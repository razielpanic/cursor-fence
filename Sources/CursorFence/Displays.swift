import AppKit
import ColorSync
import CoreGraphics
import FenceCore

struct DisplayInfo: Identifiable, Hashable {
    /// Stable across reconnects and re-arrangement, unlike the display ID.
    let id: String
    let displayID: CGDirectDisplayID
    let name: String
    /// Global CG coordinates.
    let bounds: CGRect
    let isMain: Bool
    let isBuiltin: Bool

    var label: String {
        var tags: [String] = []
        if isBuiltin { tags.append("built-in") }
        if isMain { tags.append("main") }
        let size = "\(Int(bounds.width))×\(Int(bounds.height))"
        return tags.isEmpty ? "\(name) — \(size)" : "\(name) — \(size) (\(tags.joined(separator: ", ")))"
    }
}

enum Displays {
    static func uuid(of id: CGDirectDisplayID) -> String? {
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String?
    }

    @MainActor
    static func active() -> [DisplayInfo] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(16, &ids, &count) == .success else { return [] }
        let names = Dictionary(NSScreen.screens.compactMap { s -> (CGDirectDisplayID, String)? in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (n.uint32Value, s.localizedName)
        }, uniquingKeysWith: { a, _ in a })
        return ids.prefix(Int(count)).compactMap { id in
            // A mirror set reports its members; only the primary counts.
            guard CGDisplayMirrorsDisplay(id) == kCGNullDirectDisplay, let u = uuid(of: id) else { return nil }
            return DisplayInfo(id: u, displayID: id, name: names[id] ?? "Display \(id)",
                               bounds: CGDisplayBounds(id), isMain: CGDisplayIsMain(id) != 0,
                               isBuiltin: CGDisplayIsBuiltin(id) != 0)
        }
    }

    /// The accessibility cursor size (1.0 = normal, up to 4.0).
    static func cursorScale() -> CGFloat {
        let v = UserDefaults(suiteName: "com.apple.universalaccess")?.double(forKey: "mouseDriverCursorSize") ?? 1
        return v > 0 ? v : 1
    }

    /// Geometry for fencing `uuid`, or nil when that display is not connected
    /// (the fence is then inactive) or is the only display.
    @MainActor
    static func geometry(fencing uuid: String?) -> FenceGeometry? {
        let all = active()
        guard let uuid, let fenced = all.first(where: { $0.id == uuid }) else { return nil }
        let rest = all.filter { $0.id != uuid }
        guard !rest.isEmpty else { return nil }
        return FenceGeometry(fenced: fenced.bounds, others: rest.map(\.bounds),
                             extent: .standard(cursorScale: cursorScale()),
                             otherScales: rest.map { backingScale($0.displayID) })
    }

    /// Pixels per point of a display's current mode (2 on a Retina panel).
    static func backingScale(_ id: CGDirectDisplayID) -> CGFloat {
        guard let mode = CGDisplayCopyDisplayMode(id), mode.width > 0 else { return 1 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    static var mainDisplayHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }
}
