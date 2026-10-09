import SwiftUI
import UIKit
import PencilKit
import CoreText

enum ReaderPalette {
    static let sage = Color(red: 0, green: 0.36, blue: 0.44)
    static let panel = Color(white: 0.25)
    static let row = Color(white: 0.35)
    static let link = Color(red: 0.32, green: 0.80, blue: 0.88)
    static func paper(_ theme: String) -> UIColor {
        theme == "night" ? UIColor(red: 0.26, green: 0.26, blue: 0.24, alpha: 1) :
        theme == "sepia" ? UIColor(red: 0.91, green: 0.83, blue: 0.69, alpha: 1) :
        UIColor(red: 0.945, green: 0.875, blue: 0.753, alpha: 1)
    }
    static func ink(_ theme: String) -> UIColor {
        theme == "night" ? UIColor(red: 0.87, green: 0.9, blue: 0.84, alpha: 1) :
        UIColor(red: 0.396, green: 0.337, blue: 0.243, alpha: 1)
    }
    static func soft(_ theme: String) -> UIColor { ink(theme).withAlphaComponent(0.56) }
    static func shell(_ theme: String) -> Color {
        theme == "night" ? Color(red: 0.14, green: 0.17, blue: 0.15) : Color(red: 0.956, green: 0.958, blue: 0.94)
    }
    static func sidebar(_ theme: String) -> Color {
        theme == "night" ? Color(red: 0.125, green: 0.15, blue: 0.135) : Color(red: 0.966, green: 0.966, blue: 0.957)
    }
    static func desk(_ theme: String) -> Color {
        theme == "night" ? Color(red: 0.13, green: 0.15, blue: 0.14) : Color(red: 0.29, green: 0.28, blue: 0.25)
    }
}

struct PaperContentView: UIViewRepresentable {
    var page: ReadingPage
    var book: ReaderBook
    var layout: PageLayout
    var theme: String
    var pageNumber: Int
    var reference: SourceAnchor?
    var speech: SpeechMark? = nil
    var onImage: (UIImage) -> Void = { _ in }
    var onRead: (String) -> Void = { _ in }
    func makeUIView(context: Context) -> PaperUIView { PaperUIView() }
    func updateUIView(_ uiView: PaperUIView, context: Context) {
        uiView.onImage = onImage; uiView.onRead = onRead
        if uiView.speech != speech { uiView.speech = speech; uiView.speechView.setNeedsDisplay() }
        guard uiView.page?.id != page.id || uiView.layout != layout || uiView.theme != theme || uiView.reference != reference ||
              uiView.pageNumber != pageNumber || uiView.book?.id != book.id || uiView.book?.original != book.original || uiView.book?.renderedPDF != book.renderedPDF ||
              uiView.page?.body.isEqual(to: page.body) != true else { return }
        uiView.page = page; uiView.book = book; uiView.layout = layout
        uiView.theme = theme; uiView.pageNumber = pageNumber; uiView.reference = reference
        uiView.isAccessibilityElement = true; uiView.accessibilityIdentifier = "reader-paper-\(pageNumber)"
        uiView.accessibilityLabel = "第 \(pageNumber) 页原文"; uiView.accessibilityValue = page.body.string
        uiView.selectionView.reload()
        uiView.setNeedsDisplay()
    }
}

final class PaperUIView: UIView {
    var onImage: ((UIImage) -> Void)?
    var onRead: ((String) -> Void)?
    let selectionView = ReaderSelectionView()
    var page: ReadingPage?
    var book: ReaderBook?
    var layout = PageLayout()
    var theme = "paper"
    var pageNumber = 1
    var reference: SourceAnchor?
    var speech: SpeechMark?
    let speechView = ReaderSpeechOverlay()
    override init(frame: CGRect) {
        super.init(frame: frame); isOpaque = true; contentMode = .redraw
        selectionView.paper = self; selectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]; addSubview(selectionView)
        speechView.paper = self; speechView.isUserInteractionEnabled = false; speechView.backgroundColor = .clear; addSubview(speechView)
    }
    override func layoutSubviews() { super.layoutSubviews(); selectionView.frame = bounds; speechView.frame = bounds }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let page, let book else { return }
        if let index = page.pdfPage {
            ReaderPDF.draw(book: book, index: index, in: context, rect: bounds, reference: reference)
            return
        }
        ReaderPalette.paper(theme).setFill(); context.fill(bounds)
        let soft = ReaderPalette.soft(theme), ink = ReaderPalette.ink(theme)
        let margin = CGFloat(layout.margin)
        if layout.typographyVersion >= 3 {
            if page.range.location == 0 && book.format != "MD" {
                let centered = NSMutableParagraphStyle(); centered.alignment = .center
                (String(page.chapterIndex + 1) as NSString).draw(in: CGRect(x: margin, y: 46, width: bounds.width - 2 * margin, height: 30), withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: ink, .paragraphStyle: centered])
                let title = page.chapterTitle.replacingOccurrences(of: "^第.{1,4}章[\\s　]*", with: "", options: .regularExpression)
                (title as NSString).draw(in: CGRect(x: margin, y: 77, width: bounds.width - 2 * margin, height: 36), withAttributes: [.font: UIFont.systemFont(ofSize: 25, weight: .semibold), .foregroundColor: ink, .paragraphStyle: centered])
            }
        } else {
        (book.title as NSString).draw(in: CGRect(x: margin, y: 35, width: 500, height: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: soft])
        context.setStrokeColor(UIColor(red: 0.44, green: 0.38, blue: 0.25, alpha: 0.025).cgColor)
        context.setLineWidth(0.4)
        for y in stride(from: CGFloat(1), to: bounds.height, by: CGFloat(3)) {
            context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: bounds.width, y: y))
        }
        context.strokePath()
        ("第 \(page.chapterIndex + 1) 章" as NSString).draw(at: CGPoint(x: margin, y: 84), withAttributes: [.font: ReaderFont.serif(size: 11), .foregroundColor: soft, .kern: 2])
        let title = page.chapterTitle.components(separatedBy: "　").last ?? page.chapterTitle
        (title as NSString).draw(in: CGRect(x: margin, y: 111, width: 680 - 2 * margin, height: 42), withAttributes: [.font: ReaderFont.serif(size: 29), .foregroundColor: ink, .kern: 1])
        ("阅读器" as NSString).draw(at: CGPoint(x: margin, y: 879), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: soft, .kern: 2])
        (String(format: "%02d", pageNumber) as NSString).draw(at: CGPoint(x: 680 - margin - 20, y: 879), withAttributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: soft])
        }
        let usesSourceRange = layout.typographyVersion >= 2
        let body = NSMutableAttributedString(attributedString: usesSourceRange ? page.fullBody : page.body)
        body.enumerateAttribute(.readerImage, in: NSRange(location: 0, length: body.length)) { image, range, _ in
            body.addAttribute(.foregroundColor, value: image == nil ? ink : UIColor.clear, range: range)
        }
        body.enumerateAttribute(.link, in: NSRange(location: 0, length: body.length)) { link, range, _ in
            if link != nil { body.addAttribute(.foregroundColor, value: theme == "night" ? UIColor.systemCyan : UIColor.systemBlue, range: range) }
        }
        let framesetter = CTFramesetterCreateWithAttributedString(body as CFAttributedString)
        let bodyRect = ReaderPagination.bodyRect(layout, opening: book.format != "MD" && page.range.location == 0)
        let path = CGPath(rect: CGRect(origin: .zero, size: bodyRect.size), transform: nil)
        // Keep paragraph context across page breaks: a substring would apply the
        // first-line indent again when a paragraph continues on the next leaf.
        let frameRange = usesSourceRange ? CFRange(location: page.range.location, length: page.range.length) : CFRange(location: 0, length: body.length)
        let frame = CTFramesetterCreateFrame(framesetter, frameRange, path, nil)
        context.saveGState(); context.translateBy(x: bodyRect.minX, y: bodyRect.maxY); context.scaleBy(x: 1, y: -1); context.textMatrix = .identity
        if let reference, reference.bookID == book.id, reference.chapterID == page.chapterID,
           let chapter = book.chapters.first(where: { $0.id == reference.chapterID }), chapter.paragraphRanges.indices.contains(reference.paragraph) {
            let source = NSIntersectionRange(chapter.paragraphRanges[reference.paragraph], page.range)
            if source.length > 0 {
                let highlight = NSRange(location: source.location - (usesSourceRange ? 0 : page.range.location), length: source.length)
                let lines = CTFrameGetLines(frame) as! [CTLine]
                var origins = Array(repeating: CGPoint.zero, count: lines.count)
                CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
                UIColor(red: 0.60, green: 0.72, blue: 0.45, alpha: 0.22).setFill()
                for (index, line) in lines.enumerated() {
                    let range = CTLineGetStringRange(line)
                    let hit = NSIntersectionRange(NSRange(location: range.location, length: range.length), highlight)
                    guard hit.length > 0 else { continue }
                    let start: CGFloat = CTLineGetOffsetForStringIndex(line, hit.location, nil)
                    let end: CGFloat = CTLineGetOffsetForStringIndex(line, NSMaxRange(hit), nil)
                    let highlightWidth: CGFloat = max(CGFloat(3), end - start)
                    context.fill(CGRect(x: origins[index].x + start, y: origins[index].y - 5, width: highlightWidth, height: CGFloat(layout.fontSize + 8)))
                }
            }
        }
        CTFrameDraw(frame, context); ReaderImages.draw(frame, context: context); context.restoreGState()
    }
}

final class ReaderSpeechOverlay: UIView {
    weak var paper: PaperUIView?
    override func draw(_ rect: CGRect) {
        guard let paper, let page = paper.page, let book = paper.book, let mark = paper.speech, mark.sourceID == page.id,
              let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.systemCyan.withAlphaComponent(0.2).cgColor)
        if let index = page.pdfPage, let pdf = ReaderPDF.document(book)?.page(at: index),
           let range = ReaderPDFText.range(count: pdf.numberOfCharacters, from: mark.range.location, to: NSMaxRange(mark.range) - 1), let selection = pdf.selection(for: range),
           let transform = ReaderPDF.transform(pdf, into: paper.bounds) {
            for line in selection.selectionsByLine() {
                let box = line.bounds(for: pdf).applying(transform)
                context.fill(CGRect(x: box.minX, y: paper.bounds.height - box.maxY, width: box.width, height: box.height))
            }
        } else if let geometry = paper.selectionView.geometry {
            let source = paper.layout.typographyVersion >= 2 ? mark.range : NSRange(location: mark.range.location - page.range.location, length: mark.range.length)
            for box in geometry.rectangles(for: source) { context.fill(box) }
        }
    }
}

@MainActor
final class InkControls: ObservableObject {
    @Published var selectedTool = "pen"
    @Published var color = UserDefaults.standard.string(forKey: "reader-ink-color") ?? "#445D7B" {
        didSet { UserDefaults.standard.set(color, forKey: "reader-ink-color") }
    }
    @Published var width = UserDefaults.standard.object(forKey: "reader-ink-width") as? Double ?? 2.7 {
        didSet { UserDefaults.standard.set(width, forKey: "reader-ink-width") }
    }
    @Published var allowFinger = false
    @Published var canUndo = false
    @Published var canRedo = false
    weak var canvas: PKCanvasView?
    var isDrawing = false
    var drawingChanged: ((Bool) -> Void)?
    var tool: PKTool {
        if selectedTool == "eraser" { return PKEraserTool(.vector) }
        return PKInkingTool(selectedTool == "marker" ? .marker : .pen, color: UIColor(notebookHex: color), width: selectedTool == "marker" ? min(128, width * 4) : width)
    }
    func undo() { canvas?.undoManager?.undo(); refresh() }
    func redo() { canvas?.undoManager?.redo(); refresh() }
    func refresh() {
        let undo = canvas?.undoManager?.canUndo ?? false, redo = canvas?.undoManager?.canRedo ?? false
        if canUndo != undo { canUndo = undo }; if canRedo != redo { canRedo = redo }
    }
}

/// Keep drawing history independent of a hosting controller's responder chain.
final class ReaderInkCanvas: PKCanvasView {
    var passThroughFingers = false
    private let drawingHistory = UndoManager()
    override var undoManager: UndoManager? { drawingHistory }
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if passThroughFingers, event?.allTouches?.contains(where: { $0.type == .pencil }) != true { return nil }
        return super.hitTest(point, with: event)
    }
}

struct PencilSurface: UIViewRepresentable {
    var pageID: String
    var bookID: String
    var drawing: PKDrawing
    var sourceData: Data
    var editing: Bool
    var logicalSize: CGSize
    @ObservedObject var controls: InkControls
    var onChange: (PKDrawing, String, String) -> Void
    var onActivate: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = ReaderInkCanvas(); canvas.backgroundColor = .clear; canvas.isOpaque = false; canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1; canvas.maximumZoomScale = 1; canvas.contentSize = logicalSize; canvas.delegate = context.coordinator
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.accessibilityIdentifier = "continuous-ink-canvas"
        canvas.accessibilityLabel = "跨页批注画布"
        canvas.isAccessibilityElement = true
        context.coordinator.loaded = sourceData; canvas.drawing = drawing
        canvas.drawingPolicy = controls.allowFinger ? .anyInput : .pencilOnly
        canvas.passThroughFingers = !controls.allowFinger
        return canvas
    }
    func updateUIView(_ canvas: PKCanvasView, context: Context) {
        // SwiftUI can update while the tip is down. Replacing the drawing or
        // tool then cancels the in-progress stroke, including at the seam.
        guard !context.coordinator.isDrawing else { return }
        context.coordinator.parent = self; canvas.tool = controls.tool
        canvas.contentSize = logicalSize
        canvas.accessibilityValue = "\(drawing.strokes.count) 笔"
        if editing { controls.canvas = canvas }
        let desired = sourceData
        if desired != context.coordinator.loaded {
            context.coordinator.loaded = desired
            canvas.drawing = drawing
            canvas.undoManager?.removeAllActions()
        }
        canvas.isUserInteractionEnabled = editing
        (canvas as? ReaderInkCanvas)?.passThroughFingers = !controls.allowFinger
        canvas.drawingPolicy = controls.allowFinger ? .anyInput : .pencilOnly
        canvas.drawingGestureRecognizer.isEnabled = editing
        if #available(iOS 18.0, *) { canvas.isDrawingEnabled = editing }
        if editing, canvas.window != nil, !canvas.isFirstResponder { canvas.becomeFirstResponder() }
        #if DEBUG
        canvas.accessibilityValue = "\(canvas.drawing.strokes.count) 笔|editing=\(editing);finger=\(controls.allowFinger);gesture=\(canvas.drawingGestureRecognizer.isEnabled);window=\(canvas.window != nil);first=\(canvas.isFirstResponder)"
        #endif
    }
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        var parent: PencilSurface
        var loaded = Data()
        var isDrawing = false
        init(_ parent: PencilSurface) { self.parent = parent }
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            guard !isDrawing else { return }
            let data = canvasView.drawing.dataRepresentation(); guard data != loaded else { return }; loaded = data
            parent.onChange(canvasView.drawing, parent.pageID, parent.bookID); parent.controls.refresh()
        }
        func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
            isDrawing = true
            parent.controls.isDrawing = true
            parent.controls.drawingChanged?(true)
            parent.controls.canvas = canvasView
            parent.onActivate()
            parent.controls.refresh()
        }
        func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
            isDrawing = false
            parent.controls.isDrawing = false
            parent.controls.drawingChanged?(false)
            canvasViewDrawingDidChange(canvasView)
            parent.controls.refresh()
        }
    }
}
