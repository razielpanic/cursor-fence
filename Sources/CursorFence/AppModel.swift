import AppKit
import FenceCore
import Observation
import ServiceManagement

/// Settings and live status, owned by the main thread. Every change is
/// pushed to the engine as a fresh config.
@MainActor @Observable
final class AppModel {
    private let defaults = UserDefaults.standard
    private enum Key {
        static let fencedUUID = "fencedDisplayUUID"
        static let fencedName = "fencedDisplayName"
        static let releaseKeys = "releaseKeys"
        static let band = "guardBand"
        static let mechanism = "mechanism"
    }

    var fencedUUID: String? {
        didSet {
            defaults.set(fencedUUID, forKey: Key.fencedUUID)
            if let d = displays.first(where: { $0.id == fencedUUID }) {
                fencedName = d.name
                defaults.set(d.name, forKey: Key.fencedName)
            }
            pushConfig()
        }
    }
    private(set) var fencedName: String?
    var releaseKeys: ReleaseKeys {
        didSet { defaults.set(Int(releaseKeys.rawValue), forKey: Key.releaseKeys); pushConfig() }
    }
    var band: Double {
        didSet { defaults.set(band, forKey: Key.band); pushConfig() }
    }
    var mechanism: Mechanism {
        didSet { defaults.set(mechanism.rawValue, forKey: Key.mechanism); pushConfig() }
    }

    private(set) var displays: [DisplayInfo] = []
    private(set) var accessibilityGranted = false
    private(set) var tapRunning = false
    private(set) var stats: [String: Int] = [:]
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var launchAtLoginNote: String?
    /// Name of the process that last posted pointer motion (Screen Sharing
    /// shows up here as screensharingd).
    private(set) var syntheticSource: String?

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLoginNote = nil
        } catch {
            launchAtLoginNote = error.localizedDescription
        }
        let status = SMAppService.mainApp.status
        launchAtLogin = status == .enabled
        if status == .requiresApproval {
            launchAtLoginNote = "Approve Cursor Fence in System Settings › General › Login Items."
        }
    }

    let engine: FenceEngine
    let glow = GlowOverlay()

    init() {
        let d = UserDefaults.standard
        fencedUUID = d.string(forKey: Key.fencedUUID)
        fencedName = d.string(forKey: Key.fencedName)
        releaseKeys = d.object(forKey: Key.releaseKeys) == nil
            ? .defaultKeys : ReleaseKeys(rawValue: UInt64(d.integer(forKey: Key.releaseKeys)))
        band = d.object(forKey: Key.band) == nil ? 240 : d.double(forKey: Key.band)
        mechanism = Mechanism(rawValue: d.string(forKey: Key.mechanism) ?? "") ?? .disassociate
        engine = FenceEngine(config: EngineConfig(geometry: nil, releaseKeys: .defaultKeys, mechanism: .disassociate, band: 240))
        engine.onContact = { [weak self] contact, pointer in
            MainActor.assumeIsolated { self?.rebound(contact, pointer) }
        }
        refreshDisplays()
    }

    var fencedDisplay: DisplayInfo? { displays.first { $0.id == fencedUUID } }
    var geometry: FenceGeometry? { Displays.geometry(fencing: fencedUUID) }

    var statusLine: String {
        if !accessibilityGranted { return "Off — waiting for Accessibility permission" }
        if !tapRunning { return "Off — event tap not running" }
        guard fencedUUID != nil else { return "Off — choose a display to fence" }
        guard fencedDisplay != nil else { return "Off — \(fencedName ?? "the fenced display") is not connected" }
        if displays.count < 2 { return "Off — only one display is connected" }
        let keys = releaseKeys.isEmpty ? "no release key" : "hold \(releaseKeys.symbols) to cross"
        return "On — fencing \(fencedDisplay!.name); \(keys)"
    }

    func refreshDisplays() {
        displays = Displays.active()
        if let d = fencedDisplay, fencedName != d.name {
            fencedName = d.name
            defaults.set(d.name, forKey: Key.fencedName)
        }
        pushConfig()
    }

    func pushConfig() {
        engine.update(EngineConfig(geometry: geometry, releaseKeys: releaseKeys,
                                   mechanism: mechanism, band: CGFloat(band)))
    }

    func refreshStatus() {
        accessibilityGranted = AXIsProcessTrusted()
        tapRunning = engine.isRunning
        launchAtLogin = SMAppService.mainApp.status == .enabled
        let pid = engine.stats.lastSyntheticPID.load(ordering: .relaxed)
        if pid > 0 { syntheticSource = processName(pid_t(pid)) }
        var s = engine.stats.snapshot()
        s["glowShown"] = glow.shown
        s["glowRefused"] = glow.refused
        stats = s
    }

    func setTapRunning(_ running: Bool) { tapRunning = running }

    private func rebound(_ contact: Contact, _ pointer: CGPoint) {
        guard let g = geometry else { return }
        glow.show(seamPoint: contact.seamPoint, pointer: pointer, geometry: g)
    }

    /// Written once a second for the leak-test harness and for diagnosis.
    func writeStats() {
        refreshStatus()
        var out: [String: Any] = stats
        out["fencedUUID"] = fencedUUID ?? ""
        out["mechanism"] = mechanism.rawValue
        out["band"] = band
        out["disassociated"] = engine.isDisassociated
        out["syntheticSource"] = syntheticSource ?? ""
        out["launchAtLogin"] = launchAtLogin
        if let f = glow.lastFrameCG { out["lastGlowFrame"] = [f.minX, f.minY, f.width, f.height] }
        if let g = geometry { out["zone"] = [g.zone.minX, g.zone.minY, g.zone.width, g.zone.height] }
        guard let data = try? JSONSerialization.data(withJSONObject: out, options: [.sortedKeys, .prettyPrinted]) else { return }
        try? data.write(to: AppModel.statsURL, options: .atomic)
    }

    private func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 256)
        let n = proc_name(pid, &buf, UInt32(buf.count))
        return n > 0 ? "\(String(cString: buf)) (\(pid))" : "pid \(pid)"
    }

    static let statsURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CursorFence", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("stats.json")
    }()
}
