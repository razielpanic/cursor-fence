// FenceHarness: measures whether the cursor ever appears on the fenced display.
//
// It covers the fenced display with a black window, records that display
// with ScreenCaptureKit (cursor shown, up to 120 fps, capturing only the black
// window plus the cursor), and counts frames with any bright pixels — the
// cursor. Meanwhile it either drives the pointer with synthetic events or
// waits while a person flicks the real mouse.
//
// Synthetic events carry an absolute location, which the window server applies
// whether or not the mouse is disassociated. So `--drive synthetic` measures
// the tap's location rewrite, not the disassociation path; that path needs a
// real hand on the mouse (`--drive manual`).
//
// Usage:
//   FenceHarness leak --drive synthetic|manual [--seconds N] [--hold option] [--out DIR]
//   FenceHarness feedback [--pushes N]

import AppKit
import CoreMedia
import FenceCore
import Foundation
@preconcurrency import ScreenCaptureKit
import Synchronization

// MARK: Arguments and shared helpers

let args = Array(CommandLine.arguments.dropFirst())
func opt(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let command = args.first ?? "leak"
let seconds = Double(opt("--seconds") ?? "20") ?? 20
let drive = opt("--drive") ?? "synthetic"
let holdFlags: UInt64 = {
    var f: UInt64 = 0
    for k in (opt("--hold") ?? "").split(separator: ",") {
        switch k {
        case "option": f |= ReleaseKeys.option.rawValue
        case "control": f |= ReleaseKeys.control.rawValue
        case "shift": f |= ReleaseKeys.shift.rawValue
        case "command": f |= ReleaseKeys.command.rawValue
        case "fn": f |= ReleaseKeys.function.rawValue
        default: break
        }
    }
    return f
}()
let outDir = URL(fileURLWithPath: opt("--out") ?? "test-results")

let statsURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("CursorFence/stats.json")
func appStats() -> [String: Any] {
    guard let d = try? Data(contentsOf: statsURL),
          let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return j
}
func int(_ d: [String: Any], _ k: String) -> Int { (d[k] as? NSNumber)?.intValue ?? 0 }

func displayUUID(_ id: CGDirectDisplayID) -> String? {
    guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
    return CFUUIDCreateString(nil, u) as String?
}
func activeDisplays() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 16)
    var n: UInt32 = 0
    CGGetActiveDisplayList(16, &ids, &n)
    return Array(ids.prefix(Int(n)))
}
func cursorLocation() -> CGPoint { CGEvent(source: nil)?.location ?? .zero }

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("FenceHarness: \(msg)\n".utf8))
    exit(2)
}

// The fenced display: --display UUID, else whatever Cursor Fence is fencing.
let fencedUUID = opt("--display") ?? (appStats()["fencedUUID"] as? String ?? "")
let fencedID: CGDirectDisplayID = {
    guard let id = activeDisplays().first(where: { displayUUID($0) == fencedUUID }) else {
        fail("no fenced display (is Cursor Fence running with a display chosen?)")
    }
    return id
}()
let F = CGDisplayBounds(fencedID)
let others = activeDisplays().filter { $0 != fencedID }.map { CGDisplayBounds($0) }
let mainHeight = CGDisplayBounds(CGMainDisplayID()).height

/// The shared seam between the fenced display and the work display beside it.
struct Seam {
    var center: CGPoint
    var normal: CGVector   // from the fenced display toward the work side
    var tangent: CGVector
    var halfLength: CGFloat
}
func findSeam() -> Seam {
    for w in others {
        let r = F.insetBy(dx: -1, dy: -1).intersection(w)
        guard !r.isNull, r.width > 0, r.height > 0 else { continue }
        if r.width <= 2 {  // vertical seam
            let n = CGVector(dx: w.midX > F.midX ? 1 : -1, dy: 0)
            return Seam(center: CGPoint(x: n.dx > 0 ? F.maxX : F.minX, y: r.midY), normal: n,
                        tangent: CGVector(dx: 0, dy: 1), halfLength: r.height / 2)
        } else {
            let n = CGVector(dx: 0, dy: w.midY > F.midY ? 1 : -1)
            return Seam(center: CGPoint(x: r.midX, y: n.dy > 0 ? F.maxY : F.minY), normal: n,
                        tangent: CGVector(dx: 1, dy: 0), halfLength: r.width / 2)
        }
    }
    fail("the fenced display shares no edge with another display")
}
let seam = findSeam()
func at(_ along: CGFloat, _ out: CGFloat) -> CGPoint {
    CGPoint(x: seam.center.x + seam.tangent.dx * along + seam.normal.dx * out,
            y: seam.center.y + seam.tangent.dy * along + seam.normal.dy * out)
}

// MARK: Synthetic driver

final class Driver: @unchecked Sendable {
    let source = CGEventSource(stateID: .hidSystemState)
    var last = cursorLocation()
    var posted = 0

    init() { source?.localEventsSuppressionInterval = 0 }

    func move(to p: CGPoint, flags: UInt64 = holdFlags) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: .mouseMoved,
                              mouseCursorPosition: p, mouseButton: .left) else { return }
        e.setIntegerValueField(.mouseEventDeltaX, value: Int64((p.x - last.x).rounded()))
        e.setIntegerValueField(.mouseEventDeltaY, value: Int64((p.y - last.y).rounded()))
        e.flags = CGEventFlags(rawValue: flags)
        e.post(tap: .cghidEventTap)
        last = p
        posted += 1
        usleep(1000)
    }

    /// Hammers the seam until `deadline`: flicks, fast approaches, grinding,
    /// corner dives and huge tunnelling jumps.
    func hammer(until deadline: Date) {
        var rng = SystemRandomNumberGenerator()
        let L = max(1, seam.halfLength - 4)
        while Date() < deadline {
            let a = CGFloat.random(in: -L...L, using: &rng)
            // Flick: one event from well clear to deep inside.
            move(to: at(a, 400)); move(to: at(a, -900))
            // Fast approach: 60pt per millisecond event.
            for i in 0..<20 { move(to: at(a, 600 - CGFloat(i) * 60)) }
            // Grind: small pushes, sliding along the seam.
            for i in 0..<80 {
                let b = max(-L, min(L, a + CGFloat(i) * 3 - 120))
                move(to: at(b, CGFloat.random(in: -6...4, using: &rng)))
            }
            // Corner dives at both ends of the seam.
            move(to: at(L, 300)); move(to: at(L + 200, -200))
            move(to: at(-L, 300)); move(to: at(-L - 200, -200))
            // Tunnel: from right beside the wall to far past it.
            move(to: at(a, 25)); move(to: at(a, -3000))
        }
    }
}

// MARK: Recorder

final class Recorder: NSObject, SCStreamOutput, @unchecked Sendable {
    let frames = Atomic<Int>(0)
    let leakFrames = Atomic<Int>(0)
    let maxBright = Atomic<Int>(0)
    private let lock = NSLock()
    private var leakTimes: [Double] = []
    private var savedLeaks = 0
    private let start = Date()
    private var stream: SCStream?
    let queue = DispatchQueue(label: "harness.capture", qos: .userInteractive)

    func start(windowID: CGWindowID) async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == fencedID }) else { fail("SCK cannot see the fenced display") }
        guard let black = content.windows.first(where: { $0.windowID == windowID }) else {
            fail("SCK cannot see the black test window")
        }
        let filter = SCContentFilter(display: display, including: [black])
        let config = SCStreamConfiguration()
        config.width = Int(F.width)
        config.height = Int(F.height)
        config.showsCursor = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 120)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.queueDepth = 8
        let s = SCStream(filter: filter, configuration: config, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await s.startCapture()
        stream = s
    }

    func stop() async { try? await stream?.stopCapture() }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let info = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete,
              let pb = CMSampleBufferGetImageBuffer(sb) else { return }
        frames.add(1, ordering: .relaxed)

        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        // Any channel above 48 on a black field is something drawn: the cursor.
        var bright = 0
        for y in 0..<h {
            let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt32.self)
            for x in 0..<w {
                let v = row[x]
                if v & 0xFF > 48 || (v >> 8) & 0xFF > 48 || (v >> 16) & 0xFF > 48 { bright += 1 }
            }
        }
        if bright > maxBright.load(ordering: .relaxed) { maxBright.store(bright, ordering: .relaxed) }
        guard bright >= 4 else { return }
        leakFrames.add(1, ordering: .relaxed)
        lock.lock()
        leakTimes.append(Date().timeIntervalSince(start))
        let save = savedLeaks < 5
        if save { savedLeaks += 1 }
        let index = savedLeaks
        lock.unlock()
        if save, let img = CIContext().createCGImage(CIImage(cvPixelBuffer: pb), from: CGRect(x: 0, y: 0, width: w, height: h)) {
            let rep = NSBitmapImageRep(cgImage: img)
            try? FileManager.default.createDirectory(at: outDir.appendingPathComponent("frames"), withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?
                .write(to: outDir.appendingPathComponent("frames/leak-\(index).png"))
        }
    }

    var times: [Double] { lock.withLock { leakTimes } }
}

// MARK: Glow placement sampler

let fencePID: pid_t = NSRunningApplication.runningApplications(withBundleIdentifier: "com.razielpanic.CursorFence")
    .first?.processIdentifier ?? -1

/// Polls the window list for Cursor Fence's windows: counts glow sightings on
/// the work screen and any window at all that overlaps the fenced display.
final class WindowSampler: @unchecked Sendable {
    let glowSamples = Atomic<Int>(0)
    let violations = Atomic<Int>(0)
    private let lock = NSLock()
    private var glowFrames: Set<String> = []
    private var timer: DispatchSourceTimer?

    func start() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "harness.windows"))
        t.schedule(deadline: .now(), repeating: 1.0 / 120)
        t.setEventHandler { [self] in
            guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return }
            for w in list where (w[kCGWindowOwnerPID as String] as? pid_t) == fencePID {
                guard let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
                let r = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
                if overlapArea(r, F) > 0 { violations.add(1, ordering: .relaxed) }
                if (w[kCGWindowName as String] as? String) == "Cursor Fence Glow" {
                    glowSamples.add(1, ordering: .relaxed)
                    lock.withLock { _ = glowFrames.insert("\(Int(r.minX)),\(Int(r.minY)) \(Int(r.width))×\(Int(r.height))") }
                }
            }
        }
        t.resume()
        timer = t
    }
    func stop() { timer?.cancel() }
    var frames: [String] { lock.withLock { Array(glowFrames).sorted() } }
}

// MARK: Commands

@MainActor
func coverFencedDisplay() -> NSWindow {
    let w = NSWindow(contentRect: Feedback.appKitRect(fromCG: F, mainDisplayHeight: mainHeight),
                     styleMask: .borderless, backing: .buffered, defer: false)
    w.backgroundColor = .black
    w.isOpaque = true
    w.level = .screenSaver
    w.ignoresMouseEvents = true
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    w.setFrame(Feedback.appKitRect(fromCG: F, mainDisplayHeight: mainHeight), display: true)
    w.orderFrontRegardless()
    return w
}

func printJSON(_ obj: [String: Any]) {
    let d = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: d, as: UTF8.self))
}

@MainActor
func runLeak() async throws {
    let window = coverFencedDisplay()
    try await Task.sleep(for: .milliseconds(500))
    let recorder = Recorder()
    try await recorder.start(windowID: CGWindowID(window.windowNumber))
    let sampler = WindowSampler()
    sampler.start()
    let before = appStats()
    try await Task.sleep(for: .milliseconds(300))

    let driver = Driver()
    let deadline = Date().addingTimeInterval(seconds)
    if drive == "synthetic" {
        await Task.detached { driver.hammer(until: deadline) }.value
        // Leave the pointer on the work side.
        driver.move(to: at(0, 300), flags: 0)
    } else {
        FileHandle.standardError.write(Data("RECORDING \(Int(seconds))s — flick the mouse at the fenced display now\n".utf8))
        try await Task.sleep(for: .seconds(seconds))
    }
    try await Task.sleep(for: .milliseconds(400))
    await recorder.stop()
    sampler.stop()
    window.orderOut(nil)
    let after = appStats()

    func delta(_ k: String) -> Int { int(after, k) - int(before, k) }
    printJSON([
        "drive": drive,
        "mechanism": after["mechanism"] ?? "?",
        "heldFlags": holdFlags,
        "seconds": seconds,
        "fencedDisplay": "\(fencedUUID) \(F)",
        "eventsPosted": driver.posted,
        "framesCaptured": recorder.frames.load(ordering: .relaxed),
        "leakedFrames": recorder.leakFrames.load(ordering: .relaxed),
        "leakTimes": recorder.times.prefix(20).map { (($0 * 1000).rounded()) / 1000 },
        "maxBrightPixels": recorder.maxBright.load(ordering: .relaxed),
        "app.rebounds": delta("contacts"),
        "app.breaches": delta("breaches"),
        "app.glowShown": delta("glowShown"),
        "app.glowRefused": delta("glowRefused"),
        "app.hardwareEvents": delta("hardwareEvents"),
        "app.syntheticEvents": delta("syntheticEvents"),
        "app.engagements": delta("engagements"),
        "app.maxHardwareDeltaPt": int(after, "maxHardwareDeltaPt"),
        "app.closestEngagePt": int(after, "closestEngagePt"),
        "app.maxBreachDepthPt": int(after, "maxBreachDepthPt"),
        "app.drivenEvents": delta("drivenEvents"),
        "app.slips": delta("slips"),
        "app.maxSlipPt": int(after, "maxSlipPt"),
        "app.watchdogTrips": delta("watchdogTrips"),
        "app.tapRestarts": delta("tapRestarts"),
        "windows.glowSamples": sampler.glowSamples.load(ordering: .relaxed),
        "windows.onFencedDisplay": sampler.violations.load(ordering: .relaxed),
        "windows.glowFrames": Array(sampler.frames.prefix(10)),
    ])
}

/// Pushes into the wall and watches what happens next: the pointer should
/// spring back from the wall, and one glow should appear on the work side.
@MainActor
func runFeedback() async throws {
    let pushes = Int(opt("--pushes") ?? "6") ?? 6
    let sampler = WindowSampler()
    sampler.start()
    let before = appStats()
    let driver = Driver()
    var recoils: [Double] = []
    for i in 0..<pushes {
        let a = CGFloat(i - pushes / 2) * min(30, seam.halfLength / CGFloat(pushes))
        driver.move(to: at(a, 200), flags: 0)
        try await Task.sleep(for: .milliseconds(50))
        driver.move(to: at(a, -300), flags: 0)
        try await Task.sleep(for: .milliseconds(300))
        let settled = cursorLocation()
        // How far the pointer settled from the wall (the zone face it hit).
        let z = (appStats()["zone"] as? [CGFloat]).map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) } ?? F
        let face = seam.normal.dx > 0 ? z.maxX : seam.normal.dx < 0 ? z.minX : seam.normal.dy > 0 ? z.maxY : z.minY
        recoils.append(Double(seam.normal.dx != 0 ? (settled.x - face) * seam.normal.dx : (settled.y - face) * seam.normal.dy))
        try await Task.sleep(for: .milliseconds(400))
    }
    sampler.stop()
    let after = appStats()
    printJSON([
        "pushes": pushes,
        "recoilPt": recoils.map { ($0 * 10).rounded() / 10 },
        "app.rebounds": int(after, "contacts") - int(before, "contacts"),
        "app.glowShown": int(after, "glowShown") - int(before, "glowShown"),
        "app.glowRefused": int(after, "glowRefused") - int(before, "glowRefused"),
        "windows.glowSamples": sampler.glowSamples.load(ordering: .relaxed),
        "windows.onFencedDisplay": sampler.violations.load(ordering: .relaxed),
        "windows.glowFrames": sampler.frames,
        "workDisplays": others.map { "\($0)" },
        "fencedDisplay": "\(F)",
    ])
}

_ = MainActor.assumeIsolated {
    NSApplication.shared.setActivationPolicy(.accessory)
}
Task { @MainActor in
    do {
        switch command {
        case "leak": try await runLeak()
        case "feedback": try await runFeedback()
        default: fail("unknown command \(command)")
        }
    } catch {
        fail("\(error)")
    }
    exit(0)
}
NSApplication.shared.run()
