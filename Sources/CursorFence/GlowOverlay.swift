import AppKit
import FenceCore
import QuartzCore

/// The rebound glow: a borderless, click-through, non-activating panel on the
/// work screen. Its frame is cut to the work display before it is shown, and
/// checked again after AppKit has placed it; a frame that would touch the
/// fenced display is never shown.
@MainActor
final class GlowOverlay {
    private let panel: NSPanel
    private let gradient = CAGradientLayer()
    private(set) var shown = 0
    private(set) var refused = 0
    private(set) var lastFrameCG: CGRect?

    static let radius: CGFloat = 90

    init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.title = "Cursor Fence Glow"

        let view = NSView()
        view.wantsLayer = true
        gradient.type = .radial
        gradient.colors = [NSColor(calibratedRed: 1, green: 0.55, blue: 0.1, alpha: 0.9).cgColor,
                           NSColor(calibratedRed: 1, green: 0.35, blue: 0.05, alpha: 0.35).cgColor,
                           NSColor(calibratedRed: 1, green: 0.3, blue: 0, alpha: 0).cgColor]
        gradient.locations = [0, 0.45, 1]
        view.layer?.addSublayer(gradient)
        panel.contentView = view
    }

    /// - Parameters are global CG coordinates.
    func show(seamPoint: CGPoint, pointer: CGPoint, geometry: FenceGeometry) {
        guard let work = geometry.display(containing: pointer),
              let frameCG = Feedback.glowFrame(seamPoint: seamPoint, radius: Self.radius,
                                               workDisplay: work, fenced: geometry.fenced) else {
            refused += 1
            return
        }
        let h = Displays.mainDisplayHeight
        panel.setFrame(Feedback.appKitRect(fromCG: frameCG, mainDisplayHeight: h), display: false)

        // Assert on what AppKit actually did, not on what was asked.
        let placed = Feedback.cgRect(fromAppKit: panel.frame, mainDisplayHeight: h)
        guard overlapArea(placed, geometry.fenced) == 0 else {
            panel.orderOut(nil)
            refused += 1
            log.fault("glow refused: placed frame \(String(describing: placed), privacy: .public) overlaps fenced display")
            assertionFailure("glow window would draw on the fenced display")
            return
        }
        lastFrameCG = placed

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradient.frame = CGRect(origin: .zero, size: frameCG.size)
        // Layer unit space is y-up; the seam point may sit on the frame edge.
        let cx = (seamPoint.x - frameCG.minX) / frameCG.width
        let cy = 1 - (seamPoint.y - frameCG.minY) / frameCG.height
        gradient.startPoint = CGPoint(x: cx, y: cy)
        gradient.endPoint = CGPoint(x: cx + Self.radius / frameCG.width, y: cy + Self.radius / frameCG.height)
        gradient.removeAllAnimations()
        gradient.opacity = 0
        CATransaction.commit()

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.5
        fade.timingFunction = CAMediaTimingFunction(name: .easeIn)
        gradient.add(fade, forKey: "fade")

        panel.orderFrontRegardless()
        shown += 1
        let token = shown
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self, self.shown == token else { return }
            self.panel.orderOut(nil)
        }
    }
}
