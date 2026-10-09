import UIKit
import ImageIO
import PDFKit
import ZIPFoundation
import SwiftSoup

enum ReaderCovers {
    static func normalized(_ data: Data) -> Data? {
        guard data.count <= 20 * 1024 * 1024, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 640, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.88)
    }
    static func firstPage(_ data: Data) -> Data? {
        autoreleasepool {
            guard let page = PDFDocument(data: data)?.page(at: 0) else { return nil }
            let rect = page.bounds(for: .cropBox)
            guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return nil }
            let scale = 640 / max(rect.width, rect.height)
            return page.thumbnail(of: CGSize(width: max(1, rect.width * scale), height: max(1, rect.height * scale)), for: .cropBox).jpegData(compressionQuality: 0.88)
        }
    }
    static func embeddedEPUB(_ data: Data) -> Data? {
        guard let archive = try? Archive(data: data, accessMode: .read) else { return nil }
        func read(_ path: String) throws -> Data {
            guard let entry = archive[path], entry.uncompressedSize <= 20 * 1024 * 1024 else { throw ReaderFileError.invalid("封面资源过大。") }
            var bytes = Data(); _ = try archive.extract(entry) { bytes.append($0) }; return bytes
        }
        guard let container = try? ReaderXML.parse(read("META-INF/container.xml")),
              let raw = container.descendants("rootfile").first?.attributes["full-path"],
              let path = ReaderImport.resourcePath(raw, from: ""), let package = try? ReaderXML.parse(read(path)) else { return nil }
        return epub(package: package, path: path, read: read)
    }
    static func epub(package: ReaderXML, path: String, read: (String) throws -> Data) -> Data? {
        func resource(_ target: String) -> Data? {
            guard let bytes = try? read(target) else { return nil }
            if let image = normalized(bytes) { return image }
            // EPUB cover documents frequently wrap a bitmap in XHTML or SVG.
            guard let html = try? ReaderHTML.decode(bytes), let doc = try? SwiftSoup.parse(html), let elements = try? doc.select("img,image").array() else { return nil }
            for element in elements {
                let raw = (try? element.attr("src")) ?? ""
                let href = raw.isEmpty ? ((try? element.attr("xlink:href")) ?? "") : raw
                let source = href.isEmpty ? ((try? element.attr("href")) ?? "") : href
                if !source.isEmpty, let imagePath = ReaderImport.resourcePath(source, from: target), let data = try? read(imagePath), let image = normalized(data) { return image }
            }
            return nil
        }
        let items = package.descendants("manifest").first?.children.filter { $0.name == "item" } ?? []
        let id = package.descendants("meta").first { $0.attributes["name"] == "cover" }?.attributes["content"]
        let item = items.first { ($0.attributes["properties"] ?? "").split(separator: " ").contains("cover-image") }
            ?? items.first { id != nil && $0.attributes["id"] == id }
        if let href = item?.attributes["href"], let target = ReaderImport.resourcePath(href, from: path), let image = resource(target) { return image }
        let guide = package.descendants("reference").first { ($0.attributes["type"] ?? "").split(separator: " ").contains("cover") }?.attributes["href"]
            ?? items.first { ($0.attributes["id"] ?? "").lowercased().contains("cover") && $0.attributes["media-type"] == "application/xhtml+xml" }?.attributes["href"]
        if let guide, let target = ReaderImport.resourcePath(guide, from: path), let image = resource(target) { return image }
        return nil
    }
    static func image(_ book: ReaderBook) -> UIImage? {
        if let data = book.customCover ?? book.coverData, let image = UIImage(data: data) { return image }
        if book.isFixedLayout, let data = book.renderedPDF ?? book.original, let cover = firstPage(data) { return UIImage(data: cover) }
        if book.format == "EPUB", let data = book.original, let cover = embeddedEPUB(data) { return UIImage(data: cover) }
        return nil
    }
}
