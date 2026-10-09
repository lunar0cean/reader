import UIKit
import PDFKit
import CoreText
import ImageIO

/// Fixed PDF pages occupy a stable logical leaf, sharing the existing pair ink canvas.
enum ReaderPDF {
    private final class CachedPDF { let bytes: Data; let document: PDFDocument; init(_ bytes: Data, _ document: PDFDocument) { self.bytes = bytes; self.document = document } }
    private static let cache = NSCache<NSString, CachedPDF>()
    static func releaseCache() { cache.removeAllObjects() }
    static func document(_ book: ReaderBook) -> PDFDocument? {
        let data = book.renderedPDF ?? book.original
        if let value = cache.object(forKey: book.id as NSString), value.bytes == data { return value.document }
        guard let data, let value = PDFDocument(data: data) else { return nil }
        cache.countLimit = 3; cache.setObject(CachedPDF(data, value), forKey: book.id as NSString); return value
    }
    static func pages(book: ReaderBook) -> [ReadingPage] {
        book.chapters.enumerated().map { index, chapter in
            let body = NSAttributedString(string: chapter.text)
            return ReadingPage(id: "\(book.id):pdf:\(index)", bookID: book.id, chapterID: chapter.id, chapterTitle: chapter.title, chapterIndex: index,
                               range: NSRange(location: 0, length: max(1, body.length)), firstParagraph: 0, firstParagraphOffset: 0, body: body, fullBody: body, pdfPage: index)
        }
    }
    static func transform(_ page: PDFPage, into rect: CGRect) -> CGAffineTransform? {
        page.pageRef?.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true)
    }
    static func draw(book: ReaderBook, index: Int, in context: CGContext, rect: CGRect, reference: SourceAnchor? = nil) {
        UIColor.white.setFill(); context.fill(rect)
        guard let page = document(book)?.page(at: index), let ref = page.pageRef, let transform = transform(page, into: CGRect(origin: .zero, size: rect.size)) else { return }
        context.saveGState(); context.translateBy(x: rect.minX, y: rect.maxY); context.scaleBy(x: 1, y: -1); context.concatenate(transform)
        context.drawPDFPage(ref)
        for annotation in page.annotations { annotation.draw(with: .cropBox, in: context) }
        if reference?.bookID == book.id, reference?.pdfPage == index,
           let quote = reference?.quote, !quote.isEmpty, let selection = page.selection(for: page.bounds(for: .cropBox)),
           let start = selection.string?.range(of: quote), let all = selection.string {
            let range = NSRange(start, in: all)
            if let match = page.selection(for: range) {
                context.setFillColor(UIColor.systemYellow.withAlphaComponent(0.25).cgColor)
                for line in match.selectionsByLine() { context.fill(line.bounds(for: page)) }
            }
        }
        context.restoreGState()
    }
}

final class ReaderImageMetrics {
    let image: CGImage; let width: CGFloat; let height: CGFloat
    let data: Data?
    init(image: CGImage, width: CGFloat, height: CGFloat, data: Data? = nil) { self.image = image; self.width = width; self.height = height; self.data = data }
}
extension NSAttributedString.Key { static let readerImage = NSAttributedString.Key("YeJianImage") }

enum ReaderImages {
    static func image(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
    static func attributed(chapter: ReaderChapter, book: ReaderBook, layout: PageLayout) -> NSAttributedString {
        let body = NSMutableAttributedString(attributedString: ReaderMarkdown.attributed(chapter: chapter, layout: layout))
        for (index, key) in chapter.images ?? [:] {
            guard chapter.paragraphRanges.indices.contains(index), let bytes = book.assets?[key], let image = image(bytes) else { continue }
            let maxWidth = CGFloat(layout.width - 2 * layout.margin)
            let maxHeight = CGFloat(layout.height - 220)
            let scale = min(maxWidth / CGFloat(image.width), maxHeight / CGFloat(image.height), 1)
            let metrics = ReaderImageMetrics(image: image, width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale, data: bytes)
            var callbacks = CTRunDelegateCallbacks(version: kCTRunDelegateCurrentVersion,
                dealloc: { ref in Unmanaged<ReaderImageMetrics>.fromOpaque(ref).release() },
                getAscent: { ref in Unmanaged<ReaderImageMetrics>.fromOpaque(ref).takeUnretainedValue().height },
                getDescent: { _ in 0 },
                getWidth: { ref in Unmanaged<ReaderImageMetrics>.fromOpaque(ref).takeUnretainedValue().width })
            let pointer = Unmanaged.passRetained(metrics).toOpaque()
            guard let delegate = CTRunDelegateCreate(&callbacks, pointer) else { Unmanaged<ReaderImageMetrics>.fromOpaque(pointer).release(); continue }
            let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center; paragraph.firstLineHeadIndent = 0
            paragraph.minimumLineHeight = metrics.height + 6; paragraph.maximumLineHeight = metrics.height + 6
            let range = chapter.paragraphRanges[index]
            body.addAttributes([NSAttributedString.Key(kCTRunDelegateAttributeName as String): delegate, .readerImage: metrics,
                                .foregroundColor: UIColor.clear, .paragraphStyle: paragraph], range: range)
        }
        return body
    }
    static func draw(_ frame: CTFrame, context: CGContext) {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
        for (index, line) in lines.enumerated() {
            for run in CTLineGetGlyphRuns(line) as! [CTRun] {
                let attributes = CTRunGetAttributes(run) as NSDictionary
                guard let image = attributes[NSAttributedString.Key.readerImage] as? ReaderImageMetrics else { continue }
                var position = CGPoint.zero; CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                context.draw(image.image, in: CGRect(x: origins[index].x + position.x, y: origins[index].y, width: image.width, height: image.height))
            }
        }
    }
}
