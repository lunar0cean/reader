import Foundation
import UIKit
import CoreText

struct ReaderBook: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var author: String
    var format: String
    var color: String
    var source: String?
    var chapters: [ReaderChapter]
    var original: Data? = nil
    var originalName: String? = nil
    var assets: [String: Data]? = nil
    var importedAt: Date? = nil
    var importWarnings: [String]? = nil
    var renderedPDF: Data? = nil
    var slideRendererVersion: Int? = nil
    var pdfTextVersion: Int? = nil
    var coverData: Data? = nil
    var customCover: Data? = nil
    var isFixedLayout: Bool { format == "PDF" || format == "PPTX" }
}

struct ReaderChapter: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var paragraphs: [String]
    var href: String? = nil
    var images: [Int: String]? = nil
    var paragraphStyles: [Int: ReaderParagraphStyle]? = nil
    var text: String { paragraphs.joined(separator: "\n\n") }
    var paragraphRanges: [NSRange] {
        var offset = 0
        return paragraphs.map { paragraph in
            let range = NSRange(location: offset, length: (paragraph as NSString).length)
            offset += range.length + 2
            return range
        }
    }
}

/// Citations survive page changes because they point to source text, not a screen.
struct SourceAnchor: Codable, Equatable {
    var bookID: String
    var chapterID: String
    var paragraph: Int
    var utf16Offset: Int = 0
    var href: String? = nil
    var pdfPage: Int? = nil
    var quote: String? = nil
}

struct ReaderNote: Codable, Identifiable {
    var id = UUID().uuidString
    var text: String
    var anchor: SourceAnchor
    var kind: String = "text"
    var created = Date()
    var citations: [ChatCitation]? = nil
    var characterID: String? = nil
    var replyID: String? = nil
    var provider: String? = nil
    // Positioned note editing is a later increment. Native V1 stores text in the
    // inspector; editable handwriting is held in the separate PKDrawing layer.
}

struct PageLayout: Codable, Equatable {
    var fontSize: Double = 22
    var lineHeight: Double = 1.45
    var margin: Double = 44
    var fontFamily: String = "sans"
    var typographyVersion = 3
    var width: Double = 680
    var height: Double = 920
    var fontWeight: Double = 0
    var alignment = "justified"

    init() {}
    enum CodingKeys: String, CodingKey { case fontSize, lineHeight, margin, fontFamily, typographyVersion, width, height, fontWeight, alignment }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fontSize = try values.decode(Double.self, forKey: .fontSize)
        lineHeight = try values.decode(Double.self, forKey: .lineHeight)
        margin = try values.decode(Double.self, forKey: .margin)
        fontFamily = try values.decode(String.self, forKey: .fontFamily)
        // Old drawings retain the exact font metrics and paragraph layout.
        typographyVersion = try values.decodeIfPresent(Int.self, forKey: .typographyVersion) ?? 1
        width = try values.decodeIfPresent(Double.self, forKey: .width) ?? 680
        height = try values.decodeIfPresent(Double.self, forKey: .height) ?? 920
        fontWeight = try values.decodeIfPresent(Double.self, forKey: .fontWeight) ?? 0
        alignment = try values.decodeIfPresent(String.self, forKey: .alignment) ?? "justified"
    }
}

enum ReaderFont {
    private static let installed: Void = {
        for (name, ext) in [("YejianSerif-Regular", "ttf"), ("STIXTwoMath-Regular", "otf")] {
            if let url = Bundle.main.url(forResource: name, withExtension: ext) { CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil) }
        }
    }()
    static func register() { _ = installed }
    static func serif(size: CGFloat, legacy: Bool = false) -> UIFont {
        UIFont(name: legacy ? "SongtiSC-Regular" : "YejianSerif-Regular", size: size) ?? UIFont.systemFont(ofSize: size)
    }
}

struct BookReadingState: Codable {
    var layout = PageLayout()
    var pageIndex = 0
    var drawings: [String: Data] = [:]
    var spreadDrawings: [String: Data] = [:]
    init() {}
    enum CodingKeys: String, CodingKey { case layout, pageIndex, drawings, spreadDrawings }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        layout = try values.decode(PageLayout.self, forKey: .layout)
        pageIndex = try values.decode(Int.self, forKey: .pageIndex)
        drawings = try values.decode([String: Data].self, forKey: .drawings)
        spreadDrawings = try values.decodeIfPresent([String: Data].self, forKey: .spreadDrawings) ?? [:]
    }
}

struct NativeBackup: Codable {
    var version = 3
    var engine = "native-pencilkit-v3"
    var books: [ReaderBook]
    var readingState: [String: BookReadingState]
    var notes: [ReaderNote]
    var bookmarks: [SourceAnchor]
    var currentBookID: String
    var theme = "paper"
}

struct ReadingPage: Identifiable {
    var id: String
    var bookID: String
    var chapterID: String
    var chapterTitle: String
    var chapterIndex: Int
    var range: NSRange
    var firstParagraph: Int
    var firstParagraphOffset: Int
    var body: NSAttributedString
    var fullBody: NSAttributedString
    var href: String? = nil
    var pdfPage: Int? = nil
    var anchor: SourceAnchor {
        SourceAnchor(bookID: bookID, chapterID: chapterID, paragraph: firstParagraph, utf16Offset: firstParagraphOffset, href: href, pdfPage: pdfPage)
    }
}

enum ReaderPagination {
    static func size(_ layout: PageLayout) -> CGSize { CGSize(width: layout.width, height: layout.height) }
    static func bodyRect(_ layout: PageLayout, opening: Bool = true) -> CGRect {
        if layout.typographyVersion < 3 { return CGRect(x: layout.margin, y: 166, width: 680 - 2 * layout.margin, height: 678) }
        let top: Double = opening ? 124 : 44
        return CGRect(x: layout.margin, y: top, width: layout.width - 2 * layout.margin, height: layout.height - top - 44)
    }

    static func attributed(_ text: String, layout: PageLayout, color: UIColor = .label) -> NSAttributedString {
        let font: UIFont
        if layout.fontFamily == "serif" {
            font = ReaderFont.serif(size: layout.fontSize, legacy: layout.typographyVersion == 1)
        } else { font = UIFont.systemFont(ofSize: layout.fontSize, weight: UIFont.Weight(rawValue: layout.fontWeight)) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = layout.fontSize * layout.lineHeight
        paragraph.maximumLineHeight = layout.fontSize * layout.lineHeight
        paragraph.paragraphSpacing = layout.typographyVersion >= 3 ? 0 : 8
        paragraph.lineBreakMode = .byWordWrapping
        if layout.typographyVersion >= 2 {
            paragraph.firstLineHeadIndent = layout.fontSize * 2
            paragraph.alignment = layout.alignment == "left" ? .left : .justified
        }
        return NSAttributedString(string: text, attributes: [.font: font, .paragraphStyle: paragraph, .foregroundColor: color])
    }

    static func pages(book: ReaderBook, layout: PageLayout) -> [ReadingPage] {
        if book.isFixedLayout { return ReaderPDF.pages(book: book) }
        var result: [ReadingPage] = []
        for (chapterIndex, chapter) in book.chapters.enumerated() {
            let text = ReaderImages.attributed(chapter: chapter, book: book, layout: layout)
            let paragraphRanges = chapter.paragraphRanges
            let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
            var offset = 0
            while offset < text.length {
                let path = CGPath(rect: CGRect(origin: .zero, size: bodyRect(layout, opening: book.format != "MD" && offset == 0).size), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { break }
                let range = NSRange(location: offset, length: visible.length)
                let first = paragraphRanges.firstIndex(where: { NSMaxRange($0) > offset }) ?? 0
                result.append(ReadingPage(
                    id: "\(book.id):\(chapter.id):\(offset)", bookID: book.id, chapterID: chapter.id,
                    chapterTitle: chapter.title, chapterIndex: chapterIndex, range: range,
                    firstParagraph: first, firstParagraphOffset: max(0, offset - paragraphRanges[first].location), body: text.attributedSubstring(from: range), fullBody: text, href: chapter.href
                ))
                offset += visible.length
            }
        }
        return result
    }
}
