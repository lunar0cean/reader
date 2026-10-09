import XCTest
import UIKit
@testable import YeJian

final class MarkdownTests: XCTestCase {
    func testMarkdownStylesAreRenderedAndSourceBytesRetained() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "sample-markdown", withExtension: "md"))
        let bytes = try Data(contentsOf: url), book = try ReaderImport.file(data: bytes, name: "sample.md")
        XCTAssertEqual(book.format, "MD"); XCTAssertEqual(book.title, "Markdown 阅读"); XCTAssertEqual(book.original, bytes)
        let chapter = book.chapters[0]
        XCTAssertFalse(chapter.text.contains("**")); XCTAssertFalse(chapter.text.contains("```"))
        XCTAssertTrue(chapter.text.contains("• 导入书籍")); XCTAssertTrue(chapter.text.contains("│ 引用"))
        XCTAssertTrue(chapter.text.contains("let page = \"页间\"")); XCTAssertTrue(chapter.text.contains("PDF  |  固定版式"))
        let body = ReaderMarkdown.attributed(chapter: chapter, layout: PageLayout())
        let bold = (body.string as NSString).range(of: "加粗文字")
        XCTAssertTrue((body.attribute(.font, at: bold.location, effectiveRange: nil) as? UIFont)?.fontDescriptor.symbolicTraits.contains(.traitBold) == true)
        let link = (body.string as NSString).range(of: "链接文字")
        XCTAssertEqual((body.attribute(.link, at: link.location, effectiveRange: nil) as? URL)?.absoluteString, "https://example.com/article")
        for width in [400.0, 820.0] {
            var layout = PageLayout(); layout.width = width
            XCTAssertEqual(ReaderPagination.pages(book: book, layout: layout).map { $0.body.string }.joined(), chapter.text)
        }
        try ReaderMarkdown.validate(chapter)
    }
    @MainActor func testMarkdownBackupAndCitationSurviveReflow() throws {
        let source = "# 标题\n\n" + Array(repeating: "有 **重要文字** 和原文出处。", count: 80).joined(separator: "\n\n")
        let book = try ReaderImport.file(data: Data(source.utf8), name: "notes.markdown")
        let store = ReaderStore(), previous = store.backup
        defer { store.backup = previous; store.repaginate(); store.save() }
        store.backup.books.append(book); store.selectBook(book.id)
        let anchor = store.anchor(chapter: book.chapters[0], paragraph: 40)
        store.jump(to: anchor); store.addNote("保留出处", anchor: anchor)
        var layout = store.layout; layout.width = 400; store.updateLayout(layout)
        store.jump(to: anchor)
        XCTAssertEqual(store.currentPage?.chapterID, anchor.chapterID)
        XCTAssertTrue(NSLocationInRange(book.chapters[0].paragraphRanges[40].location, try XCTUnwrap(store.currentPage?.range)))
        let restored = try ReaderStore.decodeBackup(JSONEncoder().encode(store.backup))
        XCTAssertEqual(restored.books.last?.chapters, book.chapters); XCTAssertEqual(restored.notes.last?.anchor, anchor)
        XCTAssertEqual(restored.books.last?.original, Data(source.utf8))
    }
    func testMarkdownInvalidEncodingAndStyleRangesAreRejected() throws {
        XCTAssertThrowsError(try ReaderImport.file(data: Data([0xFF, 0xFE, 0xF0]), name: "bad.md"))
        XCTAssertThrowsError(try ReaderImport.file(data: Data("  \n\n".utf8), name: "empty.md"))
        var chapter = ReaderChapter(id: "md", title: "标题", paragraphs: ["正文"], paragraphStyles: [0: ReaderParagraphStyle(runs: [ReaderInlineStyle(location: Int.max, length: 5)])])
        XCTAssertThrowsError(try ReaderMarkdown.validate(chapter))
        chapter.paragraphStyles = [2: ReaderParagraphStyle()]; XCTAssertThrowsError(try ReaderMarkdown.validate(chapter))
    }
}
