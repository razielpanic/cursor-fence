import CoreGraphics

/// Geometry for the rebound feedback. Nothing here may ever place a pixel on
/// the fenced display; `glowFrame` refuses rather than spill.
public enum Feedback {
    /// The glow's window frame in global CG coordinates: a square centred on
    /// the seam point, cut down to the work display. Returns nil when the cut
    /// leaves nothing to draw, or (defensively) when the result would overlap
    /// the fenced display at all.
    public static func glowFrame(seamPoint: CGPoint, radius: CGFloat,
                                 workDisplay: CGRect, fenced: CGRect) -> CGRect? {
        let square = CGRect(x: seamPoint.x - radius, y: seamPoint.y - radius,
                            width: radius * 2, height: radius * 2)
        let frame = square.intersection(workDisplay)
        guard !frame.isNull, frame.width >= 1, frame.height >= 1 else { return nil }
        guard overlapArea(frame, fenced) == 0 else { return nil }
        return frame
    }

    /// Converts a global CG rect (top-left origin, y down) to AppKit screen
    /// coordinates (bottom-left origin of the main display, y up).
    public static func appKitRect(fromCG r: CGRect, mainDisplayHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    public static func cgRect(fromAppKit r: CGRect, mainDisplayHeight h: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
    }

    /// Ease-out cubic: fast away from the wall, settling gently.
    public static func easeOut(_ t: Double) -> Double {
        let c = min(max(t, 0), 1)
        let u = 1 - c
        return 1 - u * u * u
    }

    /// Recoil offset (distance from the wall) at a given time into the animation.
    public static func recoilDistance(elapsed: Double, duration: Double, distance: CGFloat) -> CGFloat {
        guard duration > 0 else { return distance }
        return distance * CGFloat(easeOut(elapsed / duration))
    }
}
