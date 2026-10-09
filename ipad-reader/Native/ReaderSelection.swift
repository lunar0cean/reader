import UIKit
import CoreText
import PDFKit
import SwiftUI

struct ReaderMedia: Identifiable {
    let id = UUID()
    let image: UIImage
}

/// Hit testing and selection use the very same CoreText frame as pagination.
/// No second text renderer or invisible web page can drift away from the ink.
final class ReaderTextGeometry {
    let frame: CTFrame
    let rect: CGRect
    let text: NSString
    let visible: NSRange
    let lines: [CTLine]
    let origins: [CGPoint]
    init(page: ReadingPage, book: ReaderBook, layout: PageLayout) {
        let full = layout.typographyVersion >= 2
        let body = full ? page.fullBody : page.body
        text = body.string as NSString
        visible = full ? page.range : NSRange(location: 0, length: body.length)
        rect = ReaderPagination.bodyRect(layout, opening: book.format != "MD" && page.range.location == 0)
        let setter = CTFramesetterCreateWithAttributedString(body as CFAttributedString)
        frame = CTFramesetterCreateFrame(setter, CFRange(location: visible.location, length: visible.length), CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil), nil)
        lines = CTFrameGetLines(frame) as! [CTLine]
        var values = Array(repeating: CGPoint.zero, count: lines.count)
        CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &values); origins = values
    }
    func lineRect(_ i: Int) -> CGRect {
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CTLineGetTypographicBounds(lines[i], &ascent, &descent, nil)
        return CGRect(x: rect.minX + origins[i].x, y: rect.maxY - origins[i].y - ascent, width: max(1, width), height: ascent + descent)
    }
    func index(at point: CGPoint) -> Int? {
        guard !lines.isEmpty else { return nil }
        let i = lines.indices.min { abs(lineRect($0).midY - point.y) < abs(lineRect($1).midY - point.y) }!
        let raw = CTLineGetStringIndexForPosition(lines[i], CGPoint(x: point.x - rect.minX - origins[i].x, y: 0))
        guard raw != kCFNotFound, visible.length > 0 else { return nil }
        return max(visible.location, min(NSMaxRange(visible) - 1, raw))
    }
    func word(at point: CGPoint) -> NSRange? {
        guard let index = index(at: point), rect.contains(point), !images().contains(where: { $0.0.contains(point) }) else { return nil }
        var word = text.rangeOfComposedCharacterSequence(at: index)
        let string = text as String
        let line = lines.first { let r = CTLineGetStringRange($0); return index >= r.location && index < r.location + r.length }
        let source = line.map { CTLineGetStringRange($0) }
        let local = source.map { NSIntersectionRange(visible, NSRange(location: $0.location, length: $0.length)) } ?? visible
        guard let bounded = Range(text.rangeOfComposedCharacterSequences(for: local), in: string) else { return word }
        string.enumerateSubstrings(in: bounded, options: [.byWords, .substringNotRequired]) { _, range, _, stop in
            let r = NSRange(range, in: string)
            if NSLocationInRange(index, r) { word = r; stop = true }
        }
        return NSIntersectionRange(word, visible)
    }
    func rectangles(for range: NSRange) -> [CGRect] {
        lines.indices.compactMap { i in
            let source = CTLineGetStringRange(lines[i]), hit = NSIntersectionRange(range, NSRange(location: source.location, length: source.length))
            guard hit.length > 0 else { return nil }
            let a = CTLineGetOffsetForStringIndex(lines[i], hit.location, nil), b = CTLineGetOffsetForStringIndex(lines[i], NSMaxRange(hit), nil)
            var box = lineRect(i); box.origin.x += min(a, b); box.size.width = max(3, abs(b - a)); return box
        }
    }
    func images() -> [(CGRect, ReaderImageMetrics)] {
        var result: [(CGRect, ReaderImageMetrics)] = []
        for i in lines.indices {
            for run in CTLineGetGlyphRuns(lines[i]) as! [CTRun] {
                guard let image = (CTRunGetAttributes(run) as NSDictionary)[NSAttributedString.Key.readerImage] as? ReaderImageMetrics else { continue }
                var position = CGPoint.zero; CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
                result.append((CGRect(x: rect.minX + origins[i].x + position.x, y: rect.maxY - origins[i].y - image.height, width: image.width, height: image.height), image))
            }
        }
        return result
    }
}

final class ReaderSelectionView: UIView, UIGestureRecognizerDelegate, UIEditMenuInteractionDelegate {
    weak var paper: PaperUIView?
    var geometry: ReaderTextGeometry?
    var selection: NSRange?
    private var pdfSelection: PDFSelection?
    private var anchorIndex = 0
    private var movingStart = false
    private let highlight = CAShapeLayer(), handles = CAShapeLayer()
    private lazy var editMenu = UIEditMenuInteraction(delegate: self)
    lazy var hold = UILongPressGestureRecognizer(target: self, action: #selector(selectText(_:)))
    lazy var drag = UIPanGestureRecognizer(target: self, action: #selector(moveHandle(_:)))
    private lazy var tap = UITapGestureRecognizer(target: self, action: #selector(tapContent(_:)))
    var hasSelection: Bool { selection != nil || pdfSelection != nil }
    private var pdfPage: PDFPage? {
        guard let paper, let book = paper.book, let index = paper.page?.pdfPage else { return nil }
        return ReaderPDF.document(book)?.page(at: index)
    }
    override init(frame: CGRect) {
        super.init(frame: frame); backgroundColor = .clear
        hold.minimumPressDuration = 0.32; hold.delegate = self
        for gesture in [hold, drag, tap] {
            gesture.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]; addGestureRecognizer(gesture)
        }
        drag.maximumNumberOfTouches = 1; drag.delegate = self; tap.delegate = self
        tap.numberOfTapsRequired = 2
        tap.require(toFail: hold); tap.require(toFail: drag)
        highlight.fillColor = UIColor.systemBlue.withAlphaComponent(0.20).cgColor
        handles.strokeColor = UIColor.systemBlue.cgColor; handles.fillColor = UIColor.systemBlue.cgColor; handles.lineWidth = 2
        layer.addSublayer(highlight); layer.addSublayer(handles); addInteraction(editMenu)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if event?.allTouches?.contains(where: { $0.type == .pencil }) == true { return nil }
        return super.hitTest(point, with: event)
    }
    func reload() {
        clear()
        if let paper, let page = paper.page, let book = paper.book, page.pdfPage == nil { geometry = ReaderTextGeometry(page: page, book: book, layout: paper.layout) }
        else { geometry = nil }
    }
    func clear() { selection = nil; pdfSelection = nil; highlight.path = nil; handles.path = nil; editMenu.dismissMenu() }
    private func pdfPoint(_ point: CGPoint) -> CGPoint? {
        guard let page = pdfPage, let transform = ReaderPDF.transform(page, into: bounds) else { return nil }
        return CGPoint(x: point.x, y: bounds.height - point.y).applying(transform.inverted())
    }
    private func viewRect(_ rect: CGRect) -> CGRect {
        guard let page = pdfPage, let transform = ReaderPDF.transform(page, into: bounds) else { return .zero }
        let r = rect.applying(transform); return CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height)
    }
    var selectedText: String {
        if let selection, let geometry { return geometry.text.substring(with: selection).replacingOccurrences(of: "\u{FFFC}", with: "") }
        return pdfSelection?.string ?? ""
    }
    private var selectedRects: [CGRect] {
        if let selection, let geometry { return geometry.rectangles(for: selection) }
        guard let pdfPage else { return [] }
        return pdfSelection?.selectionsByLine().map { viewRect($0.bounds(for: pdfPage)) } ?? []
    }
    private var endpoints: (CGPoint, CGPoint)? {
        guard let first = selectedRects.first, let last = selectedRects.last else { return nil }
        return (CGPoint(x: first.minX, y: first.minY), CGPoint(x: last.maxX, y: last.maxY))
    }
    private func redraw() {
        let path = CGMutablePath(); for rect in selectedRects { path.addRect(rect) }; highlight.path = path
        let points = CGMutablePath()
        if let (a, b) = endpoints {
            for p in [a, b] { points.addEllipse(in: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)) }
        }
        handles.path = points
    }
    private func showMenu() {
        guard hasSelection, !selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { clear(); return }
        let first = selectedRects.first ?? bounds
        editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: first.midX, y: first.minY)))
    }
    @objc private func selectText(_ gesture: UILongPressGestureRecognizer) {
        let p = gesture.location(in: self)
        if gesture.state == .began {
            if let geometry, let word = geometry.word(at: p), word.length > 0 { selection = word; anchorIndex = word.location }
            else if let page = pdfPage, let point = pdfPoint(p), let word = ReaderPDFText.word(page, at: point) {
                pdfSelection = word; anchorIndex = page.characterIndex(at: point)
            }
            redraw()
        } else if gesture.state == .changed { extend(to: p, from: anchorIndex); redraw() }
        else if gesture.state == .ended { showMenu() }
    }
    private func extend(to p: CGPoint, from index: Int) {
        if let geometry, let to = geometry.index(at: p) {
            selection = NSIntersectionRange(NSRange(location: min(index, to), length: abs(to - index) + 1), geometry.visible)
            if let selection { self.selection = NSIntersectionRange(geometry.text.rangeOfComposedCharacterSequences(for: selection), geometry.visible) }
        } else if pdfSelection != nil, let page = pdfPage, let point = pdfPoint(p),
                  let range = ReaderPDFText.range(count: page.numberOfCharacters, from: index, to: page.characterIndex(at: point)) {
            pdfSelection = page.selection(for: range)
        }
    }
    @objc private func moveHandle(_ gesture: UIPanGestureRecognizer) {
        let p = gesture.location(in: self)
        if gesture.state == .began, let (a, b) = endpoints {
            movingStart = hypot(p.x - a.x, p.y - a.y) < hypot(p.x - b.x, p.y - b.y)
            if let selection { anchorIndex = movingStart ? NSMaxRange(selection) - 1 : selection.location }
            else if let page = pdfPage, let point = pdfPoint(movingStart ? CGPoint(x: b.x - 2, y: b.y - 2) : CGPoint(x: a.x + 2, y: a.y + 2)) {
                let index = page.characterIndex(at: point)
                guard ReaderPDFText.range(count: page.numberOfCharacters, from: index, to: index) != nil else { return }
                anchorIndex = index
            }
            editMenu.dismissMenu()
        }
        if gesture.state == .began || gesture.state == .changed { extend(to: p, from: anchorIndex); redraw() }
        if gesture.state == .ended { showMenu() }
    }
    func image(at point: CGPoint) -> UIImage? {
        if let item = geometry?.images().first(where: { $0.0.contains(point) }) {
            return item.1.data.flatMap { UIImage(data: $0) } ?? UIImage(cgImage: item.1.image)
        }
        guard let paper, let book = paper.book, let index = paper.page?.pdfPage, let page = pdfPage,
              ReaderPDF.transform(page, into: bounds) != nil else { return nil }
        let regions = ReaderPDFImages.rectangles(book: book, index: index).map { viewRect($0).intersection(bounds) }
        guard let region = regions.reversed().first(where: { $0.contains(point) }), region.width > 2, region.height > 2 else { return nil }
        let factor = min(3, 2048 / max(region.width, region.height))
        let format = UIGraphicsImageRendererFormat(); format.scale = factor
        return UIGraphicsImageRenderer(size: region.size, format: format).image { output in
            output.cgContext.translateBy(x: -region.minX, y: -region.minY)
            ReaderPDF.draw(book: book, index: index, in: output.cgContext, rect: bounds)
        }
    }
    func handlesTap(at point: CGPoint) -> Bool {
        if hasSelection { return true }
        if geometry?.images().contains(where: { $0.0.contains(point) }) == true { return true }
        guard let paper, let book = paper.book, let index = paper.page?.pdfPage else { return false }
        return ReaderPDFImages.rectangles(book: book, index: index).contains { viewRect($0).contains(point) }
    }
    @objc private func tapContent(_ gesture: UITapGestureRecognizer) {
        let p = gesture.location(in: self)
        if let image = image(at: p) { clear(); paper?.onImage?(image) }
        else if hasSelection { clear() }
    }
    override func gestureRecognizerShouldBegin(_ gesture: UIGestureRecognizer) -> Bool {
        let p = gesture.location(in: self)
        if gesture === drag {
            guard let (a, b) = endpoints else { return false }
            return min(hypot(p.x - a.x, p.y - a.y), hypot(p.x - b.x, p.y - b.y)) < 32
        }
        if gesture === tap { return handlesTap(at: p) }
        if gesture === hold {
            // Consume a genuine hold on a picture without selecting text.
            // Otherwise consecutive holds can count as a double tap.
            if handlesTap(at: p) { return true }
            if geometry?.word(at: p) != nil { return true }
            guard let page = pdfPage, let point = pdfPoint(p) else { return false }
            return ReaderPDFText.word(page, at: point) != nil
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: [
            UIAction(title: "复制", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in UIPasteboard.general.string = self?.selectedText; self?.clear() },
            UIAction(title: "全选本页") { [weak self] _ in
                guard let self else { return }; self.selection = self.geometry?.visible
                if let page = self.pdfPage, page.numberOfCharacters > 0 { self.pdfSelection = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)) }
                self.redraw(); self.editMenu.reloadVisibleMenu()
            },
            UIAction(title: "朗读", image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in
                guard let self else { return }; self.paper?.onRead?(self.selectedText); self.clear()
            }
        ])
    }
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect { selectedRects.first ?? bounds }
}

struct ReaderImageViewer: View {
    let media: ReaderMedia
    @Environment(\.dismiss) private var dismiss
    @State private var sharing = false
    var body: some View {
        NavigationStack {
            ZoomableReaderImage(image: media.image, close: { dismiss() }).background(.black).ignoresSafeArea(edges: .bottom)
                .navigationTitle("图片").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button("复制", systemImage: "doc.on.doc") { UIPasteboard.general.image = media.image }
                        Button("分享", systemImage: "square.and.arrow.up") { sharing = true }
                    }
                }.sheet(isPresented: $sharing) { ActivityShare(items: [media.image]) }
        }.accessibilityIdentifier("reader-image-viewer")
    }
}
private struct ZoomableReaderImage: UIViewRepresentable {
    let image: UIImage
    var close: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(close: close) }
    func makeUIView(context: Context) -> ImageScroll {
        let scroll = ImageScroll(); scroll.image.image = image; scroll.image.frame = CGRect(origin: .zero, size: image.size)
        scroll.addSubview(scroll.image); scroll.contentSize = image.size
        scroll.delegate = context.coordinator; scroll.contentInsetAdjustmentBehavior = .never
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.dismissImage))
        double.numberOfTapsRequired = 2; scroll.addGestureRecognizer(double)
        scroll.accessibilityIdentifier = "reader-image-zoom"; return scroll
    }
    func updateUIView(_ view: ImageScroll, context: Context) {}
    final class Coordinator: NSObject, UIScrollViewDelegate {
        var close: () -> Void
        init(close: @escaping () -> Void) { self.close = close }
        @objc func dismissImage() { close() }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ImageScroll)?.image }
    }
    final class ImageScroll: UIScrollView {
        let image = UIImageView(); private var measured = CGSize.zero
        override func layoutSubviews() {
            super.layoutSubviews()
            guard let size = image.image?.size, size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return }
            if bounds.size != measured {
                measured = bounds.size
                let fit = min(bounds.width / size.width, bounds.height / size.height)
                minimumZoomScale = fit; maximumZoomScale = max(4, fit * 6); setZoomScale(fit, animated: false)
            }
            let x = max(0, (bounds.width - size.width * zoomScale) / 2)
            let y = max(0, (bounds.height - size.height * zoomScale) / 2)
            let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
            if contentInset != inset { contentInset = inset }
        }
    }
}
