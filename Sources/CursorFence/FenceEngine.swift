import ApplicationServices
import CoreGraphics
import FenceCore
import Foundation
import os
import Synchronization

let log = Logger(subsystem: "com.razielpanic.CursorFence", category: "fence")

struct EngineConfig: Sendable {
    var geometry: FenceGeometry?
    var releaseKeys: ReleaseKeys
    var mechanism: Mechanism
    var band: CGFloat
}

/// Counters for diagnostics; written on the tap thread, read anywhere.
final class EngineStats: Sendable {
    let hardwareEvents = Atomic<Int>(0)
    let syntheticEvents = Atomic<Int>(0)
    let contacts = Atomic<Int>(0)
    let breaches = Atomic<Int>(0)
    let tapRestarts = Atomic<Int>(0)
    let watchdogTrips = Atomic<Int>(0)
    let engagements = Atomic<Int>(0)
    /// Largest single hardware motion seen, in hundredths of a point.
    let maxHardwareDelta = Atomic<Int>(0)
    /// Closest the pointer had come to the zone when the mouse was
    /// disassociated, in hundredths of a point. If this nears zero, the band
    /// is too thin for the motion it is getting. Int.max until first engage.
    let closestEngage = Atomic<Int>(.max)

    func snapshot() -> [String: Int] {
        [
            "hardwareEvents": hardwareEvents.load(ordering: .relaxed),
            "syntheticEvents": syntheticEvents.load(ordering: .relaxed),
            "contacts": contacts.load(ordering: .relaxed),
            "breaches": breaches.load(ordering: .relaxed),
            "tapRestarts": tapRestarts.load(ordering: .relaxed),
            "watchdogTrips": watchdogTrips.load(ordering: .relaxed),
            "engagements": engagements.load(ordering: .relaxed),
            "maxHardwareDeltaPt": maxHardwareDelta.load(ordering: .relaxed) / 100,
            "closestEngagePt": closestEngage.load(ordering: .relaxed) == .max
                ? -1 : closestEngage.load(ordering: .relaxed) / 100,
        ]
    }
}

/// The wall. Runs a HID-level event tap on its own thread; every per-event
/// path stays off the main thread and allocation-free.
///
/// Invariant: the mouse is disassociated only while the tap is alive and the
/// pointer is in the band beside the fenced display. Every way out — release
/// key, leaving the band, tap disabled, watchdog, suspend, stop, quit,
/// signal, crash guardian — re-associates.
final class FenceEngine: @unchecked Sendable {
    let stats = EngineStats()
    /// Called on the main queue for each rebound: (contact, pointer position).
    var onContact: (@Sendable (Contact, CGPoint) -> Void)?

    // Shared state.
    private let pendingConfig: Mutex<EngineConfig>
    private let configGeneration = Atomic<UInt64>(1)
    private let disassociated = Mutex<Bool>(false)
    private let lastAssertNanos = Atomic<UInt64>(0)
    private let lastTapEventNanos = Atomic<UInt64>(0)
    private let suspended = Atomic<Bool>(false)
    private let lifecycle = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var watchdog: DispatchSourceTimer?

    // Tap-thread-only state.
    private var decider = Decider(geometry: nil, releaseKeys: .defaultKeys, mechanism: .disassociate, band: 240)
    private var appliedGeneration: UInt64 = 0
    private var recoilTimer: CFRunLoopTimer?
    private var recoilStart: UInt64 = 0
    private var recoilNormal = CGVector.zero
    private var recoilApplied: CGFloat = 0
    private var recoilActive = false
    private var lastFeedbackNanos: UInt64 = 0

    static let recoilDistance: CGFloat = 14
    static let recoilDuration: Double = 0.14
    static let feedbackCooldown: UInt64 = 300_000_000

    init(config: EngineConfig) {
        pendingConfig = Mutex(config)
    }

    var isRunning: Bool { lifecycle.withLock { tap != nil } }
    var isDisassociated: Bool { disassociated.withLock { $0 } }

    func update(_ config: EngineConfig) {
        pendingConfig.withLock { $0 = config }
        configGeneration.add(1, ordering: .releasing)
        if config.geometry == nil || config.mechanism == .rewriteOnly { associate(reason: "config") }
    }

    // MARK: Lifecycle

    /// Starts the tap. Returns false when the tap cannot be created, which in
    /// practice means Accessibility has not been granted.
    @discardableResult
    func start() -> Bool {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard tap == nil else { return true }

        let mask: CGEventMask = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged,
                                 .otherMouseDragged, .flagsChanged]
            .reduce(0) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: tapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            log.error("tapCreate failed (Accessibility not granted?)")
            return false
        }
        tap = port
        lastTapEventNanos.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)

        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let rl = CFRunLoopGetCurrent()!
            // Read under start()'s lock, which is held until `ready` fires.
            guard let port = self.tap else { ready.signal(); return }
            let source = CFMachPortCreateRunLoopSource(nil, port, 0)
            CFRunLoopAddSource(rl, source, .commonModes)
            let timer = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 1.0 / 240, 0, 0) { [unowned self] _ in
                self.recoilTick()
            }
            CFRunLoopAddTimer(rl, timer, .commonModes)
            self.recoilTimer = timer
            self.runLoop = rl
            CGEvent.tapEnable(tap: port, enable: true)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "cursor-fence.tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        startWatchdog()
        log.notice("fence tap started")
        return true
    }

    func stop() {
        associate(reason: "stop")
        lifecycle.lock()
        defer { lifecycle.unlock() }
        watchdog?.cancel()
        watchdog = nil
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let rl = runLoop { CFRunLoopStop(rl) }
        tap = nil
        runLoop = nil
        associate(reason: "stop")
    }

    /// Display reconfiguration, sleep, screen lock: let go of the mouse and
    /// ignore motion until `resume`.
    func suspend(reason: String) {
        suspended.store(true, ordering: .sequentiallyConsistent)
        associate(reason: reason)
    }

    func resume() {
        suspended.store(false, ordering: .sequentiallyConsistent)
    }

    // MARK: Association

    /// Re-associates the mouse. Safe from any thread; idempotent.
    func associate(reason: String) {
        disassociated.withLock { dis in
            if dis {
                CGAssociateMouseAndMouseCursorPosition(1)
                dis = false
                log.debug("associated: \(reason, privacy: .public)")
            }
        }
    }

    private func setDisassociated(_ want: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        disassociated.withLock { dis in
            if want != dis {
                CGAssociateMouseAndMouseCursorPosition(want ? 0 : 1)
                dis = want
                if want { lastAssertNanos.store(now, ordering: .relaxed) }
            } else if want, now &- lastAssertNanos.load(ordering: .relaxed) > 100_000_000 {
                // Another process (a game, a remote-control tool) may have
                // re-associated behind our back. Re-assert while engaged.
                CGAssociateMouseAndMouseCursorPosition(0)
                lastAssertNanos.store(now, ordering: .relaxed)
            }
        }
    }

    // MARK: Tap

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        lastTapEventNanos.store(DispatchTime.now().uptimeNanoseconds, ordering: .relaxed)

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Let go first, then come back.
            associate(reason: "tap disabled")
            stats.tapRestarts.add(1, ordering: .relaxed)
            decider.reset(at: nil)
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            refreshConfig()
            if decider.releaseKeys.isHeld(flags: event.flags.rawValue) {
                associate(reason: "release key")
                recoilActive = false
            }
            return Unmanaged.passUnretained(event)

        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            break

        default:
            return Unmanaged.passUnretained(event)
        }

        refreshConfig()
        if suspended.load(ordering: .relaxed) {
            associate(reason: "suspended")
            decider.reset(at: event.location)
            return Unmanaged.passUnretained(event)
        }

        let synthetic = event.getIntegerValueField(.eventSourceUnixProcessID) != 0
        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let dy = event.getDoubleValueField(.mouseEventDeltaY)
        let wasDisassociated = isDisassociated
        if synthetic {
            stats.syntheticEvents.add(1, ordering: .relaxed)
        } else {
            stats.hardwareEvents.add(1, ordering: .relaxed)
            let mag = Int((dx * dx + dy * dy).squareRoot() * 100)
            if mag > stats.maxHardwareDelta.load(ordering: .relaxed) {
                stats.maxHardwareDelta.store(mag, ordering: .relaxed)
            }
        }

        let out = decider.handle(MotionInput(location: event.location, delta: CGVector(dx: dx, dy: dy),
                                             isSynthetic: synthetic, flags: event.flags.rawValue,
                                             disassociated: wasDisassociated))
        if out.released { recoilActive = false }
        if out.breach {
            stats.breaches.add(1, ordering: .relaxed)
            log.error("breach: hardware motion reached the zone while associated")
        }
        if out.warp { CGWarpMouseCursorPosition(out.position) }
        if out.rewrite { event.location = out.position }

        if out.wantDisassociated, !wasDisassociated, let g = decider.geometry {
            stats.engagements.add(1, ordering: .relaxed)
            let d = Int(g.distanceToZone(out.position) * 100)
            if d < stats.closestEngage.load(ordering: .relaxed) { stats.closestEngage.store(d, ordering: .relaxed) }
        }
        setDisassociated(out.wantDisassociated)

        if let c = out.contact { contact(c, at: out.position) }
        return Unmanaged.passUnretained(event)
    }

    private func refreshConfig() {
        let gen = configGeneration.load(ordering: .acquiring)
        guard gen != appliedGeneration else { return }
        appliedGeneration = gen
        let c = pendingConfig.withLock { $0 }
        decider.geometry = c.geometry
        decider.releaseKeys = c.releaseKeys
        decider.mechanism = c.mechanism
        decider.band = c.band
        decider.reset(at: nil)
        recoilActive = false
    }

    // MARK: Rebound

    private func contact(_ c: Contact, at p: CGPoint) {
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastFeedbackNanos > Self.feedbackCooldown else { return }
        lastFeedbackNanos = now
        stats.contacts.add(1, ordering: .relaxed)

        recoilStart = now
        recoilNormal = c.normal
        recoilApplied = 0
        recoilActive = true
        if let t = recoilTimer { CFRunLoopTimerSetNextFireDate(t, CFAbsoluteTimeGetCurrent()) }

        if let handler = onContact {
            DispatchQueue.main.async { handler(c, p) }
        }
    }

    private func recoilTick() {
        guard recoilActive, !suspended.load(ordering: .relaxed),
              let g = decider.geometry, let p = decider.lastPosition else {
            stopRecoil()
            return
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- recoilStart) / 1e9
        let d = Feedback.recoilDistance(elapsed: elapsed, duration: Self.recoilDuration, distance: Self.recoilDistance)
        let inc = d - recoilApplied
        recoilApplied = d
        if inc > 0 {
            let target = CGPoint(x: p.x + recoilNormal.dx * inc, y: p.y + recoilNormal.dy * inc)
            let q = g.step(from: p, to: target).point
            CGWarpMouseCursorPosition(q)
            decider.reset(at: q)
        }
        if elapsed >= Self.recoilDuration { stopRecoil() }
    }

    private func stopRecoil() {
        recoilActive = false
        if let t = recoilTimer { CFRunLoopTimerSetNextFireDate(t, .greatestFiniteMagnitude) }
    }

    // MARK: Watchdog

    /// Lets go of the mouse if the tap stops hearing motion the HID system is
    /// still producing (Accessibility revoked, tap killed, thread wedged).
    private func startWatchdog() {
        let q = DispatchQueue(label: "cursor-fence.watchdog", qos: .userInteractive)
        let t = DispatchSource.makeTimerSource(queue: q)
        var ticks = 0
        t.schedule(deadline: .now() + 0.05, repeating: 0.05)
        t.setEventHandler { [weak self] in
            guard let self, self.isDisassociated else { return }
            ticks += 1
            var reason: String?
            if let port = self.lifecycle.withLock({ self.tap }), !CGEvent.tapIsEnabled(tap: port) {
                reason = "tap disabled"
            }
            let hidIdle = [CGEventType.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
                .map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }
                .min() ?? .infinity
            let tapIdle = Double(DispatchTime.now().uptimeNanoseconds &- self.lastTapEventNanos.load(ordering: .relaxed)) / 1e9
            if tapIdle - hidIdle > 0.15 { reason = "tap starved (\(Int(tapIdle * 1000))ms)" }
            if ticks % 10 == 0, !AXIsProcessTrusted() { reason = "accessibility revoked" }
            if let reason {
                self.associate(reason: reason)
                self.stats.watchdogTrips.add(1, ordering: .relaxed)
                log.error("watchdog: \(reason, privacy: .public)")
            }
        }
        t.resume()
        watchdog = t
    }
}

private let tapCallback: CGEventTapCallBack = { _, type, event, refcon in
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<FenceEngine>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
