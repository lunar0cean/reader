import XCTest
import UIKit
import PDFKit
import PencilKit
@testable import YeJian

final class FormatImportTests: XCTestCase {
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: XCTUnwrap(Bundle.main.url(forResource: name, withExtension: ext)))
    }
    func testEPUBSpineOrderMetadataImagesAndOriginalAreRetained() throws {
        let bytes = try fixture("sample-illustrated", "epub")
        let book = try ReaderImport.file(data: bytes, name: "sample.epub")
        XCTAssertEqual(book.title, "有插图的 EPUB"); XCTAssertEqual(book.author, "页间测试")
        XCTAssertEqual(book.chapters.map(\.href), ["OPS/text/one.xhtml", "OPS/text/two.xhtml"])
        XCTAssertEqual(book.chapters.map(\.title), ["第一章：阅读", "第二章：出处"])
        XCTAssertTrue(book.chapters[0].text.contains("📚")); XCTAssertTrue(book.chapters[1].text.contains("引用跳转"))
        let key = try XCTUnwrap(book.chapters[0].images?.values.first)
        XCTAssertNotNil(ReaderImages.image(try XCTUnwrap(book.assets?[key])))
        XCTAssertEqual(book.original, bytes)
        let pages = ReaderPagination.pages(book: book, layout: PageLayout())
        for chapter in book.chapters { XCTAssertEqual(pages.filter { $0.chapterID == chapter.id }.map { $0.body.string }.joined(), chapter.text) }
        XCTAssertTrue(pages.contains { page in
            var hasImage = false
            page.body.enumerateAttribute(.readerImage, in: NSRange(location: 0, length: page.body.length)) { image, _, _ in hasImage = hasImage || image != nil }
            return hasImage
        })
    }
    func testEPUBPathsCannotEscapeArchive() {
        XCTAssertEqual(ReaderImport.resourcePath("../images/a%20b.png", from: "OPS/text/chapter.xhtml"), "OPS/images/a b.png")
        XCTAssertNil(ReaderImport.resourcePath("../../outside", from: "OPS/a.xhtml"))
        XCTAssertNil(ReaderImport.resourcePath("https://remote/image", from: "OPS/a.xhtml"))
        XCTAssertNil(ReaderImport.resourcePath("%2foutside", from: "OPS/a.xhtml"))
    }
    func testMalformedHTMLExtractsArticleAndExcludesExecutableAndNavigationContent() throws {
        let bytes = try fixture("sample-article", "html")
        let url = try XCTUnwrap(URL(string: "https://example.com/article"))
        let book = try ReaderImport.article(data: bytes, name: "article.html", source: url)
        XCTAssertEqual(book.source, url.absoluteString); XCTAssertEqual(book.original, bytes)
        XCTAssertTrue(book.chapters[0].text.contains("重要文字 与 & 实体"))
        for removed in ["首页广告", "推荐广告", "window.injected", "版权导航"] { XCTAssertFalse(book.chapters[0].text.contains(removed)) }
        XCTAssertThrowsError(try ReaderImport.webURL("file:///etc/passwd"))
        XCTAssertThrowsError(try ReaderImport.webURL("javascript:alert(1)"))
        let malformed = try ReaderHTML.extract("<main><p>第一段<p>第二段</main>", article: true)
        XCTAssertEqual(malformed.blocks.map(\.text), ["第一段", "第二段"])
    }
    func testPDFKeepsScannedPagesAndFixedPageNumbers() throws {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 560)
        let bytes = UIGraphicsPDFRenderer(bounds: rect).pdfData { context in
            context.beginPage(); ("PDF page one source" as NSString).draw(at: CGPoint(x: 40, y: 60), withAttributes: [.font: UIFont.systemFont(ofSize: 22)])
            context.beginPage(); UIColor.systemBlue.setFill(); context.cgContext.fill(CGRect(x: 50, y: 50, width: 300, height: 200))
        }
        let book = try ReaderImport.pdf(data: bytes, name: "sample.pdf")
        XCTAssertEqual(book.original, bytes); XCTAssertEqual(book.chapters.count, 2)
        XCTAssertTrue(book.chapters[0].text.contains("PDF page one source")); XCTAssertEqual(book.chapters[1].text, "")
        let pages = ReaderPagination.pages(book: book, layout: PageLayout())
        XCTAssertEqual(pages.map(\.pdfPage), [0, 1]); XCTAssertEqual(pages.count, 2)
        XCTAssertFalse((book.importWarnings ?? []).isEmpty)
    }
    @MainActor func testFormatBackupRestoresSourceAssetsInkAndCitationJump() throws {
        let epub = try ReaderImport.file(data: fixture("sample-illustrated", "epub"), name: "sample.epub")
        let store = ReaderStore(); let previous = store.backup
        defer { store.backup = previous; store.repaginate(); store.save() }
        store.backup.books.append(epub); store.selectBook(epub.id)
        let chapter = epub.chapters[1], anchor = store.anchor(chapter: chapter, paragraph: 0)
        store.jump(to: anchor); XCTAssertEqual(store.currentPage?.chapterID, chapter.id); XCTAssertEqual(anchor.href, chapter.href)
        store.addNote("带出处的笔记", anchor: anchor)
        let first = store.spreadKey(start: 0)
        let path = PKStrokePath(controlPoints: [CGPoint(x: 650, y: 200), CGPoint(x: 710, y: 210)].map {
            PKStrokePoint(location: $0, timeOffset: 0, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2)
        }, creationDate: Date())
        store.saveSpreadDrawing(PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .blue), path: path)]), pageID: first, bookID: epub.id)
        let restored = try ReaderStore.decodeBackup(JSONEncoder().encode(store.backup))
        XCTAssertEqual(restored.version, 3); XCTAssertEqual(restored.books.last?.original, epub.original)
        XCTAssertEqual(restored.books.last?.assets, epub.assets)
        XCTAssertEqual(try PKDrawing(data: XCTUnwrap(restored.readingState[epub.id]?.spreadDrawings[first])).strokes.count, 1)
        XCTAssertEqual(restored.notes.last?.anchor, anchor)
        let exported = try XCTUnwrap(store.exportPDF()), pdf = try XCTUnwrap(PDFDocument(url: exported))
        XCTAssertEqual(pdf.pageCount, store.pages.count)
    }
}

private final class ArticleFixtureProtocol: URLProtocol {
    static var html = Data(), image = Data()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let isImage = url.path == "/picture.png"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": isImage ? "image/png" : "text/html; charset=utf-8"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: isImage ? Self.image : Self.html)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
extension FormatImportTests {
    func testArticleNetworkImportSavesRelativeImagesAndSourceForOfflineReading() async throws {
        let epub = try ReaderImport.file(data: fixture("sample-illustrated", "epub"), name: "sample.epub")
        let image = try XCTUnwrap(epub.assets?.values.first)
        let html = "<html><head><title>网络文章</title></head><body><article><h1>网络文章</h1><p>正文。</p><img src='/picture.png' alt='插图'><p>图片后的文字。</p></article></body></html>"
        ArticleFixtureProtocol.html = Data(html.utf8); ArticleFixtureProtocol.image = image
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [ArticleFixtureProtocol.self]
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        let book = try await ReaderImport.fetchArticle("https://example.test/article", session: session)
        XCTAssertEqual(book.source, "https://example.test/article"); XCTAssertEqual(book.original, Data(html.utf8))
        let chapter = book.chapters[0], key = try XCTUnwrap(chapter.images?[1])
        XCTAssertEqual(chapter.paragraphs, ["正文。", "\u{FFFC}", "图片后的文字。"])
        XCTAssertEqual(book.assets?[key], image); XCTAssertTrue((book.importWarnings ?? []).isEmpty)
    }
    func testHTMLInlineImageAndPDFReplacementWithSameBookID() throws {
        let epub = try ReaderImport.file(data: fixture("sample-illustrated", "epub"), name: "sample.epub")
        let image = try XCTUnwrap(epub.assets?.values.first)
        let html = "<title>内嵌图片</title><article><p>正文</p><img src='data:image/png;base64,\(image.base64EncodedString())'></article>"
        let article = try ReaderImport.article(data: Data(html.utf8), name: "inline.html", source: nil)
        XCTAssertEqual(article.assets?.values.first, image); XCTAssertEqual(article.chapters[0].paragraphs.last, "\u{FFFC}")
        let bytes = try fixture("sample-fixed", "pdf")
        var first = try ReaderImport.pdf(data: bytes, name: "sample.pdf")
        XCTAssertEqual(ReaderPDF.document(first)?.pageCount, 3)
        let onePage = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 500)).pdfData { $0.beginPage() }
        first.original = onePage
        XCTAssertEqual(ReaderPDF.document(first)?.pageCount, 1)
    }
}

extension FormatImportTests {
    func testEPUB2NCXAllowsStandardDoctypeWithoutExternalEntities() throws {
        let book = try ReaderImport.file(data: fixture("sample-epub2", "epub"), name: "epub2.epub")
        XCTAssertEqual(book.chapters.map(\.title), ["NCX 第一章", "NCX 第二章"])
        XCTAssertThrowsError(try ReaderXML.parse(Data("<!DOCTYPE root [<!ENTITY inject 'bad'>]><root>&inject;</root>".utf8)))
    }
    func testChineseHTMLLegacyEncodingIsNotMistakenForUTF16() throws {
        let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let html = "<meta charset='gb18030'><title>中文文章</title><article><p>完整保留中文。</p></article>"
        let bytes = try XCTUnwrap(html.data(using: encoding))
        XCTAssertEqual(try ReaderHTML.decode(bytes), html)
        XCTAssertEqual(try ReaderImport.article(data: bytes, name: "chinese.html", source: nil).chapters[0].paragraphs, ["完整保留中文。"])
    }
}
