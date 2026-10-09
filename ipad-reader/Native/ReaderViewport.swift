import SwiftUI
import UIKit

@MainActor final class ReaderViewportControls: ObservableObject {
    @Published var zoom = 1.0
    var fit: (() -> Void)?
    var turn: ((Int) -> Void)?
}

/// Zoom transforms paper and ink together, without repagination.
struct ReaderViewport: UIViewControllerRepresentable {
    @EnvironmentObject private var store: ReaderStore
    @ObservedObject var ink: InkControls
    @ObservedObject var controls: ReaderViewportControls
    var start: Int
    var spread: Bool
    var onTap: () -> Void
    func makeUIViewController(context: Context) -> ReaderViewportController { ReaderViewportController(self, store: store) }
    func updateUIViewController(_ controller: ReaderViewportController, context: Context) { controller.update(self) }
}

/// Each cached leaf uses exactly the same hosting/scroll geometry. An incoming
/// leaf becomes the current view; it is never replaced by a differently scaled preview.
@MainActor private final class ReaderPaperSlot: UIViewController {
    let scroll = UIScrollView()
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    let previewInk = InkControls()
    var key = ""
    var index = -1
    var isPreview = true
    var logicalSize = CGSize.zero
    var fitScale: CGFloat = 1
    private var measuredBounds = CGSize.zero

    override func viewDidLoad() {
        super.viewDidLoad()
        view.clipsToBounds = true
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.showsHorizontalScrollIndicator = false; scroll.showsVerticalScrollIndicator = false
        scroll.bounces = false; scroll.bouncesZoom = true
        scroll.delaysContentTouches = false
        scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scroll.pinchGestureRecognizer?.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        host.safeAreaRegions = []
        addChild(host); scroll.addSubview(host.view); host.didMove(toParent: self)
        view.addSubview(scroll)
    }
    func load(_ value: ReaderViewport, store: ReaderStore, start: Int, preview: Bool) {
        loadViewIfNeeded()
        let size = CGSize(width: store.layout.width * (value.spread ? 2 : 1), height: store.layout.height)
        let next = "\(store.backup.currentBookID):\(start):\(value.spread):\(size)"
        let changed = next != key
        if changed || isPreview != preview {
            host.rootView = AnyView(BookSurface(controls: preview ? previewInk : value.ink, start: start, spread: value.spread, preview: preview).environmentObject(store))
        }
        key = next; index = start; isPreview = preview
        view.isUserInteractionEnabled = !preview
        view.accessibilityElementsHidden = preview
        scroll.accessibilityIdentifier = preview ? nil : "reader-viewport"
        let paper = ReaderPalette.paper(store.backup.theme)
        view.backgroundColor = paper; scroll.backgroundColor = paper; host.view.backgroundColor = paper
        scroll.panGestureRecognizer.minimumNumberOfTouches = value.ink.allowFinger && store.isAnnotating ? 2 : 1
        // A page turn does not reset the scroll transform through 1x.
        if logicalSize != size {
            scroll.minimumZoomScale = min(scroll.minimumZoomScale, 1)
            scroll.maximumZoomScale = max(scroll.maximumZoomScale, 1)
            scroll.setZoomScale(1, animated: false)
            logicalSize = size; measuredBounds = .zero
            host.view.bounds = CGRect(origin: .zero, size: size)
            host.view.center = CGPoint(x: size.width / 2, y: size.height / 2)
            scroll.contentSize = size
            view.setNeedsLayout()
        }
        view.layoutIfNeeded(); host.view.layoutIfNeeded()
        if changed { fit() }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scroll.frame = view.bounds
        guard view.bounds.width > 0, view.bounds.height > 0, logicalSize.width > 0, measuredBounds != view.bounds.size else { return }
        let relative = measuredBounds == .zero ? 1 : scroll.zoomScale / fitScale
        measuredBounds = view.bounds.size
        fitScale = min(view.bounds.width / logicalSize.width, view.bounds.height / logicalSize.height)
        scroll.minimumZoomScale = fitScale; scroll.maximumZoomScale = fitScale * 4
        scroll.setZoomScale(max(fitScale, min(fitScale * 4, fitScale * relative)), animated: false)
        centerPaper()
        if relative <= 1.02 { scroll.contentOffset = CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top) }
    }
    func centerPaper() {
        scroll.contentInset = UIEdgeInsets(top: max(0, (scroll.bounds.height - logicalSize.height * scroll.zoomScale) / 2), left: max(0, (scroll.bounds.width - logicalSize.width * scroll.zoomScale) / 2), bottom: 0, right: 0)
    }
    func fit(animated: Bool = false) {
        guard measuredBounds != .zero else { return }
        scroll.setZoomScale(fitScale, animated: animated)
        if !animated { centerPaper(); scroll.contentOffset = CGPoint(x: -scroll.contentInset.left, y: -scroll.contentInset.top) }
    }
}

@MainActor final class ReaderViewportController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private var configuration: ReaderViewport
    private let store: ReaderStore
    private let slots: [ReaderPaperSlot]
    private var active: ReaderPaperSlot
    private var incoming: ReaderPaperSlot?
    private var turning = false
    private var warming: DispatchWorkItem?
    private lazy var pagePan = UIPanGestureRecognizer(target: self, action: #selector(panPage(_:)))
    private lazy var pageTap = UITapGestureRecognizer(target: self, action: #selector(tapPage))

    init(_ configuration: ReaderViewport, store: ReaderStore) {
        self.configuration = configuration; self.store = store
        let slots = [ReaderPaperSlot(), ReaderPaperSlot(), ReaderPaperSlot()]
        self.slots = slots; active = slots[0]
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func viewDidLoad() {
        super.viewDidLoad(); view.clipsToBounds = true
        for slot in slots {
            addChild(slot); view.addSubview(slot.view); slot.didMove(toParent: self)
            slot.scroll.delegate = self
        }
        pagePan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pagePan.maximumNumberOfTouches = 1; pagePan.delegate = self
        pageTap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        pageTap.cancelsTouchesInView = false; pageTap.delegate = self
        view.addGestureRecognizer(pagePan); view.addGestureRecognizer(pageTap)
        for slot in slots {
            slot.scroll.panGestureRecognizer.require(toFail: pagePan)
            if let pinch = slot.scroll.pinchGestureRecognizer { pageTap.require(toFail: pinch) }
        }
        pageTap.require(toFail: pagePan)
        configuration.controls.fit = { [weak self] in self?.active.fit(animated: true) }
        configuration.controls.turn = { [weak self] index in self?.turn(to: index) }
        configuration.ink.drawingChanged = { [weak self] drawing in
            guard let self else { return }
            self.active.scroll.pinchGestureRecognizer?.isEnabled = !drawing
            self.active.scroll.panGestureRecognizer.isEnabled = !drawing
        }
        update(configuration)
    }
    func update(_ value: ReaderViewport) {
        let changed = value.start != configuration.start || value.spread != configuration.spread
        configuration = value
        guard isViewLoaded else { return }
        if changed && !turning { resetPositions() }
        active.load(value, store: store, start: value.start, preview: false)
        reportZoom(publish: true); warmNeighbors()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard !turning, pagePan.state != .began, pagePan.state != .changed else { return }
        for slot in slots {
            slot.view.bounds = view.bounds
            slot.view.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
            slot.view.setNeedsLayout(); slot.view.layoutIfNeeded()
        }
        resetPositions(); reportZoom(publish: true); warmNeighbors()
    }
    private func resetPositions() {
        for slot in slots { slot.view.transform = slot === active ? .identity : CGAffineTransform(translationX: view.bounds.width * 2, y: 0) }
        view.bringSubviewToFront(active.view)
    }
    private func warmNeighbors() {
        warming?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.turning, self.pagePan.state != .began, self.pagePan.state != .changed, !self.configuration.ink.isDrawing else { return }
            let step = self.configuration.spread ? 2 : 1
            let indices = [self.configuration.start - step, self.configuration.start + step].filter { self.store.pages.indices.contains($0) }
            for (slot, index) in zip(self.slots.filter { $0 !== self.active }, indices) {
                slot.load(self.configuration, store: self.store, start: index, preview: true)
            }
        }
        warming = work; DispatchQueue.main.async(execute: work)
    }
    private func prepare(_ index: Int, direction: CGFloat) {
        warming?.cancel()
        let others = slots.filter { $0 !== active }
        let slot = others.first(where: { $0.index == index }) ?? others[0]
        slot.load(configuration, store: store, start: index, preview: true)
        slot.view.transform = CGAffineTransform(translationX: direction * view.bounds.width, y: 0)
        view.bringSubviewToFront(slot.view); view.bringSubviewToFront(active.view)
        incoming = slot
    }
    private func settle(index: Int?, direction: CGFloat, distance: CGFloat, velocity: CGFloat) {
        turning = true
        let remaining = index == nil ? abs(distance) : max(0, view.bounds.width - abs(distance))
        let duration = UIAccessibility.isReduceMotionEnabled ? 0 : min(0.24, max(0.09, Double(remaining / max(1400, abs(velocity)))))
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            self.active.view.transform = CGAffineTransform(translationX: index == nil ? 0 : -direction * self.view.bounds.width, y: 0)
            self.incoming?.view.transform = CGAffineTransform(translationX: index == nil ? direction * self.view.bounds.width : 0, y: 0)
        } completion: { [weak self] _ in
            guard let self else { return }
            if let index, let slot = self.incoming {
                self.active.load(self.configuration, store: self.store, start: self.configuration.start, preview: true)
                self.active = slot; self.configuration.start = index
                // Promote the view already in its final position. Its PDF crop,
                // rotation, scroll scale and paper origin remain unchanged.
                self.active.load(self.configuration, store: self.store, start: index, preview: false)
                self.store.go(to: index)
            }
            self.incoming = nil; self.turning = false
            self.resetPositions(); self.reportZoom(publish: true); self.warmNeighbors()
        }
    }
    private func turn(to index: Int) {
        guard !turning, !configuration.ink.isDrawing, index != configuration.start, store.pages.indices.contains(index) else { return }
        active.fit()
        let direction: CGFloat = index > configuration.start ? 1 : -1
        prepare(index, direction: direction)
        settle(index: index, direction: direction, distance: 0, velocity: 0)
    }
    func viewForZooming(in scrollView: UIScrollView) -> UIView? { slots.first(where: { $0.scroll === scrollView })?.host.view }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        slots.first(where: { $0.scroll === scrollView })?.centerPaper()
        if scrollView === active.scroll { reportZoom() }
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) { if scrollView === active.scroll { reportZoom(publish: true) } }
    private func reportZoom(publish: Bool = false) {
        let relative = Double(active.scroll.zoomScale / max(0.001, active.fitScale))
        active.scroll.accessibilityValue = "\(Int((relative * 100).rounded()))% · 第 \(configuration.start + 1) 页"
        guard publish else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, abs(self.configuration.controls.zoom - relative) > 0.005 else { return }
            self.configuration.controls.zoom = relative
        }
    }
    @objc private func tapPage() { guard !turning, !configuration.ink.isDrawing else { return }; configuration.onTap() }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !turning, !configuration.ink.isDrawing else { return false }
        if configuration.ink.allowFinger && store.isAnnotating { return false }
        if gestureRecognizer === pagePan {
            if selections(in: active.host.view).contains(where: { $0.hasSelection }) { return false }
            let velocity = pagePan.velocity(in: view)
            return active.scroll.zoomScale <= active.fitScale * 1.02 && abs(velocity.x) > abs(velocity.y) * 1.1
        }
        return true
    }
    private func selections(in view: UIView) -> [ReaderSelectionView] {
        if let view = view as? ReaderSelectionView { return [view] }
        return view.subviews.flatMap { selections(in: $0) }
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === pageTap {
            if let selection = selections(in: active.host.view).first(where: { $0.bounds.contains(touch.location(in: $0)) }) {
                return !selection.hasSelection
            }
        }
        return true
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pageTap {
            if other is UILongPressGestureRecognizer || (other.view is ReaderSelectionView && other is UIPanGestureRecognizer) { return true }
            if other is UITapGestureRecognizer, let selection = other.view as? ReaderSelectionView { return selection.handlesTap(at: other.location(in: selection)) }
            return false
        }
        if gestureRecognizer === pagePan { return other.view is ReaderSelectionView && (other is UILongPressGestureRecognizer || other is UIPanGestureRecognizer) }
        return false
    }
    @objc private func panPage(_ gesture: UIPanGestureRecognizer) {
        let delta = gesture.translation(in: view).x
        let direction: CGFloat = delta < 0 ? 1 : -1
        let next = configuration.start + Int(direction) * (configuration.spread ? 2 : 1)
        let valid = store.pages.indices.contains(next)
        if gesture.state == .began || gesture.state == .changed {
            if valid && incoming?.index != next { prepare(next, direction: direction) }
            let distance = valid ? delta : delta * 0.18
            active.view.transform = CGAffineTransform(translationX: distance, y: 0)
            if valid { incoming?.view.transform = CGAffineTransform(translationX: direction * view.bounds.width + distance, y: 0) }
            else { incoming?.view.transform = CGAffineTransform(translationX: view.bounds.width * 2, y: 0); incoming = nil }
        } else if [.ended, .cancelled, .failed].contains(gesture.state) {
            let velocity = gesture.velocity(in: view).x
            let projected = delta + velocity * 0.16
            let commit = gesture.state == .ended && valid && abs(delta) > 8 && projected * delta > 0 && (abs(projected) > view.bounds.width * 0.22 || abs(velocity) > 550)
            settle(index: commit ? next : nil, direction: direction, distance: delta, velocity: velocity)
        }
    }
}
