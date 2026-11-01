/// Modifier keys that, held together, let the pointer cross into the fenced
/// display. Raw values are the matching `CGEventFlags` masks, so a mouse
/// event's flags can be tested directly.
public struct ReleaseKeys: OptionSet, Sendable, Hashable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let shift = ReleaseKeys(rawValue: 0x0002_0000)    // maskShift
    public static let control = ReleaseKeys(rawValue: 0x0004_0000)  // maskControl
    public static let option = ReleaseKeys(rawValue: 0x0008_0000)   // maskAlternate
    public static let command = ReleaseKeys(rawValue: 0x0010_0000)  // maskCommand
    public static let function = ReleaseKeys(rawValue: 0x0080_0000) // maskSecondaryFn

    public static let all: ReleaseKeys = [.control, .option, .shift, .command, .function]
    public static let defaultKeys: ReleaseKeys = [.option]

    /// True when every chosen key is down. Other modifiers (Caps Lock, or keys
    /// not chosen) do not matter. An empty set never releases the fence.
    public func isHeld(flags: UInt64) -> Bool {
        let wanted = rawValue & ReleaseKeys.all.rawValue
        return wanted != 0 && flags & wanted == wanted
    }

    /// Display order and symbols, matching the macOS menu convention.
    public static let ordered: [(key: ReleaseKeys, symbol: String, name: String)] = [
        (.control, "⌃", "Control"),
        (.option, "⌥", "Option"),
        (.shift, "⇧", "Shift"),
        (.command, "⌘", "Command"),
        (.function, "fn", "Function"),
    ]

    public var symbols: String {
        ReleaseKeys.ordered.filter { contains($0.key) }.map(\.symbol).joined()
    }
}
