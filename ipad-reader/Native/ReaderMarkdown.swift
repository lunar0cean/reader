import Foundation
import UIKit
import Markdown

struct ReaderInlineStyle: Codable, Equatable {
    var location: Int
    var length: Int
    var bold = false
    var italic = false
    var code = false
    var strike = false
    var link: String? = nil
}
struct ReaderParagraphStyle: Codable, Equatable {
    var kind = "body"
    var level = 0
    var depth = 0
    var runs: [ReaderInlineStyle] = []
}

/// CommonMark/GFM is parsed once on import. Display text and style ranges are
/// portable backup data; citations address this stable text after repagination.
enum ReaderMarkdown {
    static func book(data: Data, name: String) throws -> ReaderBook {
        guard let source = String(data: data, encoding: .utf8) else { throw ReaderFileError.invalid("Markdown 请使用 UTF-8 编码。") }
        var builder = Builder()
        try builder.blocks(Document(parsing: source.replacingOccurrences(of: "\u{FEFF}", with: "")))
        guard !builder.paragraphs.isEmpty else { throw ReaderFileError.invalid("Markdown 没有正文。") }
        let heading = builder.styles.keys.sorted().first { builder.styles[$0]?.kind == "heading" }
        let title = heading.map { builder.paragraphs[$0] } ?? (name as NSString).deletingPathExtension
        let chapter = ReaderChapter(id: "markdown", title: title, paragraphs: builder.paragraphs, href: name, paragraphStyles: builder.styles)
        return ReaderBook(id: UUID().uuidString, title: String(title.prefix(500)), author: "从此设备导入", format: "MD", color: "clay", chapters: [chapter], original: data, originalName: name, importedAt: Date(), importWarnings: builder.hasImages ? ["Markdown 图片暂显示替代文字；原始链接保留在原文件中。"] : [])
    }
    static func validate(_ chapter: ReaderChapter) throws {
        for (index, style) in chapter.paragraphStyles ?? [:] {
            guard chapter.paragraphs.indices.contains(index), ["body", "heading", "list", "quote", "code", "table", "rule"].contains(style.kind),
                  (0...6).contains(style.level), (0...64).contains(style.depth) else { throw ReaderFileError.invalid("Markdown 段落样式无效。") }
            let length = (chapter.paragraphs[index] as NSString).length
            guard style.runs.count <= 100_000, style.runs.allSatisfy({ $0.location >= 0 && $0.location <= length && $0.length >= 0 && $0.length <= length - $0.location }) else { throw ReaderFileError.invalid("Markdown 文字样式越界。") }
        }
    }
    static func attributed(chapter: ReaderChapter, layout: PageLayout) -> NSAttributedString {
        let body = NSMutableAttributedString(attributedString: ReaderPagination.attributed(chapter.text, layout: layout))
        let ranges = chapter.paragraphRanges
        let bodyFont = body.length > 0 ? body.attribute(.font, at: 0, effectiveRange: nil) as? UIFont : nil
        for (index, style) in chapter.paragraphStyles ?? [:] {
            guard ranges.indices.contains(index) else { continue }
            let range = ranges[index]
            var size = CGFloat(layout.fontSize)
            if style.kind == "heading" { size *= style.level == 1 ? 1.5 : style.level == 2 ? 1.3 : style.level == 3 ? 1.15 : 1.05 }
            let base = style.kind == "code" ? UIFont.monospacedSystemFont(ofSize: size * 0.86, weight: .regular) :
                style.kind == "heading" ? UIFont.systemFont(ofSize: size, weight: .semibold) :
                (bodyFont ?? UIFont.systemFont(ofSize: size))
            let paragraph = NSMutableParagraphStyle()
            paragraph.minimumLineHeight = size * layout.lineHeight; paragraph.maximumLineHeight = size * layout.lineHeight
            paragraph.firstLineHeadIndent = CGFloat(style.depth) * 16
            paragraph.headIndent = paragraph.firstLineHeadIndent + (style.kind == "list" ? size * 1.5 : style.kind == "quote" ? 14 : 0)
            paragraph.alignment = .left
            paragraph.lineBreakMode = style.kind == "code" ? .byCharWrapping : .byWordWrapping
            body.addAttributes([.font: base, .paragraphStyle: paragraph], range: range)
            for run in style.runs where run.location >= 0 && run.location <= range.length && run.length <= range.length - run.location {
                let target = NSRange(location: range.location + run.location, length: run.length)
                let font = run.code ? UIFont.monospacedSystemFont(ofSize: size * 0.9, weight: .regular) : base
                var traits = font.fontDescriptor.symbolicTraits
                if run.bold { traits.insert(.traitBold) }; if run.italic { traits.insert(.traitItalic) }
                if let descriptor = font.fontDescriptor.withSymbolicTraits(traits) { body.addAttribute(.font, value: UIFont(descriptor: descriptor, size: font.pointSize), range: target) }
                if run.strike { body.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: target) }
                if let link = run.link, let url = URL(string: link), ["https", "http", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    body.addAttributes([.link: url, .underlineStyle: NSUnderlineStyle.single.rawValue], range: target)
                }
            }
        }
        return body
    }

    private struct Builder {
        var paragraphs: [String] = []
        var styles: [Int: ReaderParagraphStyle] = [:]
        var hasImages = false
        mutating func append(_ node: Markup, kind: String, level: Int = 0, depth: Int = 0, prefix: String = "", raw: String? = nil) throws {
            var text = prefix, runs: [ReaderInlineStyle] = []
            if let raw { text += raw }
            else { for child in node.children { inline(child, text: &text, runs: &runs) } }
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            guard paragraphs.count < 50_000 else { throw ReaderFileError.invalid("Markdown 段落过多。") }
            styles[paragraphs.count] = ReaderParagraphStyle(kind: kind, level: level, depth: depth, runs: runs)
            paragraphs.append(text)
        }
        mutating func blocks(_ node: Markup, depth: Int = 0, quote: Bool = false, prefix: String = "") throws {
            guard depth <= 64 else { throw ReaderFileError.invalid("Markdown 嵌套过深。") }
            switch node {
            case let heading as Heading: try append(heading, kind: "heading", level: heading.level, depth: depth)
            case let paragraph as Paragraph: try append(paragraph, kind: quote ? "quote" : prefix.isEmpty ? "body" : "list", depth: depth, prefix: quote ? "│ " + prefix : prefix)
            case let code as CodeBlock: try append(code, kind: "code", depth: depth, raw: code.code.hasSuffix("\n") ? String(code.code.dropLast()) : code.code)
            case is ThematicBreak: try append(node, kind: "rule", raw: "────────")
            case let list as OrderedList:
                for (index, item) in list.children.enumerated() { try listItem(item, depth: depth, quote: quote, prefix: "\(list.startIndex + UInt(index)). ") }
            case let list as UnorderedList:
                for item in list.children { try listItem(item, depth: depth, quote: quote, prefix: "• ") }
            case is BlockQuote:
                for child in node.children { try blocks(child, depth: depth + 1, quote: true) }
            case let table as Table:
                try tableRow(table.head, depth: depth, header: true)
                for row in table.body.children { try tableRow(row, depth: depth, header: false) }
            case let html as HTMLBlock: try append(html, kind: "code", raw: html.rawHTML)
            default: for child in node.children { try blocks(child, depth: depth, quote: quote, prefix: prefix) }
            }
        }
        mutating func listItem(_ item: Markup, depth: Int, quote: Bool, prefix: String) throws {
            for (index, child) in item.children.enumerated() {
                try blocks(child, depth: depth + 1, quote: quote, prefix: index == 0 ? prefix : "")
            }
        }
        mutating func tableRow(_ row: Markup, depth: Int, header: Bool) throws {
            var text = "", runs: [ReaderInlineStyle] = []
            for (index, cell) in row.children.enumerated() {
                if index > 0 { text += "  |  " }
                for child in cell.children { inline(child, text: &text, runs: &runs, bold: header) }
            }
            try append(row, kind: "table", depth: depth, raw: text)
            if !text.isEmpty { styles[paragraphs.count - 1]?.runs = runs }
        }
        mutating func inline(_ node: Markup, text: inout String, runs: inout [ReaderInlineStyle], bold: Bool = false, italic: Bool = false, code: Bool = false, strike: Bool = false, link: String? = nil) {
            let start = (text as NSString).length
            switch node {
            case let value as Markdown.Text: text += value.string
            case let value as InlineCode: text += value.code
            case is SoftBreak: text += " "
            case is LineBreak: text += "\n"
            case let value as InlineHTML: text += value.rawHTML
            case is Image:
                hasImages = true; text += "[图片："
                for child in node.children { inline(child, text: &text, runs: &runs) }
                text += "]"
            default:
                for child in node.children {
                    inline(child, text: &text, runs: &runs, bold: bold || node is Strong, italic: italic || node is Emphasis, code: code, strike: strike || node is Strikethrough, link: (node as? Markdown.Link)?.destination ?? link)
                }
                return
            }
            let length = (text as NSString).length - start
            if length > 0 { runs.append(ReaderInlineStyle(location: start, length: length, bold: bold, italic: italic, code: code || node is InlineCode, strike: strike, link: link)) }
        }
    }
}
