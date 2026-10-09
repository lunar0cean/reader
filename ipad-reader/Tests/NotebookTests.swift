import XCTest
import PencilKit
@testable import YeJian

final class NotebookTests: XCTestCase {
    @MainActor func testCanvasGrowthRetainsScaleAndVisibleOrigin() {
        let page = NotebookPage(), controls = NotebookControls()
        let surface = NotebookSurface(page: page, controls: controls, onDrawing: { _, _, _ in }, onExtent: { _, _ in }, onElement: { _, _ in }, onEdit: { _ in })
        let coordinator = NotebookSurface.Coordinator(surface)
        let scroll = UIScrollView(frame: CGRect(x: 0, y: 0, width: 820, height: 1000))
        let content = UIView(frame: CGRect(origin: .zero, size: page.size))
        coordinator.scroll = scroll; coordinator.content = content
        coordinator.canvas = ReaderInkCanvas(frame: content.bounds)
        scroll.addSubview(content); scroll.contentSize = page.size; scroll.delegate = coordinator
        scroll.minimumZoomScale = 0.2; scroll.maximumZoomScale = 3
        for scale in [0.65, 1.6] {
            scroll.setZoomScale(scale, animated: false); scroll.contentOffset = CGPoint(x: 80, y: 120)
            let origin = content.convert(CGPoint.zero, to: scroll), offset = scroll.contentOffset
            coordinator.extent(CGSize(width: 6000, height: 8000))
            XCTAssertEqual(scroll.zoomScale, scale, accuracy: 0.001)
            XCTAssertEqual(content.bounds.size, CGSize(width: 6000, height: 8000))
            XCTAssertEqual(content.convert(CGPoint.zero, to: scroll).x, origin.x, accuracy: 0.01)
            XCTAssertEqual(content.convert(CGPoint.zero, to: scroll).y, origin.y, accuracy: 0.01)
            XCTAssertEqual(scroll.contentOffset, offset)
        }
    }
    @MainActor func testIndependentNotebookExportAndRememberedPage() async throws {
        let store = NotebookStore(), previous = store.document
        defer { store.document = previous; store.save() }
        store.addBook("独立笔记本"); let id = store.document.notebookID
        store.addPage("第二页"); let pageID = store.document.pageID
        store.addBook("另一本"); store.select(bookID: id)
        XCTAssertEqual(store.document.pageID, pageID)
        let file = try XCTUnwrap(store.exportBook()); XCTAssertEqual(file.pathExtension, "yejiannotebook")
        let single = try JSONDecoder().decode(NotebookDocument.self, from: Data(contentsOf: file))
        try NotebookCodec.validate(single)
        XCTAssertEqual(single.notebooks.count, 1); XCTAssertEqual(single.notebooks[0].title, "独立笔记本")
        XCTAssertEqual(single.pageID, pageID)
        store.importFile(file)
        for _ in 0..<200 where store.isImporting { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(store.isImporting); XCTAssertNil(store.error)
        XCTAssertEqual(store.book?.title, "独立笔记本")
        XCTAssertNotEqual(store.document.notebookID, id); XCTAssertEqual(store.page?.title, "第二页")
    }
    private func drawing() -> PKDrawing {
        let points = [0.2, 0.8, 0.4].enumerated().map { index, force in
            PKStrokePoint(location: CGPoint(x: 200 + index * 80, y: 300 + index * 20), timeOffset: Double(index) * 0.05,
                          size: CGSize(width: force * 12, height: force * 10), opacity: 1, force: force, azimuth: 0.3, altitude: 1.2)
        }
        return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()), transform: CGAffineTransform(translationX: 30, y: 10), mask: nil)])
    }
    func testPressureSVGIsVectorAndRestoresEditableDrawing() throws {
        var page = NotebookPage(); page.title = "电机 & <草图> 🖊"; page.capture(drawing())
        let data = try NotebookSVG.export(page), svg = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(svg.contains("<path d=")); XCTAssertTrue(svg.contains("yejian-notebook")); XCTAssertFalse(svg.contains("data:image"))
        XCTAssertTrue(svg.contains("电机 &amp; &lt;草图&gt; 🖊"))
        let restored = try NotebookSVG.restore(data)
        XCTAssertEqual(restored.strokes, page.strokes); XCTAssertEqual(restored.title, page.title)
        XCTAssertEqual(restored.drawing.strokes.count, 1)
        XCTAssertEqual(restored.drawing.strokes[0].path[1].force, 0.8, accuracy: 0.001)
        XCTAssertEqual(restored.drawing.strokes[0].path[1].size.width, 9.6, accuracy: 0.001)
        XCTAssertEqual(restored.drawing.strokes[0].transform.tx, 30, accuracy: 0.001)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.svg-image")
        attachment.name = "native-notebook-editable-svg"; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testPortableSVGWithoutNativeDataKeepsForceAndEditableObjects() throws {
        var page = NotebookPage(); page.capture(drawing()); page.inkData = nil
        page.elements = [NotebookElement(text: "文字\n仍可编辑", bold: true)]
        let restored = try NotebookSVG.restore(NotebookSVG.export(page))
        XCTAssertEqual(restored.drawing.strokes[0].path[0].force, 0.2, accuracy: 0.001)
        XCTAssertEqual(restored.elements, page.elements)
        XCTAssertEqual(restored.strokes[0].points.map(\.width), page.strokes[0].points.map(\.width))
    }
    func testRightAndBottomGrowthDoesNotMoveInkOrTopLeftOrigin() throws {
        var page = NotebookPage(); page.capture(drawing())
        let before = page.strokes
        page.grow(to: 6000, y: 8500)
        XCTAssertGreaterThanOrEqual(page.width, 6000); XCTAssertGreaterThanOrEqual(page.height, 8500)
        XCTAssertEqual(page.strokes, before)
        page.grow(to: 500, y: 500); XCTAssertGreaterThanOrEqual(page.width, 6000)
        try NotebookCodec.validate(page)
    }
    func testBrowserSVGReconstructsPressureImagesAndEditableObjects() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "notebook-browser", withExtension: "svg"))
        let page = try NotebookSVG.restore(Data(contentsOf: url))
        XCTAssertEqual(page.title, "压力与图片 🖊")
        XCTAssertEqual(page.strokes.count, 2); XCTAssertNil(page.inkData)
        XCTAssertEqual(page.drawing.strokes.count, 2)
        XCTAssertEqual(page.drawing.strokes[1].path[0].force, 0.15, accuracy: 0.001)
        XCTAssertGreaterThan(Set(page.strokes[1].points.map(\.width)).count, 8)
        XCTAssertEqual(page.elements.count, 2)
        XCTAssertTrue(page.elements[0].text.contains("电机 & <公式> 🖊"))
        XCTAssertNotNil(NotebookCodec.imageData(page.elements[1].dataURI))
        XCTAssertGreaterThan(page.width, 1600); XCTAssertGreaterThan(page.height, 2400)
    }
    func testNotebookBackupKeepsHierarchyImagesAndPressure() throws {
        var page = NotebookPage(); page.capture(drawing())
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { c in UIColor.blue.setFill(); c.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }.pngData()!
        page.elements = [NotebookElement(kind: "image", dataURI: "data:image/png;base64," + image.base64EncodedString())]
        let section = NotebookSection(pages: [page]), book = NotebookBook(sections: [section])
        let document = NotebookDocument(notebooks: [book], notebookID: book.id, sectionID: section.id, pageID: page.id)
        let restored = try JSONDecoder().decode(NotebookDocument.self, from: JSONEncoder().encode(document))
        try NotebookCodec.validate(restored)
        XCTAssertEqual(restored.notebooks, document.notebooks)
        var broken = page; broken.strokes[0].points[0].width = -1
        XCTAssertThrowsError(try NotebookCodec.validate(broken))
        XCTAssertThrowsError(try NotebookSVG.restore(Data("<!DOCTYPE svg [<!ENTITY x SYSTEM 'file:///private/test'>]><svg/>".utf8)))
    }
}
