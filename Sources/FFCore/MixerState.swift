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
    /// Device config block (phantom, pads, levels, clock) — write-only
    /// register, so we track it and rewrite the whole block on change.
    public var config: Fireface400.ConfigBlock
    /// Per-row flags (TotalMix channel-strip semantics, applied to every
    /// matrix cell of the row). Phase = negative gain written to hardware.
    public var inputMute: [Bool]
    public var inputPhase: [Bool]
    public var inputSolo: [Bool]
    public var outputMute: [Bool]
    /// When true, the monitor bus pair is mono-locked (L and R cells equal).
    public var monoBus: Bool

    public init() {
        input = [UInt32](repeating: 0, count: 324)
        playback = [UInt32](repeating: 0, count: 324)
        // playback 1:1 at unity by default (Mac audio out)
        for i in 0..<Fireface400.channelCount {
            playback[i * Fireface400.channelCount + i] = Fireface400.unityGain
        }
        output = [UInt32](repeating: Fireface400.unityGain, count: Fireface400.channelCount)
        ampGains = [:]
        config = Fireface400.ConfigBlock()
        inputMute = [Bool](repeating: false, count: Fireface400.channelCount)
        inputPhase = [Bool](repeating: false, count: Fireface400.channelCount)
        inputSolo = [Bool](repeating: false, count: Fireface400.channelCount)
        outputMute = [Bool](repeating: false, count: Fireface400.channelCount)
        monoBus = false
    }

    public static func index(src: Int, dest: Int) -> Int {
        src * Fireface400.channelCount + dest
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decode([UInt32].self, forKey: .input)
        playback = try c.decode([UInt32].self, forKey: .playback)
        output = try c.decode([UInt32].self, forKey: .output)
        ampGains = try c.decode([String: UInt32].self, forKey: .ampGains)
        config = try c.decodeIfPresent(Fireface400.ConfigBlock.self, forKey: .config)
            ?? Fireface400.ConfigBlock()
        inputMute = try c.decodeIfPresent([Bool].self, forKey: .inputMute)
            ?? [Bool](repeating: false, count: Fireface400.channelCount)
        inputPhase = try c.decodeIfPresent([Bool].self, forKey: .inputPhase)
            ?? [Bool](repeating: false, count: Fireface400.channelCount)
        inputSolo = try c.decodeIfPresent([Bool].self, forKey: .inputSolo)
            ?? [Bool](repeating: false, count: Fireface400.channelCount)
        outputMute = try c.decodeIfPresent([Bool].self, forKey: .outputMute)
            ?? [Bool](repeating: false, count: Fireface400.channelCount)
        monoBus = try c.decodeIfPresent(Bool.self, forKey: .monoBus) ?? false
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

    // MARK: - Snapshots (named presets, TotalMix "workspace" style)

    public static var snapshotsDir: URL {
        storeURL.deletingLastPathComponent().appendingPathComponent("snapshots", isDirectory: true)
    }

    public static func snapshotURL(name: String) -> URL {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let safe = name.components(separatedBy: allowed.inverted).joined()
        return snapshotsDir.appendingPathComponent("\(safe.isEmpty ? "snapshot" : safe).json")
    }

    public func saveSnapshot(name: String) -> Bool {
        let url = MixerState.snapshotURL(name: name)
        do {
            try FileManager.default.createDirectory(at: MixerState.snapshotsDir,
                                                    withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: url, options: .atomic)
            return true
        } catch { return false }
    }

    public static func loadSnapshot(name: String) -> MixerState? {
        let url = snapshotURL(name: name)
        guard let data = try? Data(contentsOf: url),
              var state = try? JSONDecoder().decode(MixerState.self, from: data)
        else { return nil }
        if state.input.count != 324 { state.input = MixerState().input }
        if state.playback.count != 324 { state.playback = MixerState().playback }
        if state.output.count != Fireface400.channelCount { state.output = MixerState().output }
        return state
    }

    public static func snapshotNames() -> [String] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: snapshotsDir, includingPropertiesForKeys: nil)
        else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent }.sorted()
    }

    public static func deleteSnapshot(name: String) -> Bool {
        let url = snapshotURL(name: name)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        return (try? FileManager.default.removeItem(at: url)) != nil
    }
}
