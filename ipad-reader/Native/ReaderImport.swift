import Foundation
import UIKit
import PDFKit
import ZIPFoundation
import SwiftSoup

/// Importers retain the source bytes; rendered paragraphs never replace the original.
enum ReaderImport {
    static let fileLimit = 50 * 1024 * 1024
    static func file(data: Data, name: String, control: ReaderImportControl? = nil) throws -> ReaderBook {
        try control?.check()
        guard !data.isEmpty, data.count <= fileLimit else { throw ReaderFileError.invalid("文件为空或超过 50 MB。") }
        switch (name as NSString).pathExtension.lowercased() {
        case "epub": return try epub(data: data, name: name)
        case "pdf": return try pdf(data: data, name: name, control: control)
        case "pptx": return try ReaderSlides.book(data: data, name: name, control: control)
        case "ppt": throw ReaderFileError.invalid("旧版 .ppt 请先在 PowerPoint 导出为 PDF 或另存为 .pptx，再导入阅读器。")
        case "md", "markdown": return try ReaderMarkdown.book(data: data, name: name)
        case "html", "htm": return try article(data: data, name: name, source: nil)
        case "txt":
            guard let text = String(data: data, encoding: .utf8) else { throw ReaderFileError.invalid("TXT 请使用 UTF-8 编码。") }
            let paragraphs = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            guard !paragraphs.isEmpty else { throw ReaderFileError.invalid("TXT 没有正文。") }
            return ReaderBook(id: UUID().uuidString, title: (name as NSString).deletingPathExtension, author: "从此设备导入", format: "TXT", color: "clay", source: nil, chapters: [ReaderChapter(id: "text", title: "正文", paragraphs: paragraphs)], original: data, originalName: name, importedAt: Date())
        default: throw ReaderFileError.invalid("请选择 EPUB、PDF、UTF-8 TXT / Markdown、HTML、笔记本或阅读器备份。")
        }
    }

    static func pdf(data: Data, name: String, control: ReaderImportControl? = nil, extractText: Bool = true) throws -> ReaderBook {
        guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else { throw ReaderFileError.invalid("PDF 无法打开或需要密码，请先解锁文件。") }
        guard document.pageCount <= 2000 else { throw ReaderFileError.invalid("本版支持 2000 页以内的 PDF。") }
        let chapters = try (0..<document.pageCount).map { index -> ReaderChapter in
            try control?.check()
            control?.progress("正在读取 PDF 页码 \(index + 1) / \(document.pageCount)…")
            let text = extractText ? autoreleasepool { document.page(at: index).map(ReaderPDFText.source) ?? "" } : ""
            return ReaderChapter(id: "pdf-\(index)", title: "第 \(index + 1) 页", paragraphs: [text])
        }
        let metadata = document.documentAttributes ?? [:]
        let title = (metadata[PDFDocumentAttribute.titleAttribute] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? (name as NSString).deletingPathExtension
        let scans = extractText ? chapters.filter { $0.text.isEmpty }.count : 0
        var book = ReaderBook(id: UUID().uuidString, title: title, author: metadata[PDFDocumentAttribute.authorAttribute] as? String ?? "从此设备导入", format: "PDF", color: "clay", source: nil, chapters: chapters, original: data, originalName: name, importedAt: Date(), importWarnings: scans > 0 ? ["\(scans) 页没有可提取文字，仍可阅读和手写；文字检索需后续 OCR。"] : [], coverData: ReaderCovers.firstPage(data))
        book.pdfTextVersion = 2; return book
    }

    static func epub(data: Data, name: String) throws -> ReaderBook {
        let archive = try Archive(data: data, accessMode: .read)
        var total: UInt64 = 0, count = 0
        for entry in archive {
            count += 1
            guard count <= 20000, entry.uncompressedSize <= 20 * 1024 * 1024, total <= 100 * 1024 * 1024 - entry.uncompressedSize else { throw ReaderFileError.invalid("EPUB 解压内容过大，暂不能导入。") }
            total += entry.uncompressedSize
        }
        func read(_ path: String) throws -> Data {
            guard let entry = archive[path], entry.type == .file else { throw ReaderFileError.invalid("EPUB 缺少资源：\(path)") }
            var result = Data()
            _ = try archive.extract(entry) { chunk in
                guard result.count + chunk.count <= 20 * 1024 * 1024 else { throw ReaderFileError.invalid("EPUB 单个资源过大。") }
                result.append(chunk)
            }
            return result
        }
        let container = try ReaderXML.parse(read("META-INF/container.xml"))
        guard let rootfile = container.descendants("rootfile").first,
              let rawPath = rootfile.attributes["full-path"], let path = resourcePath(rawPath, from: "") else { throw ReaderFileError.invalid("EPUB 没有有效的 container.xml。") }
        let package = try ReaderXML.parse(read(path))
        if package.descendants("meta").contains(where: { $0.attributes["property"] == "rendition:layout" && $0.text.contains("pre-paginated") }) {
            throw ReaderFileError.invalid("本版先支持可重排 EPUB，固定版式 EPUB 请暂用 PDF。")
        }
        if let encrypted = archive["META-INF/encryption.xml"] {
            var bytes = Data(); _ = try archive.extract(encrypted) { bytes.append($0) }
            let encryption = try ReaderXML.parse(bytes)
            let algorithms = encryption.descendants("EncryptionMethod").compactMap { $0.attributes["Algorithm"] }
            if algorithms.contains(where: { !["http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC"].contains($0) }) {
                throw ReaderFileError.invalid("此 EPUB 含加密内容，本版不能打开 DRM 书籍。")
            }
        }
        let items = package.descendants("manifest").first?.children.filter { $0.name == "item" } ?? []
        let manifest = Dictionary(items.compactMap { item -> (String, ReaderXML)? in
            guard let id = item.attributes["id"] else { return nil }; return (id, item)
        }, uniquingKeysWith: { first, _ in first })
        let spine = package.descendants("spine").first?.children.filter { $0.name == "itemref" && $0.attributes["linear"] != "no" } ?? []
        guard !spine.isEmpty else { throw ReaderFileError.invalid("EPUB 没有可阅读的章节顺序。") }
        var chapterTitles: [String: String] = [:]
        if let nav = items.first(where: { ($0.attributes["properties"] ?? "").split(separator: " ").contains("nav") }),
           let href = nav.attributes["href"], let navPath = resourcePath(href, from: path) {
            let doc = try SwiftSoup.parse(ReaderHTML.decode(try read(navPath)))
            for a in try doc.select("nav a").array() {
                if let target = resourcePath(try a.attr("href"), from: navPath), chapterTitles[target] == nil { chapterTitles[target] = try a.text() }
            }
        }
        if chapterTitles.isEmpty, let ncx = items.first(where: { $0.attributes["media-type"] == "application/x-dtbncx+xml" }),
           let href = ncx.attributes["href"], let ncxPath = resourcePath(href, from: path) {
            let nav = try ReaderXML.parse(read(ncxPath))
            for point in nav.descendants("navPoint") {
                if let href = point.children.first(where: { $0.name == "content" })?.attributes["src"],
                   let target = resourcePath(href, from: ncxPath), let label = point.children.first(where: { $0.name == "navLabel" })?.text, chapterTitles[target] == nil { chapterTitles[target] = label }
            }
        }
        var chapters: [ReaderChapter] = [], assets: [String: Data] = [:], warnings: [String] = []
        for (index, ref) in spine.enumerated() {
            guard let id = ref.attributes["idref"], let item = manifest[id], let href = item.attributes["href"],
                  let chapterPath = resourcePath(href, from: path), ["application/xhtml+xml", "text/html"].contains(item.attributes["media-type"] ?? "") else { throw ReaderFileError.invalid("EPUB 的章节资源无效。") }
            let extracted = try ReaderHTML.extract(ReaderHTML.decode(try read(chapterPath)), article: false)
            var paragraphs: [String] = [], images: [Int: String] = [:]
            for block in extracted.blocks {
                if let src = block.image, let imagePath = resourcePath(src, from: chapterPath) {
                    if let bytes = try? read(imagePath), ReaderImages.image(bytes) != nil {
                        assets[imagePath] = bytes; images[paragraphs.count] = imagePath; paragraphs.append("\u{FFFC}")
                    } else { paragraphs.append("[插图：\(block.text.isEmpty ? imagePath : block.text)]"); warnings.append("部分插图格式暂不能显示；原资源仍保存在 EPUB 原文件中。") }
                } else if !block.text.isEmpty { paragraphs.append(block.text) }
            }
            if paragraphs.isEmpty { paragraphs = ["本章节没有可提取正文。"] }
            chapters.append(ReaderChapter(id: "spine-\(index)", title: chapterTitles[chapterPath] ?? extracted.heading ?? "第 \(index + 1) 章", paragraphs: paragraphs, href: chapterPath, images: images))
        }
        let metadata = package.descendants("metadata").first
        return ReaderBook(id: UUID().uuidString, title: metadata?.descendants("title").first?.text ?? (name as NSString).deletingPathExtension,
                          author: metadata?.descendants("creator").first?.text ?? "作者未标注", format: "EPUB", color: "sage", source: nil,
                          chapters: chapters, original: data, originalName: name, assets: assets, importedAt: Date(), importWarnings: Array(Set(warnings)).sorted(), coverData: ReaderCovers.epub(package: package, path: path, read: read))
    }

    /// Resolves legitimate ../ references without permitting a path outside the archive.
    static func resourcePath(_ href: String, from base: String) -> String? {
        guard !href.hasPrefix("/"), !href.contains(":"), !href.contains("\\") else { return nil }
        let raw = String(href.split(separator: "#", omittingEmptySubsequences: false)[0]).split(separator: "?", omittingEmptySubsequences: false)[0]
        guard let decoded = String(raw).removingPercentEncoding, !decoded.contains("\\"), !decoded.hasPrefix("/") else { return nil }
        var parts = base.isEmpty ? [] : base.split(separator: "/").dropLast().map(String.init)
        if decoded.isEmpty { return base.isEmpty ? nil : base }
        for component in decoded.split(separator: "/").map(String.init) {
            if component == "." { continue }
            if component == ".." { guard !parts.isEmpty else { return nil }; parts.removeLast() }
            else { parts.append(component) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    static func article(data: Data, name: String, source: URL?) throws -> ReaderBook {
        let extracted = try ReaderHTML.extract(ReaderHTML.decode(data), article: true)
        var paragraphs: [String] = [], images: [Int: String] = [:], assets: [String: Data] = [:]
        for (index, block) in extracted.blocks.enumerated() {
            if let src = block.image, let bytes = inlineImage(src), ReaderImages.image(bytes) != nil {
                let key = "inline-\(index)"; assets[key] = bytes; images[paragraphs.count] = key; paragraphs.append("\u{FFFC}")
            } else { paragraphs.append(block.image == nil ? block.text : "[插图：\(block.text.isEmpty ? "网页图片" : block.text)]") }
        }
        guard !paragraphs.isEmpty else { throw ReaderFileError.invalid("没有找到文章正文。请使用静态 HTML 或可公开访问的文章；动态和登录页面暂不支持。") }
        return ReaderBook(id: UUID().uuidString, title: extracted.title.isEmpty ? (name as NSString).deletingPathExtension : extracted.title,
                          author: extracted.author ?? source?.host ?? "网页文章", format: "WEB", color: "sage", source: source?.absoluteString,
                          chapters: [ReaderChapter(id: "article", title: extracted.heading ?? extracted.title, paragraphs: paragraphs, href: source?.absoluteString, images: images)],
                          original: data, originalName: name, assets: assets, importedAt: Date(), importWarnings: extracted.blocks.enumerated().contains(where: { $0.element.image != nil && images[$0.offset] == nil }) ? ["部分网页图片未保存，显示替代说明；原 HTML 一并备份。"] : [])
    }
    static func inlineImage(_ text: String) -> Data? {
        guard text.count <= 3 * 1024 * 1024, let comma = text.firstIndex(of: ","), ["data:image/png;base64", "data:image/jpeg;base64", "data:image/gif;base64", "data:image/webp;base64"].contains(String(text[..<comma]).lowercased()) else { return nil }
        return Data(base64Encoded: String(text[text.index(after: comma)...]))
    }

    static func webURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw ReaderFileError.invalid("请输入完整的 https:// 文章网址。")
        }; return url
    }
    static func fetchArticle(_ text: String, session suppliedSession: URLSession? = nil) async throws -> ReaderBook {
        let url = try webURL(text)
        let config = URLSessionConfiguration.ephemeral; config.httpShouldSetCookies = false
        let session = suppliedSession ?? URLSession(configuration: config)
        defer { if suppliedSession == nil { session.invalidateAndCancel() } }
        let (data, response) = try await fetch(url, session: session, limit: 5 * 1024 * 1024, accepted: ["text/html", "application/xhtml+xml"])
        let source = response.url ?? url
        var book = try article(data: data, name: "article.html", source: source)
        let blocks = try ReaderHTML.extract(ReaderHTML.decode(data), article: true).blocks
        var downloaded = 0, count = 0
        for (index, block) in blocks.enumerated() {
            guard let src = block.image, book.chapters[0].images?[index] == nil else { continue }
            guard let imageURL = URL(string: src, relativeTo: source)?.absoluteURL, imageURL.scheme == "https", imageURL.user == nil, imageURL.password == nil, count < 12 else { continue }
            count += 1
            if let (bytes, _) = try? await fetch(imageURL, session: session, limit: 2 * 1024 * 1024, accepted: ["image/png", "image/jpeg", "image/gif", "image/webp"]), downloaded + bytes.count <= 12 * 1024 * 1024, ReaderImages.image(bytes) != nil {
                downloaded += bytes.count; let key = "web-image-\(index)"
                book.assets?[key] = bytes; book.chapters[0].images?[index] = key; book.chapters[0].paragraphs[index] = "\u{FFFC}"
            }
        }
        book.importWarnings = blocks.enumerated().contains(where: { $0.element.image != nil && book.chapters[0].images?[$0.offset] == nil }) ? ["部分网页图片未保存，显示替代说明；原 HTML 一并备份。"] : []
        return book
    }
    private static func fetch(_ url: URL, session: URLSession, limit: Int, accepted: [String]) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url); request.timeoutInterval = 25
        request.setValue(accepted.joined(separator: ","), forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), http.url?.scheme == "https" else { throw ReaderFileError.invalid("网页请求失败或跳转到了不受支持的地址。") }
        guard accepted.contains(http.mimeType ?? "") else { throw ReaderFileError.invalid("网址返回的格式不支持，请下载原文件再导入。") }
        var data = Data()
        for try await byte in bytes { guard data.count < limit else { throw ReaderFileError.invalid("网页或图片超过本版支持的大小。") }; data.append(byte) }
        return (data, http)
    }
}

struct ReaderHTMLBlock { var text: String; var image: String? }
struct ReaderHTMLContent { var title: String; var heading: String?; var author: String?; var blocks: [ReaderHTMLBlock] }
enum ReaderHTML {
    static func decode(_ data: Data) throws -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        if (data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff])), let text = String(data: data, encoding: .utf16) { return text }
        let declaration = String(decoding: data.prefix(2048), as: UTF8.self).lowercased()
        if declaration.contains("windows-1252") || declaration.contains("iso-8859-1"), let text = String(data: data, encoding: .windowsCP1252) { return text }
        let gb = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: gb) { return text }
        throw ReaderFileError.invalid("正文编码无法识别，请保存为 UTF-8 HTML。")
    }
    static func extract(_ html: String, article: Bool) throws -> ReaderHTMLContent {
        let doc = try SwiftSoup.parse(html)
        let title = try doc.title(), heading = try doc.select("h1,h2").first()?.text()
        let author = try doc.select("meta[name=author]").first()?.attr("content")
        try doc.select("script,style,noscript,iframe,object,embed,form,button,template,head,[hidden],[aria-hidden=true]").remove()
        if article { try doc.select("nav,aside,footer,header,[role=navigation],[role=banner]").remove() }
        let candidates = article ? try doc.select("article,main,[role=main]").array() : []
        let root = try candidates.max(by: { (try $0.text().count) < (try $1.text().count) }) ?? doc.body()
        guard let root else { throw ReaderFileError.invalid("HTML 没有正文。") }
        var blocks: [ReaderHTMLBlock] = [], buffer = ""
        let blockTags: Set<String> = ["p", "div", "section", "article", "main", "h1", "h2", "h3", "h4", "h5", "h6", "li", "blockquote", "pre", "tr", "figure", "figcaption"]
        func flush() {
            let text = buffer.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { blocks.append(ReaderHTMLBlock(text: text, image: nil)) }; buffer = ""
        }
        func walk(_ node: Node) throws {
            if let text = node as? TextNode { buffer += text.getWholeText(); return }
            guard let element = node as? Element else { return }
            let tag = element.tagName().lowercased()
            if blockTags.contains(tag) { flush() }
            if tag == "br" { flush(); return }
            if tag == "td" || tag == "th" { buffer += " " }
            if tag == "img" || tag == "image" {
                flush(); let src = try element.attr(tag == "image" ? "xlink:href" : "src")
                if !src.isEmpty { blocks.append(ReaderHTMLBlock(text: try element.attr("alt"), image: src)) }; return
            }
            for child in element.getChildNodes() { try walk(child) }
            if blockTags.contains(tag) { flush() }
        }
        try walk(root); flush()
        if blocks.count > 1, blocks.first?.image == nil, blocks.first?.text == heading { blocks.removeFirst() }
        return ReaderHTMLContent(title: title, heading: heading, author: author, blocks: blocks)
    }
}

/// Small XML tree for EPUB package/container/NCX, with no external entity loading.
final class ReaderXML: NSObject, XMLParserDelegate {
    var name: String; var attributes: [String: String]; var children: [ReaderXML] = []; var ownText = ""
    init(_ name: String = "", attributes: [String: String] = [:]) { self.name = name; self.attributes = attributes }
    var text: String { (ownText + children.map(\.text).joined()).trimmingCharacters(in: .whitespacesAndNewlines) }
    func descendants(_ name: String) -> [ReaderXML] { children.flatMap { ($0.name == name ? [$0] : []) + $0.descendants(name) } }
    private var stack: [ReaderXML] = []
    static func parse(_ data: Data) throws -> ReaderXML {
        if (try? ReaderHTML.decode(data))?.contains("<!ENTITY") == true { throw ReaderFileError.invalid("EPUB XML 声明了不支持的实体。") }
        let root = ReaderXML(); root.stack = [root]
        let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = root
        guard parser.parse() else { throw ReaderFileError.invalid("EPUB XML 结构无效。") }; return root
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        let node = ReaderXML(elementName.components(separatedBy: ":").last ?? elementName, attributes: attributeDict)
        stack.last?.children.append(node); stack.append(node)
    }
    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { parser.abortParsing() }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.ownText += string }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) { stack.removeLast() }
}
