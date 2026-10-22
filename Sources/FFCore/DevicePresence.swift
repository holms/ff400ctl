/// Decides whether a CoreAudio device name belongs to the Fireface 400
/// and tracks absent→present transitions so the mixer can be re-applied
/// when the unit returns from a power cycle.
public enum DevicePresence {
    public static func isFireface400(name: String) -> Bool {
        name.range(of: "fireface 400", options: .caseInsensitive) != nil
    }

    /// Reports `true` exactly once per absent→present edge — launching
    /// while the unit is present must not count as a transition.
    public struct Tracker {
        public private(set) var present: Bool
        public init(present: Bool) { self.present = present }

        public mutating func update(present now: Bool) -> Bool {
            let edge = now && !present
            present = now
            return edge
        }
    }
}
