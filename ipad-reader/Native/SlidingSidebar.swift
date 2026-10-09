import SwiftUI
import UIKit

struct SlidingSidebar<Content: View>: UIViewControllerRepresentable {
    var leading: Bool
    var width: CGFloat
    var dimmed = true
    var dismiss: () -> Void
    @ViewBuilder var content: () -> Content
    func makeUIViewController(context: Context) -> SwipeSidebarController<Content> {
        SwipeSidebarController(content: content(), leading: leading, width: width, dimmed: dimmed, dismiss: dismiss)
    }
    func updateUIViewController(_ controller: SwipeSidebarController<Content>, context: Context) {
        controller.update(content: content(), width: width, dismiss: dismiss)
    }
}

/// No SwiftUI layout/animation is scheduled for individual drag frames.
final class SwipeSidebarController<Content: View>: UIViewController, UIGestureRecognizerDelegate {
    private let host: UIHostingController<Content>
    private let dimming = UIView()
    private let leading: Bool
    private let dimmed: Bool
    private var width: CGFloat
    private var onDismiss: () -> Void
    private var closing = false
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(drag(_:)))
    private var sign: CGFloat { leading ? -1 : 1 }
    init(content: Content, leading: Bool, width: CGFloat, dimmed: Bool, dismiss: @escaping () -> Void) {
        host = UIHostingController(rootView: content); self.leading = leading; self.width = width
        self.dimmed = dimmed; onDismiss = dismiss
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func loadView() { view = SidebarHitView() }
    override func viewDidLoad() {
        super.viewDidLoad()
        dimming.backgroundColor = UIColor.black.withAlphaComponent(0.2)
        dimming.isHidden = !dimmed
        dimming.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(close)))
        view.addSubview(dimming)
        host.safeAreaRegions = []
        addChild(host); view.addSubview(host.view); host.didMove(toParent: self)
        pan.delegate = self; pan.maximumNumberOfTouches = 1
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        host.view.addGestureRecognizer(pan)
    }
    func update(content: Content, width: CGFloat, dismiss: @escaping () -> Void) {
        host.rootView = content; self.width = width; onDismiss = dismiss
        view.setNeedsLayout()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        dimming.frame = view.bounds
        // Bounds/center are stable even while a drag translates the pane.
        host.view.bounds = CGRect(x: 0, y: 0, width: width, height: view.bounds.height)
        host.view.center = CGPoint(x: leading ? width / 2 : view.bounds.width - width / 2, y: view.bounds.midY)
    }
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard !closing else { return false }
        let velocity = pan.velocity(in: view)
        return velocity.x * sign > 0 && abs(velocity.x) > abs(velocity.y) * 1.1
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // Vertical list scrolling can coexist, but a horizontal dismissal
        // must cancel row taps instead of selecting the row under the finger.
        other is UIPanGestureRecognizer
    }
    @objc private func drag(_ gesture: UIPanGestureRecognizer) {
        let distance = min(width, max(0, gesture.translation(in: view).x * sign))
        if gesture.state == .began || gesture.state == .changed {
            host.view.transform = CGAffineTransform(translationX: sign * distance, y: 0)
            dimming.alpha = 1 - distance / max(1, width)
        } else if [.ended, .cancelled, .failed].contains(gesture.state) {
            let velocity = gesture.velocity(in: view).x * sign
            let commit = gesture.state == .ended && (distance > width * 0.28 || distance > 8 && velocity > 550)
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--uitesting-reset") {
                print("Sidebar release: distance=\(distance), width=\(width), velocity=\(velocity), commit=\(commit)")
            }
            #endif
            if commit { finish(distance: distance, velocity: velocity) }
            else {
                UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.22, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.host.view.transform = .identity; self.dimming.alpha = 1
                }
            }
        }
    }
    @objc private func close() { finish(distance: abs(host.view.transform.tx), velocity: 0) }
    private func finish(distance: CGFloat, velocity: CGFloat) {
        guard !closing else { return }; closing = true
        host.view.isUserInteractionEnabled = false
        let duration = UIAccessibility.isReduceMotionEnabled ? 0 : min(0.25, max(0.09, Double((width - distance) / max(1400, velocity))))
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.host.view.transform = CGAffineTransform(translationX: self.sign * self.width, y: 0)
            self.dimming.alpha = 0
        } completion: { _ in
            // It is already offscreen. Removing it must not animate a second time.
            var transaction = Transaction(); transaction.disablesAnimations = true
            withTransaction(transaction) { self.onDismiss() }
        }
    }
}

private final class SidebarHitView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}
