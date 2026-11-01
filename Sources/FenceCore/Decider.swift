import CoreGraphics

/// How the wall is enforced against hardware motion.
public enum Mechanism: String, Sendable, CaseIterable {
    /// Near the wall, disconnect the mouse from the cursor
    /// (`CGAssociateMouseAndMouseCursorPosition(false)`) and drive the cursor
    /// from event deltas, so hardware motion can never carry it across.
    case disassociate
    /// Stay associated; rewrite each event's location and warp the cursor
    /// back when it crosses. Kept as a test mode for measuring whether the
    /// tap's rewrite alone holds against hardware motion.
    case rewriteOnly
}

/// One pointer-motion event as the tap sees it.
public struct MotionInput: Sendable {
    public var location: CGPoint
    public var delta: CGVector
    /// Posted by a process (CGEventPost) rather than by HID hardware. Such
    /// events carry an absolute location that the window server applies after
    /// the tap chain, so rewriting the location alone holds them, associated
    /// or not.
    public var isSynthetic: Bool
    public var flags: UInt64
    /// Whether the mouse is currently disassociated from the cursor.
    public var disassociated: Bool

    public init(location: CGPoint, delta: CGVector, isSynthetic: Bool, flags: UInt64, disassociated: Bool) {
        self.location = location
        self.delta = delta
        self.isSynthetic = isSynthetic
        self.flags = flags
        self.disassociated = disassociated
    }
}

public struct MotionOutput: Sendable, Equatable {
    /// Where the cursor should end up.
    public var position: CGPoint
    /// Write `position` into the event before passing it on.
    public var rewrite: Bool
    /// Move the cursor to `position` (it will not get there on its own).
    public var warp: Bool
    /// Whether the mouse should be disassociated after this event.
    public var wantDisassociated: Bool
    public var contact: Contact?
    /// Hardware moved the cursor into the zone while associated: the cursor
    /// image may already have been drawn on the fenced display.
    public var breach: Bool
    public var released: Bool
}

/// The fence's per-event decision, kept free of side effects so it can be
/// tested exhaustively. The engine applies the output.
public struct Decider: Sendable {
    public var geometry: FenceGeometry?
    public var releaseKeys: ReleaseKeys
    public var mechanism: Mechanism
    /// Distance from the zone inside which the mouse is disassociated.
    public var band: CGFloat
    /// The band also widens to this many times the latest motion, so a fast
    /// pointer is caught earlier than a slow one.
    public var bandVelocityFactor: CGFloat = 6
    public private(set) var lastPosition: CGPoint?

    public init(geometry: FenceGeometry?, releaseKeys: ReleaseKeys, mechanism: Mechanism, band: CGFloat) {
        self.geometry = geometry
        self.releaseKeys = releaseKeys
        self.mechanism = mechanism
        self.band = band
    }

    public mutating func reset(at p: CGPoint?) { lastPosition = p }

    public mutating func handle(_ e: MotionInput) -> MotionOutput {
        let released = releaseKeys.isHeld(flags: e.flags)
        guard let g = geometry, !released else {
            lastPosition = e.location
            return MotionOutput(position: e.location, rewrite: false, warp: false,
                                wantDisassociated: false, contact: nil, breach: false, released: released)
        }

        // Disassociated hardware motion leaves the cursor where it was and
        // reports only deltas; everything else reports where the cursor went.
        let driven = e.disassociated && !e.isSynthetic
        let from = driven ? e.location : (lastPosition ?? e.location)
        let target = driven
            ? CGPoint(x: e.location.x + e.delta.dx, y: e.location.y + e.delta.dy)
            : e.location

        // Inside the fenced display (crossed with a release key, or it was
        // there when the fence came up): leaving is free.
        if g.isInFenced(from) {
            lastPosition = target
            return MotionOutput(position: target, rewrite: false, warp: driven,
                                wantDisassociated: false, contact: nil, breach: false, released: false)
        }

        let step = g.step(from: from, to: target)
        let pos = step.point
        let breach = !driven && !e.isSynthetic && g.isInZone(e.location) && !g.isInZone(from)
        // A rewritten synthetic event lands where it says; hardware motion has
        // already put the cursor at the event's location (or left it there).
        let cursorWithoutWarp = e.isSynthetic ? pos : e.location
        let speed = (e.delta.dx * e.delta.dx + e.delta.dy * e.delta.dy).squareRoot()
        let reach = max(band, speed * bandVelocityFactor)
        let want = mechanism == .disassociate && !g.isInFenced(pos) && g.distanceToZone(pos) < reach

        lastPosition = pos
        return MotionOutput(position: pos, rewrite: pos != e.location,
                            warp: cursorWithoutWarp != pos, wantDisassociated: want,
                            contact: step.contact, breach: breach, released: false)
    }
}
