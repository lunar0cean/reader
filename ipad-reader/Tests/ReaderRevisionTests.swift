import XCTest
import UIKit
import PDFKit
import PencilKit
@testable import YeJian

@MainActor final class ReaderRevisionTests: XCTestCase {
    func testPDFSelectionRejectsMissingCharactersAndNotFoundIndices() throws {
        for pair in [(0, 0, 0), (10, NSNotFound, 0), (10, 0, NSNotFound), (10, -1, 4), (10, 3, 10)] {
            XCTAssertNil(ReaderPDFText.range(count: pair.0, from: pair.1, to: pair.2))
        }
        XCTAssertEqual(ReaderPDFText.range(count: 10, from: 8, to: 2), NSRange(location: 2, length: 7))
        let image = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 400)).image { c in
            ("Only pixels" as NSString).draw(at: CGPoint(x: 20, y: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 20)])
        }
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { c in c.beginPage(); image.draw(at: .zero) }
        let page = try XCTUnwrap(PDFDocument(data: data)?.page(at: 0))
        XCTAssertNil(ReaderPDFText.word(page, at: CGPoint(x: 30, y: 290)))
    }
    func testPDFAndPPTXFirstPageCoversAndCustomCoverBackup() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 600)).pdfData { c in
            c.beginPage(); UIColor.blue.setFill(); c.cgContext.fill(CGRect(x: 0, y: 0, width: 400, height: 600))
        }
        var book = try ReaderImport.pdf(data: data, name: "封面.pdf")
        XCTAssertNotNil(book.coverData); XCTAssertNotNil(ReaderCovers.image(book))
        book.customCover = ReaderCovers.normalized(UIGraphicsImageRenderer(size: CGSize(width: 80, height: 100)).image { c in UIColor.red.setFill(); c.fill(CGRect(x: 0, y: 0, width: 80, height: 100)) }.pngData()!)
        let restored = try JSONDecoder().decode(ReaderBook.self, from: JSONEncoder().encode(book))
        XCTAssertEqual(restored.customCover, book.customCover); XCTAssertEqual(restored.coverData, book.coverData)
        let url = try XCTUnwrap(Bundle.main.url(forResource: "sample-slides", withExtension: "pptx"))
        XCTAssertNotNil(try ReaderImport.file(data: Data(contentsOf: url), name: "slides.pptx").coverData)
    }
    func testEPUB2And3DeclaredCoversUseEmbeddedImage() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 160)).image { c in UIColor.cyan.setFill(); c.fill(CGRect(x: 0, y: 0, width: 120, height: 160)) }.pngData()!
        for declaration in ["<metadata><meta name='cover' content='jacket'/></metadata>", ""] {
            let properties = declaration.isEmpty ? " properties='cover-image'" : ""
            let xml = try ReaderXML.parse(Data("<package>\(declaration)<manifest><item id='jacket' href='cover.png' media-type='image/png'\(properties)/></manifest></package>".utf8))
            let data = try XCTUnwrap(ReaderCovers.epub(package: xml, path: "OPS/book.opf", read: { path in XCTAssertEqual(path, "OPS/cover.png"); return image }))
            XCTAssertNotNil(UIImage(data: data))
        }
    }
    func testNotebookPageCacheRetainsIndependentInkAndViewport() throws {
        let controls = NotebookControls(); var first = NotebookPage(); let second = NotebookPage()
        let point = PKStrokePoint(location: CGPoint(x: 80, y: 200), timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 0.7, azimuth: 0, altitude: 1)
        first.captureNative(PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: [point], creationDate: Date()))]))
        func surface(_ page: NotebookPage) -> NotebookSurface { NotebookSurface(page: page, controls: controls, onDrawing: { _, _, _ in }, onExtent: { _, _ in }, onElement: { _, _ in }, onEdit: { _ in }) }
        // Exercise the coordinator through real UIKit views, preserving PencilKit undo state.
        let coordinator = NotebookSurface.Coordinator(surface(first))
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 700, height: 800))
        let content = UIView(frame: CGRect(origin: .zero, size: first.size)), canvas = ReaderInkCanvas(frame: content.bounds)
        content.addSubview(canvas); scroll.addSubview(content); scroll.contentSize = first.size
        scroll.minimumZoomScale = 0.2; scroll.maximumZoomScale = 3; scroll.delegate = coordinator
        coordinator.scroll = scroll; coordinator.content = content; coordinator.canvas = canvas
        coordinator.update(surface(first)); scroll.setZoomScale(1.4, animated: false); scroll.setContentOffset(CGPoint(x: 90, y: 130), animated: false)
        let original = coordinator.canvas
        coordinator.update(surface(second)); XCTAssertFalse(original === coordinator.canvas)
        XCTAssertEqual(coordinator.canvas?.drawing.strokes.count, 0)
        coordinator.update(surface(first)); XCTAssertTrue(original === coordinator.canvas)
        XCTAssertEqual(coordinator.canvas?.drawing.strokes.count, 1)
        XCTAssertEqual(scroll.zoomScale, 1.4, accuracy: 0.01); XCTAssertEqual(scroll.contentOffset.y, 130, accuracy: 1)
        coordinator.close(); XCTAssertNil(controls.canvas)
    }
}
