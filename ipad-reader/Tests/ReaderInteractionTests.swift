import XCTest
import UIKit
import PDFKit
import PencilKit
@testable import YeJian

@MainActor final class ReaderInteractionTests: XCTestCase {
    func testCoreTextSelectionUsesPageRangeAndPreservesUnicode() throws {
        let text = Array(repeating: "正文含有中文、English 与 🖊️，可以复制原文。", count: 80).joined()
        let book = try ReaderImport.file(data: Data(text.utf8), name: "select.txt")
        let layout = PageLayout(), pages = ReaderPagination.pages(book: book, layout: layout)
        XCTAssertGreaterThan(pages.count, 1)
        for page in [pages[0], pages[1]] {
            let geometry = ReaderTextGeometry(page: page, book: book, layout: layout)
            XCTAssertEqual(geometry.visible, page.range)
            let rectangles = geometry.rectangles(for: page.range)
            XCTAssertFalse(rectangles.isEmpty)
            let point = try XCTUnwrap(rectangles.first).origin.applying(CGAffineTransform(translationX: 10, y: 10))
            let index = try XCTUnwrap(geometry.index(at: point))
            XCTAssertTrue(NSLocationInRange(index, page.range))
            let word = try XCTUnwrap(geometry.word(at: point))
            XCTAssertGreaterThan(word.length, 0)
            XCTAssertFalse(geometry.text.substring(with: word).isEmpty)
        }
    }
    func testEPUBImagesKeepOriginalDataAndHaveVisibleHitTargets() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "sample-illustrated", withExtension: "epub"))
        let book = try ReaderImport.file(data: Data(contentsOf: url), name: "sample.epub")
        let layout = PageLayout()
        let images = ReaderPagination.pages(book: book, layout: layout).flatMap { ReaderTextGeometry(page: $0, book: book, layout: layout).images() }
        XCTAssertFalse(images.isEmpty)
        for (rect, metrics) in images {
            XCTAssertGreaterThan(rect.width, 10); XCTAssertGreaterThan(rect.height, 10)
            XCTAssertNotNil(metrics.data.flatMap { UIImage(data: $0) })
        }
    }
    func testPDFImageLocationsAndSelectableText() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 32)).image { c in UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 64, height: 32)) }
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 500)).pdfData { c in
            c.beginPage(); ("Copy this text" as NSString).draw(at: CGPoint(x: 20, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
            image.draw(in: CGRect(x: 80, y: 160, width: 240, height: 120))
        }
        let book = try ReaderImport.pdf(data: pdf, name: "image.pdf")
        let page = try XCTUnwrap(ReaderPDF.document(book)?.page(at: 0))
        XCTAssertTrue(page.string?.contains("Copy this text") == true)
        let boxes = ReaderPDFImages.rectangles(book: book, index: 0)
        XCTAssertEqual(boxes.count, 1)
        XCTAssertEqual(boxes[0].width, 240, accuracy: 1); XCTAssertEqual(boxes[0].height, 120, accuracy: 1)
    }
    func testPPTXImportsSelectableTextImagesAndOriginalBackup() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "sample-slides", withExtension: "pptx"))
        let bytes = try Data(contentsOf: url), book = try ReaderImport.file(data: bytes, name: "sample-slides.pptx")
        XCTAssertEqual(book.format, "PPTX"); XCTAssertEqual(book.original, bytes); XCTAssertTrue(book.isFixedLayout)
        XCTAssertTrue(ReaderPDF.document(book)?.page(at: 0)?.string?.contains("Slide text can be copied") == true)
        XCTAssertFalse(ReaderPDFImages.rectangles(book: book, index: 0).isEmpty)
        let backup = NativeBackup(books: [book], readingState: [:], notes: [], bookmarks: [], currentBookID: book.id)
        let restored = try ReaderStore.decodeBackup(JSONEncoder().encode(backup))
        XCTAssertEqual(restored.books[0].original, bytes); XCTAssertEqual(restored.books[0].renderedPDF, book.renderedPDF)
    }
    func testNativeInkCaptureDefersVectorSamplingButSVGRemainsEditable() throws {
        let point = PKStrokePoint(location: CGPoint(x: 100, y: 200), timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 0.6, azimuth: 0, altitude: 1)
        let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [point], creationDate: Date()))])
        var page = NotebookPage(); page.captureNative(drawing)
        XCTAssertEqual(page.strokeCount, 1); XCTAssertTrue(page.strokes.isEmpty)
        XCTAssertEqual(page.drawing.strokes.count, 1)
        let section = NotebookSection(pages: [page]), book = NotebookBook(sections: [section])
        let document = NotebookDocument(notebooks: [book], notebookID: book.id, sectionID: section.id, pageID: page.id)
        let portable = document.exportSnapshot()
        XCTAssertTrue(document.notebooks[0].sections[0].pages[0].strokes.isEmpty)
        XCTAssertEqual(portable.notebooks[0].sections[0].pages[0].strokes.count, 1)
        let restored = try NotebookSVG.restore(NotebookSVG.export(page))
        XCTAssertEqual(restored.strokes.count, 1); XCTAssertEqual(restored.drawing.strokes[0].path[0].force, 0.6, accuracy: 0.01)
    }
    func testBundledSpeechFrontendAndJapaneseBridgeLoadInReader() throws {
        let frontend = try TextFrontend()
        XCTAssertFalse(try frontend.prepare("这是读书的声音。", language: "zh").isEmpty)
        XCTAssertFalse(try frontend.prepare("本を読みます。", language: "ja").isEmpty)
        XCTAssertFalse(try frontend.reference("参考录音。", language: "zh").ids.isEmpty)
    }
    func testMalformedImportedVoiceCannotReachTensorAllocation() throws {
        let header = "{\"kind\":\"voice\",\"meta\":{},\"tensors\":[{\"name\":\"ref_seq\",\"dtype\":\"i64\",\"shape\":[1,10],\"offset\":-1,\"length\":80}]}"
        var data = Data("GSVP".utf8); let n = UInt32(header.utf8.count)
        data.append(contentsOf: (0..<4).map { UInt8((n >> (8 * $0)) & 255) }); data.append(Data(header.utf8)); data.append(Data(repeating: 0, count: 80))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gsvpack")
        try data.write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try TensorPack(url: url))
    }
}
