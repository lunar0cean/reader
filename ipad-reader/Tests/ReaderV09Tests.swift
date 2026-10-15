import XCTest
import UIKit
import PencilKit
import PDFKit
@testable import YeJian

final class ReaderV09Tests: XCTestCase {
    private func temporary() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true); return folder
    }
    func testProgressDoesNotRewriteOriginalBooksAndRestartReusesRecords() throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let legacy = folder.appendingPathComponent("old.json")
        let book = ReaderBook(id: "book", title: "一册", author: "", format: "TXT", color: "blue", chapters: [ReaderChapter(id: "chapter", title: "第一章", paragraphs: ["正文"])], original: Data(repeating: 42, count: 1_000_000))
        var state = NativeBackup(books: [book], readingState: [:], notes: [], bookmarks: [], currentBookID: book.id)
        let writer = ReaderLibraryPersistence(); try writer.write(state, legacy: legacy)
        let root = ReaderLibraryPersistence.folder(legacy)
        let initial = try PropertyListDecoder().decode(ReaderLibraryPersistence.Index.self, from: Data(contentsOf: root.appendingPathComponent("index.plist")))
        state.readingState[book.id] = BookReadingState(); state.readingState[book.id]?.pageIndex = 9
        try writer.write(state, legacy: legacy)
        let restarted = ReaderLibraryPersistence(), restored = try XCTUnwrap(restarted.restore(legacy))
        XCTAssertEqual(restored.books, [book]); XCTAssertEqual(restored.readingState[book.id]?.pageIndex, 9)
        try restarted.write(restored, legacy: legacy)
        let final = try PropertyListDecoder().decode(ReaderLibraryPersistence.Index.self, from: Data(contentsOf: root.appendingPathComponent("index.plist")))
        XCTAssertEqual(final.books, initial.books)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 2)
    }
    func testNotebookWritesOnlyChangedPageAndRetainsEditableInk() throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let legacy = folder.appendingPathComponent("old.json")
        var page = NotebookPage(), second = NotebookPage()
        second.title = "另一页"; page.elements = [NotebookElement(text: "保留文字对象")]
        let point = PKStrokePoint(location: CGPoint(x: 100, y: 200), timeOffset: 0, size: CGSize(width: 4, height: 4), opacity: 1, force: 0.6, azimuth: 0, altitude: 1)
        page.captureNative(PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .blue), path: PKStrokePath(controlPoints: [point], creationDate: Date()))]))
        let section = NotebookSection(pages: [page, second]), book = NotebookBook(sections: [section])
        var doc = NotebookDocument(notebooks: [book], notebookID: book.id, sectionID: section.id, pageID: page.id)
        let writer = NotebookLibraryPersistence(); try writer.write(doc, legacy: legacy)
        let root = NotebookLibraryPersistence.folder(legacy), index = root.appendingPathComponent("index.plist")
        let first = try PropertyListDecoder().decode(NotebookLibraryPersistence.Index.self, from: Data(contentsOf: index))
        doc.notebooks[0].sections[0].pages[0].title = "修改标题"; try writer.write(doc, legacy: legacy)
        let final = try PropertyListDecoder().decode(NotebookLibraryPersistence.Index.self, from: Data(contentsOf: index))
        XCTAssertEqual(first.pages[second.id], final.pages[second.id]); XCTAssertNotEqual(first.pages[page.id], final.pages[page.id])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path).count, 3)
        let restored = try XCTUnwrap(NotebookLibraryPersistence.load(legacy))
        XCTAssertEqual(restored.notebooks, doc.notebooks)
        XCTAssertEqual(restored.notebooks[0].sections[0].pages[0].drawing.strokes.count, 1)
    }
    func testCorruptOrTraversingIndexIsRejectedWithoutChangingFiles() throws {
        let folder = try temporary(); defer { try? FileManager.default.removeItem(at: folder) }
        let legacy = folder.appendingPathComponent("old.json"), root = ReaderLibraryPersistence.folder(legacy)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let state = NativeBackup(books: [], readingState: [:], notes: [], bookmarks: [], currentBookID: "")
        let encoded = try PropertyListEncoder().encode(ReaderLibraryPersistence.Index(state: state, books: ["../outside.plist"]))
        let index = root.appendingPathComponent("index.plist"); try encoded.write(to: index)
        XCTAssertThrowsError(try ReaderLibraryPersistence.load(legacy)); XCTAssertEqual(try Data(contentsOf: index), encoded)
    }
    func testSpeechRangesPreserveEmojiAttachmentsAndResumeBoundary() {
        let source = "第一句📚。\u{FFFC}第二句。日本語です！"
        let chunks = SpeechText.chunks(source)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0].text, "第一句📚。"); XCTAssertEqual(chunks[1].text, "第二句。")
        let original = source as NSString
        XCTAssertEqual(original.substring(with: chunks[1].range), "\u{FFFC}第二句。")
        XCTAssertEqual(SpeechText.chunks(source, from: chunks[1].range.location), Array(chunks.dropFirst()))
        XCTAssertEqual(SpeechText.language("こんにちは。"), "ja"); XCTAssertEqual(SpeechText.language("中文内容。"), "zh")
        XCTAssertTrue(SpeechText.chunks(source, from: original.length).isEmpty)
    }
    func testLegacySymbolAndGroupContentAreRenderedAndSelectable() throws {
        ReaderFont.register()
        XCTAssertEqual(ReaderSlideSymbols.text("If \u{F0AE}\u{F0A5} \u{F0DE} stable", typeface: "Symbol"), "If →∞ ⇒ stable")
        XCTAssertEqual(ReaderSlideSymbols.bytes([0x61, 0xAE, 0xA5]), "α→∞")
        XCTAssertEqual(ReaderSlideSymbols.mathExtra([0x4C, 0x4D]), "⋯⋮")
        let url = try XCTUnwrap(Bundle.main.url(forResource: "sample-legacy-math", withExtension: "pptx"))
        let book = try ReaderSlides.book(data: Data(contentsOf: url), name: "regression.pptx")
        XCTAssertEqual(book.slideRendererVersion, ReaderSlides.version); XCTAssertEqual(book.chapters.count, 2)
        let pdf = try XCTUnwrap(PDFDocument(data: XCTUnwrap(book.renderedPDF))), text = pdf.page(at: 0).map(ReaderPDFText.source) ?? ""
        XCTAssertTrue(text.contains("Steady-state")); XCTAssertTrue(text.contains("Output")); XCTAssertTrue(text.contains("stability"))
        XCTAssertTrue(text.contains("→")); XCTAssertTrue(text.contains("∞")); XCTAssertTrue(text.contains("⇒"))
        XCTAssertFalse(text.unicodeScalars.contains { (0xF000...0xF0FF).contains($0.value) })
        XCTAssertTrue((pdf.page(at: 1).map(ReaderPDFText.source) ?? "").contains("⋯"), "MT Extra ellipsis must not become a Greek letter")
        for i in 0..<2 {
            let image = try XCTUnwrap(pdf.page(at: i)?.thumbnail(of: CGSize(width: 1000, height: 750), for: .cropBox))
            let attachment = XCTAttachment(image: image); attachment.name = "legacy-slide-\(i + 1)"; attachment.lifetime = .keepAlways; add(attachment)
            if i == 0 {
                let cg = try XCTUnwrap(image.cgImage)
                // The grouped white labels must keep both their blue fill and visible text.
                for region in [CGRect(x: 0.59, y: 0.86, width: 0.14, height: 0.06), CGRect(x: 0.09, y: 0.84, width: 0.18, height: 0.08)] {
                    let crop = try XCTUnwrap(cg.cropping(to: region.applying(CGAffineTransform(scaleX: CGFloat(cg.width), y: CGFloat(cg.height)))))
                    var bytes = [UInt8](repeating: 255, count: crop.width * crop.height * 4)
                    try bytes.withUnsafeMutableBytes { buffer in
                        let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                        context.draw(crop, in: CGRect(x: 0, y: 0, width: CGFloat(crop.width), height: CGFloat(crop.height)))
                    }
                    let blue = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] < 50 && bytes[$0 + 1] < 50 && bytes[$0 + 2] > 80 }.count
                    XCTAssertGreaterThan(blue, crop.width * crop.height / 3, "White labels need visible blue backgrounds")
                    let white = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 220 && bytes[$0 + 1] > 220 && bytes[$0 + 2] > 220 }.count
                    XCTAssertGreaterThan(white, crop.width * crop.height / 40, "Grouped labels must not be enlarged outside the visible page")
                }
            }
        }
    }
    func testWMFEquationProducesPixelsAndRejectsTruncatedRecords() throws {
        ReaderFont.register()
        let url = try XCTUnwrap(Bundle.main.url(forResource: "sample-equation", withExtension: "wmf"))
        let data = try Data(contentsOf: url)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 150)).image { c in
            UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 600, height: 150))
            XCTAssertTrue(ReaderWMF.draw(data, into: CGRect(x: 10, y: 10, width: 580, height: 130), context: c.cgContext))
        }
        let attachment = XCTAttachment(image: image); attachment.name = "legacy-wmf-equation"; attachment.lifetime = .keepAlways; add(attachment)
        let cg = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 255, count: cg.width * cg.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(cg.width), height: CGFloat(cg.height)))
        }
        XCTAssertTrue(stride(from: 0, to: pixels.count, by: 4).contains { pixels[$0] < 100 && pixels[$0 + 1] < 100 && pixels[$0 + 2] < 100 }, "Equation must contain visible ink")
        _ = UIGraphicsImageRenderer(size: CGSize(width: 10, height: 10)).image { c in
            XCTAssertFalse(ReaderWMF.draw(Data(data.prefix(42)), into: CGRect(x: 0, y: 0, width: 10, height: 10), context: c.cgContext))
        }
    }
    func testPDFTextKeepsCharacterOffsetsForSelectionAndSpeech() throws {
        let data = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 500)).pdfData { c in
            c.beginPage()
            ("First sentence.\nSecond sentence." as NSString).draw(in: CGRect(x: 30, y: 100, width: 330, height: 100), withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
        }
        let document = try XCTUnwrap(PDFDocument(data: data))
        defer { withExtendedLifetime(document) {} }
        let page = try XCTUnwrap(document.page(at: 0)), source = ReaderPDFText.source(page)
        let imported = try ReaderImport.pdf(data: data, name: "speech.pdf")
        XCTAssertEqual(imported.pdfTextVersion, 2)
        XCTAssertEqual(imported.chapters[0].paragraphs, [source])
        XCTAssertEqual((source as NSString).length, page.numberOfCharacters)
        for chunk in SpeechText.chunks(source) {
            let range = try XCTUnwrap(ReaderPDFText.range(count: page.numberOfCharacters, from: chunk.range.location, to: NSMaxRange(chunk.range) - 1))
            XCTAssertNotNil(page.selection(for: range))
        }
    }
}
