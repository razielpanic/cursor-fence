import CoreGraphics

/// How far the cursor *image* can reach from its hotspot, in points.
///
/// macOS draws the cursor across a display seam: with the hotspot 3pt onto one
/// display, the arrow's body still paints on its neighbour (measured on the dev Mac,
/// 2026-11-01). So the wall has to hold the hotspot far enough back that no
/// part of the image touches the fenced display, not merely the hotspot.
public struct CursorExtent: Sendable, Equatable {
    public var left: CGFloat
    public var up: CGFloat
    public var right: CGFloat
    public var down: CGFloat

    public init(left: CGFloat, up: CGFloat, right: CGFloat, down: CGFloat) {
        self.left = left
        self.up = up
        self.right = right
        self.down = down
    }

    /// Conservative bounds for the system cursors (arrow, I-beam, resize,
    /// drag-copy, context menu) at a given accessibility cursor size.
    /// Hotspots sit at the top-left (arrow) or centre (resize, crosshair),
    /// so images reach further right/down than left/up.
    public static func standard(cursorScale: CGFloat) -> CursorExtent {
        // Whole points: the cursor sits on whole-point positions (a warp
        // floors), so whole-point zone faces can't be crossed by rounding.
        let s = max(1, cursorScale)
        return CursorExtent(left: (20 * s).rounded(.up), up: (20 * s).rounded(.up),
                            right: (40 * s).rounded(.up), down: (40 * s).rounded(.up))
    }

    public static let zero = CursorExtent(left: 0, up: 0, right: 0, down: 0)
}

/// Which face of the forbidden zone the pointer ran into.
public enum Face: Sendable, Equatable {
    case left, right, top, bottom
}

/// A rebound: where the pointer met the wall.
public struct Contact: Sendable, Equatable {
    /// The face of the forbidden zone that was hit.
    public var face: Face
    /// The point on the fenced display's own edge opposite the contact,
    /// in global CG coordinates. The glow is centred here and clipped to
    /// the work screen, so only its work-side half is ever drawn.
    public var seamPoint: CGPoint
    /// Unit vector pointing away from the fenced display.
    public var normal: CGVector
}

public struct Step: Sendable, Equatable {
    public var point: CGPoint
    public var contact: Contact?
}

/// The fenced display and its neighbours, in global CG coordinates
/// (origin at the top-left of the main display, y grows downward).
public struct FenceGeometry: Sendable, Equatable {
    public var fenced: CGRect
    /// Bounds of every other active display. The pointer may go anywhere in these.
    public var others: [CGRect]
    public var extent: CursorExtent
    /// Backing scale (pixels per point) of each display in `others`.
    /// Disassociated, the mouse reports its motion in pixels of the display
    /// under the cursor, not in points: on a 2x Retina panel, driving the
    /// cursor by the raw deltas doubled every move (RP, the dev Mac, 2026-11-01).
    public var otherScales: [CGFloat]

    public init(fenced: CGRect, others: [CGRect], extent: CursorExtent, otherScales: [CGFloat]? = nil) {
        self.fenced = fenced
        self.others = others
        self.extent = extent
        self.otherScales = otherScales ?? others.map { _ in 1 }
    }

    /// Pixels per point of the display containing `p`; 1 if none does.
    public func scale(at p: CGPoint) -> CGFloat {
        guard let i = others.firstIndex(where: { p.x >= $0.minX && p.x < $0.maxX && p.y >= $0.minY && p.y < $0.maxY }),
              i < otherScales.count, otherScales[i] > 0 else { return 1 }
        return otherScales[i]
    }

    /// Hotspot positions at which the cursor image would overlap the fenced
    /// display. Open rectangle: a hotspot exactly on its boundary is allowed.
    public var zone: CGRect {
        CGRect(x: fenced.minX - extent.right,
               y: fenced.minY - extent.down,
               width: fenced.width + extent.left + extent.right,
               height: fenced.height + extent.up + extent.down)
    }

    public func isInFenced(_ p: CGPoint) -> Bool {
        p.x >= fenced.minX && p.x < fenced.maxX && p.y >= fenced.minY && p.y < fenced.maxY
    }

    public func isInZone(_ p: CGPoint) -> Bool {
        let z = zone
        return p.x > z.minX && p.x < z.maxX && p.y > z.minY && p.y < z.maxY
    }

    /// Euclidean distance from `p` to the zone; 0 inside or on it.
    public func distanceToZone(_ p: CGPoint) -> CGFloat {
        let z = zone
        let dx = max(z.minX - p.x, 0, p.x - z.maxX)
        let dy = max(z.minY - p.y, 0, p.y - z.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    /// How far inside the zone `p` is (distance to its nearest face); 0 outside.
    public func depthInZone(_ p: CGPoint) -> CGFloat {
        guard isInZone(p) else { return 0 }
        let z = zone
        return min(p.x - z.minX, z.maxX - p.x, p.y - z.minY, z.maxY - p.y)
    }

    public func display(containing p: CGPoint) -> CGRect? {
        others.first { p.x >= $0.minX && p.x < $0.maxX && p.y >= $0.minY && p.y < $0.maxY }
    }

    /// Moves the pointer from `p` toward `target` without letting the cursor
    /// image enter the fenced display. Motion into the wall stops at the wall
    /// and the remainder slides along it. The caller handles pointers that are
    /// already inside the fenced display (leaving is free).
    public func step(from p: CGPoint, to target: CGPoint) -> Step {
        if !isInZone(target) {
            let q = clampToDisplays(from: p, to: target)
            return Step(point: isInZone(q) ? p : q, contact: nil)
        }
        if isInZone(p) {
            return Step(point: stepInsideZone(from: p, to: target), contact: nil)
        }

        // Slab entry: the face crossed last among the axes where p is outside.
        let z = zone
        let dx = target.x - p.x
        let dy = target.y - p.y
        var entry: (t: CGFloat, face: Face)? = nil
        func consider(_ t: CGFloat, _ face: Face) {
            if entry == nil || t > entry!.t { entry = (t, face) }
        }
        if p.x <= z.minX, dx > 0 { consider((z.minX - p.x) / dx, .left) }
        if p.x >= z.maxX, dx < 0 { consider((z.maxX - p.x) / dx, .right) }
        if p.y <= z.minY, dy > 0 { consider((z.minY - p.y) / dy, .top) }
        if p.y >= z.maxY, dy < 0 { consider((z.maxY - p.y) / dy, .bottom) }
        guard let hit = entry else { return Step(point: p, contact: nil) }

        // Hold the hit axis exactly on the face; keep the other axis's full motion.
        var slid = target
        var stopped = CGPoint(x: p.x + dx * hit.t, y: p.y + dy * hit.t)
        switch hit.face {
        case .left: slid.x = z.minX; stopped.x = z.minX
        case .right: slid.x = z.maxX; stopped.x = z.maxX
        case .top: slid.y = z.minY; stopped.y = z.minY
        case .bottom: slid.y = z.maxY; stopped.y = z.maxY
        }

        var result = p
        for candidate in [slid, stopped] {
            let q = clampToDisplays(from: p, to: candidate)
            if !isInZone(q) { result = q; break }
        }
        return Step(point: result, contact: contact(at: result, face: hit.face))
    }

    /// The pointer starts inside the clearance strip (it just left the fenced
    /// display, or a release key was let go near it). Allow any motion that
    /// does not take it deeper; block the axis that would.
    private func stepInsideZone(from p: CGPoint, to target: CGPoint) -> CGPoint {
        let depth = depthInZone(p)
        let candidates = [target, CGPoint(x: target.x, y: p.y), CGPoint(x: p.x, y: target.y)]
        for c in candidates {
            let q = clampToDisplays(from: p, to: c)
            if depthInZone(q) <= depth, !isInFenced(q) { return q }
        }
        return p
    }

    /// Keeps the pointer on a non-fenced display, as the OS does when the
    /// mouse is associated. Disassociated, that clamping is ours to do.
    func clampToDisplays(from p: CGPoint, to target: CGPoint) -> CGPoint {
        if display(containing: target) != nil { return target }
        guard let d = display(containing: p) else { return target }
        return CGPoint(x: min(max(target.x, d.minX), d.maxX - 1),
                       y: min(max(target.y, d.minY), d.maxY - 1))
    }

    private func contact(at q: CGPoint, face: Face) -> Contact {
        let f = fenced
        let y = min(max(q.y, f.minY), f.maxY)
        let x = min(max(q.x, f.minX), f.maxX)
        switch face {
        case .left: return Contact(face: face, seamPoint: CGPoint(x: f.minX, y: y), normal: CGVector(dx: -1, dy: 0))
        case .right: return Contact(face: face, seamPoint: CGPoint(x: f.maxX, y: y), normal: CGVector(dx: 1, dy: 0))
        case .top: return Contact(face: face, seamPoint: CGPoint(x: x, y: f.minY), normal: CGVector(dx: 0, dy: -1))
        case .bottom: return Contact(face: face, seamPoint: CGPoint(x: x, y: f.maxY), normal: CGVector(dx: 0, dy: 1))
        }
    }
}

/// Area of the overlap of two rectangles; 0 when they only touch.
public func overlapArea(_ a: CGRect, _ b: CGRect) -> CGFloat {
    let w = min(a.maxX, b.maxX) - max(a.minX, b.minX)
    let h = min(a.maxY, b.maxY) - max(a.minY, b.minY)
    return w > 0 && h > 0 ? w * h : 0
}
