import Foundation

/// Persisted view of the FF400's live mixer RAM.
///
/// The device's mixer cells are effectively write-only through the ASFW
/// user client (AR responses never reach user-space transactions on the
/// current build), so — like FFADO — we track the state we wrote and
/// re-apply it on demand.
public struct MixerState: Codable, Equatable {
    /// Input → output fader gains, row-major [dest][src] order:
    /// index = src * 18 + dest... documented below as src*18+dest.
    /// Stored flat: input[src][dest] → input[src*18+dest].
    public var input: [UInt32]
    public var playback: [UInt32]
    public var output: [UInt32]
    /// Raw amp-gain register values last written (index → devval).
    public var ampGains: [String: UInt32]

    public init() {
        input = [UInt32](repeating: 0, count: 324)
        playback = [UInt32](repeating: 0, count: 324)
        // playback 1:1 at unity by default (Mac audio out)
        for i in 0..<Fireface400.channelCount {
            playback[i * Fireface400.channelCount + i] = Fireface400.unityGain
        }
        output = [UInt32](repeating: Fireface400.unityGain, count: Fireface400.channelCount)
        ampGains = [:]
    }

    public static func index(src: Int, dest: Int) -> Int {
        src * Fireface400.channelCount + dest
    }

    // MARK: - Persistence

    public static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ff400ctl", isDirectory: true)
        return dir.appendingPathComponent("state.json")
    }

    public static func load() -> MixerState {
        let url = storeURL
        guard let data = try? Data(contentsOf: url),
              var state = try? JSONDecoder().decode(MixerState.self, from: data)
        else { return MixerState() }
        // Defensive: arrays must be the right size even if file is stale.
        if state.input.count != 324 { state.input = MixerState().input }
        if state.playback.count != 324 { state.playback = MixerState().playback }
        if state.output.count != Fireface400.channelCount { state.output = MixerState().output }
        return state
    }

    public func save() {
        let url = MixerState.storeURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(self) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
