import SwiftUI
import UIKit
import PencilKit

@MainActor
final class NotebookControls: ObservableObject {
    @Published var tool = "pen"
    @Published var color = UserDefaults.standard.string(forKey: "notebook-ink-color") ?? "#202124" {
        didSet { UserDefaults.standard.set(color, forKey: "notebook-ink-color") }
    }
    @Published var width: Double = UserDefaults.standard.object(forKey: "notebook-ink-width") as? Double ?? 3 {
        didSet { UserDefaults.standard.set(width, forKey: "notebook-ink-width") }
    }
    @Published var drawingEnabled = true
    @Published var allowFinger = false
    @Published var canUndo = false; @Published var canRedo = false
    @Published var selection: String?
    @Published var zoom: Double = 1
    @Published var loading = false
    var fit: (() -> Void)?
    weak var canvas: PKCanvasView?
    var pencilTool: PKTool {
        if tool == "eraser" { return PKEraserTool(.vector) }
        if tool == "select" { return PKLassoTool() }
        return PKInkingTool(tool == "marker" ? .marker : tool == "pencil" ? .pencil : .pen,
                            color: UIColor(notebookHex: color), width: tool == "marker" ? min(128, width * 4) : width)
    }
    func undo() { canvas?.undoManager?.undo(); refresh() }
    func redo() { canvas?.undoManager?.redo(); refresh() }
    func refresh() {
        let undo = canvas?.undoManager?.canUndo ?? false, redo = canvas?.undoManager?.canRedo ?? false
        if canUndo != undo { canUndo = undo }; if canRedo != redo { canRedo = redo }
    }
}

struct NotebookSurface: UIViewRepresentable {
    var page: NotebookPage
    @ObservedObject var controls: NotebookControls
    var onDrawing: (PKDrawing, Data, String) -> Void
    var onExtent: (String, CGSize) -> Void
    var onElement: (NotebookElement, String) -> Void
    var onEdit: (String) -> Void
    var onCloseSidebar: (() -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.backgroundColor = .white; scroll.contentInsetAdjustmentBehavior = .never
        scroll.minimumZoomScale = 0.2; scroll.maximumZoomScale = 3
        scroll.delegate = context.coordinator; scroll.bounces = false
        scroll.delaysContentTouches = false; scroll.canCancelContentTouches = true
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        scroll.accessibilityIdentifier = "notebook-viewport"
        scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scroll.pinchGestureRecognizer?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        let content = UIView(frame: CGRect(origin: .zero, size: page.size))
        let paper = NotebookPaperView(frame: content.bounds)
        let canvas = ReaderInkCanvas(frame: content.bounds)
        canvas.backgroundColor = .clear; canvas.isOpaque = false; canvas.isScrollEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.minimumZoomScale = 1; canvas.maximumZoomScale = 1; canvas.zoomScale = 1
        canvas.contentSize = page.size; canvas.delegate = context.coordinator
        canvas.accessibilityIdentifier = "notebook-ink-canvas"; canvas.accessibilityLabel = "笔记本压感画布"; canvas.isAccessibilityElement = true
        content.addSubview(paper); content.addSubview(canvas); scroll.addSubview(content)
        context.coordinator.scroll = scroll; context.coordinator.content = content
        context.coordinator.paper = paper; context.coordinator.canvas = canvas
        controls.canvas = canvas
        controls.fit = { [weak scroll] in if let scroll { scroll.setZoomScale(max(0.2, min(1, scroll.bounds.width / 1100)), animated: true) } }
        let dismissPan = context.coordinator.dismissPan
        scroll.addGestureRecognizer(dismissPan); scroll.panGestureRecognizer.require(toFail: dismissPan)
        return scroll
    }
    func updateUIView(_ scroll: UIScrollView, context: Context) { context.coordinator.update(self) }
    static func dismantleUIView(_ scroll: UIScrollView, coordinator: Coordinator) { coordinator.close() }
    final class Coordinator: NSObject, PKCanvasViewDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
        var parent: NotebookSurface
        weak var scroll: UIScrollView?; weak var canvas: PKCanvasView?
        var content: UIView?; var paper: NotebookPaperView?
        var elements: [String: NotebookElementView] = [:]
        var loadedID = ""; var loadedData: Data?; var loadedStrokes: [NotebookStroke] = []
        var isDrawing = false; var isLoading = false; var extending = false
        var appliedTool = ""; var appliedFinger: Bool?
        private var cachedCanvases: [String: ReaderInkCanvas] = [:]
        private var cachedData: [String: Data] = [:]
        private var pageViews: [String: (CGFloat, CGPoint)] = [:]
        private var recent: [String] = []
        private var loadTask: Task<Void, Never>?
        private var loadRevision = UUID()
        private var drawingReady = true
        lazy var dismissPan: UIPanGestureRecognizer = {
            let pan = UIPanGestureRecognizer(target: self, action: #selector(closeSidebar(_:)))
            pan.delegate = self; pan.maximumNumberOfTouches = 1
            pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            return pan
        }()
        init(_ parent: NotebookSurface) { self.parent = parent }
        func update(_ value: NotebookSurface) {
            parent = value
            guard !isDrawing, var canvas = canvas, let scroll, let content else { return }
            let changedPage = loadedID != value.page.id
            isLoading = true
            dismissPan.isEnabled = value.onCloseSidebar != nil && !value.controls.allowFinger
            if changedPage {
                loadTask?.cancel(); loadRevision = UUID()
                if !loadedID.isEmpty, let current = canvas as? ReaderInkCanvas {
                    if drawingReady {
                        cachedCanvases[loadedID] = current
                        if let loadedData { cachedData[loadedID] = loadedData }
                    } else { cachedCanvases.removeValue(forKey: loadedID); cachedData.removeValue(forKey: loadedID) }
                    pageViews[loadedID] = (scroll.zoomScale, scroll.contentOffset)
                    current.delegate = nil; current.resignFirstResponder(); current.removeFromSuperview()
                }
                scroll.setZoomScale(1, animated: false)
                if let cached = cachedCanvases[value.page.id] {
                    canvas = cached
                } else if !loadedID.isEmpty {
                    let next = ReaderInkCanvas(frame: CGRect(origin: .zero, size: value.page.size))
                    next.backgroundColor = .clear; next.isOpaque = false; next.isScrollEnabled = false
                    next.pinchGestureRecognizer?.isEnabled = false
                    next.minimumZoomScale = 1; next.maximumZoomScale = 1; next.zoomScale = 1
                    next.accessibilityIdentifier = "notebook-ink-canvas"
                    next.accessibilityLabel = "笔记本压感画布"; next.isAccessibilityElement = true
                    canvas = next
                }
                canvas.frame = CGRect(origin: .zero, size: value.page.size); canvas.contentSize = value.page.size
                canvas.delegate = self; content.addSubview(canvas); self.canvas = canvas; value.controls.canvas = canvas
                scroll.panGestureRecognizer.isEnabled = true; scroll.pinchGestureRecognizer?.isEnabled = true
                appliedTool = ""; appliedFinger = nil
                drawingReady = true
                DispatchQueue.main.async { value.controls.loading = false }
                recent.removeAll { $0 == value.page.id }; recent.append(value.page.id)
                while recent.count > 3 {
                    let old = recent.removeFirst(); cachedCanvases.removeValue(forKey: old)?.delegate = nil; cachedData.removeValue(forKey: old)
                }
            }
            if changedPage || value.page.inkData != loadedData || (value.page.inkData == nil && value.page.strokes != loadedStrokes) {
                loadedID = value.page.id; loadedData = value.page.inkData; loadedStrokes = value.page.strokes
                if !changedPage || cachedCanvases[value.page.id] == nil || cachedData[value.page.id] != value.page.inkData {
                    loadTask?.cancel(); loadRevision = UUID()
                    if (value.page.inkData?.count ?? 0) > 32_768 || value.page.strokes.count > 100 {
                        let page = value.page, token = loadRevision
                        drawingReady = false
                        canvas.drawing = PKDrawing()
                        DispatchQueue.main.async { value.controls.loading = true }
                        loadTask = Task { @MainActor [weak self, weak canvas] in
                            let drawing = await Task.detached(priority: .userInitiated) { page.drawing }.value
                            guard !Task.isCancelled, let self, let canvas, self.loadRevision == token, self.loadedID == page.id else { return }
                            self.isLoading = true; canvas.drawing = drawing; canvas.undoManager?.removeAllActions(); self.drawingReady = true; self.isLoading = false
                            canvas.accessibilityValue = "\(drawing.strokes.count) 笔"
                            value.controls.loading = false; value.controls.refresh()
                        }
                    } else { canvas.drawing = value.page.drawing; canvas.undoManager?.removeAllActions(); DispatchQueue.main.async { value.controls.loading = false } }
                }
            }
            if paper?.page.title != value.page.title || paper?.page.paper != value.page.paper || paper?.page.pattern != value.page.pattern || paper?.page.created != value.page.created {
                var metadata = value.page; metadata.inkData = nil; metadata.strokes = []; metadata.elements = []
                paper?.page = metadata; paper?.setNeedsDisplay()
            }
            if content.bounds.size != value.page.size { extent(value.page.size) }
            let toolKey = "\(value.controls.tool):\(value.controls.color):\(value.controls.width)"
            if appliedTool != toolKey { canvas.tool = value.controls.pencilTool; appliedTool = toolKey }
            if appliedFinger != value.controls.allowFinger {
                canvas.drawingPolicy = value.controls.allowFinger ? .anyInput : .pencilOnly
                appliedFinger = value.controls.allowFinger
            }
            canvas.drawingGestureRecognizer.isEnabled = value.controls.drawingEnabled && drawingReady
            if #available(iOS 18.0, *) { canvas.isDrawingEnabled = value.controls.drawingEnabled && drawingReady }
            scroll.panGestureRecognizer.minimumNumberOfTouches = value.controls.allowFinger && value.controls.drawingEnabled ? 2 : 1
            for id in elements.keys where !value.page.elements.contains(where: { $0.id == id }) { elements.removeValue(forKey: id)?.removeFromSuperview() }
            for element in value.page.elements {
                let view = elements[element.id] ?? NotebookElementView()
                if elements[element.id] == nil {
                    elements[element.id] = view; content.addSubview(view)
                    // Moving a selected object must win over one-finger page panning.
                    scroll.panGestureRecognizer.require(toFail: view.moveGesture)
                }
                let selected = value.controls.selection == element.id, editing = value.controls.tool == "select"
                if view.element != element || view.isSelected != selected || view.isUserInteractionEnabled != editing {
                    view.configure(element, selected: selected, editing: editing)
                }
                let pageID = value.page.id
                view.onSelect = { [weak self] in self?.parent.controls.selection = element.id }
                view.onChange = { [weak self] e in self?.parent.onElement(e, pageID) }
                view.onEdit = { [weak self] in self?.parent.onEdit(element.id) }
                if value.controls.tool == "select" { content.bringSubviewToFront(view) }
            }
            if value.controls.tool != "select" { content.bringSubviewToFront(canvas) }
            if changedPage, canvas.window != nil, !canvas.isFirstResponder { canvas.becomeFirstResponder() }
            canvas.accessibilityValue = "\(canvas.drawing.strokes.count) 笔"
            if changedPage {
                let saved = pageViews[value.page.id] ?? (1, .zero)
                scroll.setZoomScale(saved.0, animated: false)
                scroll.setContentOffset(saved.1, animated: false)
                DispatchQueue.main.async { [weak self] in self?.parent.controls.refresh() }
            }
            scroll.accessibilityValue = "\(Int((scroll.zoomScale * 100).rounded()))%"
            isLoading = false
        }
        func extent(_ size: CGSize) {
            guard let scroll, let content else { return }
            let scale = scroll.zoomScale, offset = scroll.contentOffset
            // UIScrollView owns the zoom transform. Assigning a transformed
            // view's frame can change its bounds/scale and make the paper jump.
            UIView.performWithoutAnimation {
                content.bounds.size = size
                content.center = CGPoint(x: size.width * scale / 2, y: size.height * scale / 2)
                paper?.frame = CGRect(origin: .zero, size: size)
                canvas?.frame = CGRect(origin: .zero, size: size); canvas?.contentSize = size
                scroll.contentSize = CGSize(width: size.width * scale, height: size.height * scale)
                scroll.setContentOffset(offset, animated: false)
            }
        }
        func grow(x: CGFloat, y: CGFloat, notify: Bool) {
            guard !extending, let content else { return }
            var size = content.bounds.size
            if x > size.width - 180 { size.width = min(10_000_000, ceil((x + 700) / 1024) * 1024) }
            if y > size.height - 180 { size.height = min(10_000_000, ceil((y + 700) / 1024) * 1024) }
            guard size != content.bounds.size else { return }
            extending = true; extent(size); extending = false
            if notify { parent.onExtent(loadedID, size) }
        }
        func canvasViewDidBeginUsingTool(_ canvas: PKCanvasView) {
            guard canvas === self.canvas else { return }
            isDrawing = true; parent.controls.canvas = canvas
            // Palm contact while the tip is down must never pinch the outer page.
            scroll?.pinchGestureRecognizer?.isEnabled = false
            scroll?.panGestureRecognizer.isEnabled = false
        }
        func canvasViewDrawingDidChange(_ canvas: PKCanvasView) {
            guard !isLoading, drawingReady, canvas === self.canvas, !loadedID.isEmpty else { return }
            guard !isDrawing else { return }
            if !canvas.drawing.bounds.isEmpty { grow(x: canvas.drawing.bounds.maxX, y: canvas.drawing.bounds.maxY, notify: false) }
            let data = canvas.drawing.dataRepresentation()
            loadedData = data
            cachedData[loadedID] = data
            loadedStrokes = []
            parent.onDrawing(canvas.drawing, data, loadedID)
            if let size = content?.bounds.size { parent.onExtent(loadedID, size) }
            canvas.accessibilityValue = "\(canvas.drawing.strokes.count) 笔"; parent.controls.refresh()
        }
        func canvasViewDidEndUsingTool(_ canvas: PKCanvasView) {
            guard canvas === self.canvas else { return }
            isDrawing = false; canvasViewDrawingDidChange(canvas)
            scroll?.pinchGestureRecognizer?.isEnabled = true
            scroll?.panGestureRecognizer.isEnabled = true
        }
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            let velocity = dismissPan.velocity(in: scroll)
            return !isDrawing && parent.onCloseSidebar != nil && velocity.x < 0 && abs(velocity.x) > abs(velocity.y) * 1.2
        }
        @objc private func closeSidebar(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .ended else { return }
            if -pan.translation(in: scroll).x > 30 || -pan.velocity(in: scroll).x > 550 { parent.onCloseSidebar?() }
        }
        func close() {
            loadTask?.cancel(); loadRevision = UUID()
            // Never publish a store mutation inside SwiftUI's dismantle pass.
            if isDrawing, let canvas, !loadedID.isEmpty {
                let drawing = canvas.drawing, data = drawing.dataRepresentation(), id = loadedID, capture = parent.onDrawing
                DispatchQueue.main.async { capture(drawing, data, id) }
            }
            isDrawing = false; isLoading = true
            canvas?.delegate = nil; canvas?.resignFirstResponder(); scroll?.delegate = nil
            for value in cachedCanvases.values { value.delegate = nil }
            cachedCanvases.removeAll(); cachedData.removeAll(); pageViews.removeAll(); elements.removeAll()
            scroll?.removeGestureRecognizer(dismissPan)
            parent.controls.canvas = nil; parent.controls.fit = nil
        }
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            guard !isLoading, !isDrawing, loadedID != "", scrollView.isDragging || scrollView.isDecelerating else { return }
            grow(x: (scrollView.contentOffset.x + scrollView.bounds.width) / scrollView.zoomScale,
                 y: (scrollView.contentOffset.y + scrollView.bounds.height) / scrollView.zoomScale, notify: true)
        }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            scrollView.accessibilityValue = "\(Int((scrollView.zoomScale * 100).rounded()))%"
        }
        func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { parent.controls.zoom = Double(scale) }
    }
}

final class NotebookPaperView: UIView {
    var page = NotebookPage()
    override class var layerClass: AnyClass { CATiledLayer.self }
    override init(frame: CGRect) {
        super.init(frame: frame); isUserInteractionEnabled = false; isOpaque = true
        let tiled = layer as! CATiledLayer; tiled.tileSize = CGSize(width: 512, height: 512); tiled.levelsOfDetail = 4; tiled.levelsOfDetailBias = 3
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ rect: CGRect) {
        guard let c = UIGraphicsGetCurrentContext() else { return }
        let page = self.page
        let background: UIColor = page.paper == "dark" ? UIColor(notebookHex: "#202124") : page.paper == "cream" ? UIColor(notebookHex: "#F8F1DF") : .white
        background.setFill(); c.fill(rect)
        if page.pattern != "blank" {
            c.setStrokeColor(UIColor.gray.withAlphaComponent(0.16).cgColor); c.setLineWidth(0.6)
            for y in stride(from: floor(rect.minY / 32) * 32, through: rect.maxY, by: 32) { c.move(to: CGPoint(x: rect.minX, y: y)); c.addLine(to: CGPoint(x: rect.maxX, y: y)) }
            if page.pattern == "grid" { for x in stride(from: floor(rect.minX / 32) * 32, through: rect.maxX, by: 32) { c.move(to: CGPoint(x: x, y: rect.minY)); c.addLine(to: CGPoint(x: x, y: rect.maxY)) } }
            c.strokePath()
        }
        let ink: UIColor = page.paper == "dark" ? .white : UIColor(notebookHex: "#202124")
        (page.title as NSString).draw(in: CGRect(x: 64, y: 48, width: 1100, height: 68), withAttributes: [.font: UIFont.systemFont(ofSize: 48), .foregroundColor: ink])
        c.setStrokeColor(UIColor.lightGray.cgColor); c.setLineWidth(1); c.move(to: CGPoint(x: 64, y: 128)); c.addLine(to: CGPoint(x: 1100, y: 128)); c.strokePath()
        (String(page.created.prefix(10)) as NSString).draw(at: CGPoint(x: 64, y: 143), withAttributes: [.font: UIFont.systemFont(ofSize: 18), .foregroundColor: UIColor.gray])
    }
}

final class NotebookElementView: UIView {
    var isSelected = false
    var element = NotebookElement()
    let label = UILabel(); let imageView = UIImageView(); let handle = UIView()
    var onSelect: (() -> Void)?; var onChange: ((NotebookElement) -> Void)?; var onEdit: (() -> Void)?
    private var starting = NotebookElement(); private var resizing = false
    lazy var moveGesture = UIPanGestureRecognizer(target: self, action: #selector(moveElement(_:)))
    override init(frame: CGRect) {
        super.init(frame: frame); label.numberOfLines = 0; imageView.contentMode = .scaleAspectFit
        addSubview(label); addSubview(imageView); handle.backgroundColor = UIColor(notebookHex: "#8030A7"); addSubview(handle)
        addGestureRecognizer(moveGesture)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(selectElement)))
        let double = UITapGestureRecognizer(target: self, action: #selector(editElement)); double.numberOfTapsRequired = 2; addGestureRecognizer(double)
    }
    required init?(coder: NSCoder) { fatalError() }
    func configure(_ value: NotebookElement, selected: Bool, editing: Bool) {
        isSelected = selected
        element = value; frame = CGRect(x: value.x, y: value.y, width: value.width, height: value.height)
        label.frame = bounds; imageView.frame = bounds; handle.frame = CGRect(x: bounds.width - 18, y: bounds.height - 18, width: 18, height: 18)
        label.isHidden = value.kind != "text"; imageView.isHidden = value.kind != "image"
        label.text = value.text; label.font = .systemFont(ofSize: value.fontSize, weight: value.bold ? .bold : .regular); label.textColor = UIColor(notebookHex: value.color)
        if let data = NotebookCodec.imageData(value.dataURI), imageView.image == nil { imageView.image = UIImage(data: data) }
        isUserInteractionEnabled = editing; handle.isHidden = !selected
        isAccessibilityElement = true; accessibilityIdentifier = "notebook-object-\(value.id)"
        accessibilityLabel = value.kind == "image" ? "笔记图片" : value.text
        layer.borderWidth = selected ? 1.5 : 0; layer.borderColor = UIColor(notebookHex: "#8030A7").cgColor
    }
    @objc func selectElement() { onSelect?() }
    @objc func editElement() { onSelect?(); if element.kind == "text" { onEdit?() } }
    @objc func moveElement(_ gesture: UIPanGestureRecognizer) {
        if gesture.state == .began { starting = element; let point = gesture.location(in: self); resizing = point.x > bounds.width - 36 && point.y > bounds.height - 36; onSelect?() }
        let delta = gesture.translation(in: superview)
        if resizing { element.width = max(60, starting.width + delta.x); element.height = max(40, starting.height + delta.y) }
        else { element.x = max(0, starting.x + delta.x); element.y = max(0, starting.y + delta.y) }
        frame = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
        label.frame = bounds; imageView.frame = bounds; handle.frame = CGRect(x: bounds.width - 18, y: bounds.height - 18, width: 18, height: 18)
        if gesture.state == .ended { onChange?(element) }
        if gesture.state == .cancelled { element = starting; onChange?(starting) }
    }
}
