import XCTest
import UIKit
import CoreText
@testable import YeJian

final class BookLayoutTests: XCTestCase {
    func testBundledChineseSerifIsAvailable() {
        ReaderFont.register()
        XCTAssertEqual(ReaderFont.serif(size: 22).fontName, "YejianSerif-Regular")
    }

    func testOldBackupRetainsOriginalTextMetrics() throws {
        let data = Data(#"{"fontSize":21,"lineHeight":1.95,"margin":60,"fontFamily":"serif"}"#.utf8)
        let legacy = try JSONDecoder().decode(PageLayout.self, from: data)
        XCTAssertEqual(legacy.typographyVersion, 1)
        let paragraph = ReaderPagination.attributed("原文", layout: legacy).attribute(.paragraphStyle, at: 0, effectiveRange: nil) as! NSParagraphStyle
        XCTAssertEqual(paragraph.firstLineHeadIndent, 0)
        XCTAssertEqual(paragraph.minimumLineHeight, 21 * 1.95, accuracy: 0.001)
        XCTAssertEqual(try JSONDecoder().decode(PageLayout.self, from: JSONEncoder().encode(legacy)), legacy)
    }

    func testNewPaginationPreservesEverySourceCharacter() throws {
        ReaderFont.register()
        let url = try XCTUnwrap(Bundle.main.url(forResource: "library", withExtension: "json"))
        let books = try JSONDecoder().decode([ReaderBook].self, from: Data(contentsOf: url))
        for book in books {
            let pages = ReaderPagination.pages(book: book, layout: PageLayout())
            for chapter in book.chapters {
                let leaves = pages.filter { $0.chapterID == chapter.id }
                XCTAssertEqual(leaves.map { $0.body.string }.joined(), chapter.text)
                for page in leaves {
                    let setter = CTFramesetterCreateWithAttributedString(page.fullBody as CFAttributedString)
                    let path = CGPath(rect: CGRect(origin: .zero, size: ReaderPagination.bodyRect(PageLayout(), opening: page.range.location == 0).size), transform: nil)
                    let frame = CTFramesetterCreateFrame(setter, CFRange(location: page.range.location, length: page.range.length), path, nil)
                    XCTAssertEqual(CTFrameGetVisibleStringRange(frame).length, page.body.length)
                }
            }
        }
    }
}
