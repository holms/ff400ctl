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
    /// Stereo-link flags for the 9 output pairs (TotalMix "stereo" button):
    /// pair i = channels 2i/2i+1; a linked pair moves as one fader.
    public var outputStereo: [Bool]

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
        outputStereo = [Bool](repeating: false, count: Fireface400.channelCount / 2)
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
        outputStereo = try c.decodeIfPresent([Bool].self, forKey: .outputStereo)
            ?? [Bool](repeating: false, count: Fireface400.channelCount / 2)
    }

    // MARK: - Persistence

    /// Directory holding state.json and snapshots/. Overridable with the
    /// FFCTL_STATE_DIR environment variable — used by the e2e tests and
    /// handy for portable/experimental setups.
    public static var stateDir: URL {
        if let p = getenv("FFCTL_STATE_DIR"), p.pointee != 0 {
            return URL(fileURLWithPath: String(cString: p), isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ff400ctl", isDirectory: true)
    }

    public static var storeURL: URL {
        stateDir.appendingPathComponent("state.json")
    }

    /// Defensive: arrays must be the right size even if the file was
    /// hand-edited or written by a stale build. Pads missing cells with
    /// safe defaults and truncates over-long arrays.
    public func normalized() -> MixerState {
        var s = self
        let n = Fireface400.channelCount
        func size<T>(_ a: inout [T], _ count: Int, _ fill: T) {
            if a.count < count { a += [T](repeating: fill, count: count - a.count) }
            else if a.count > count { a = Array(a.prefix(count)) }
        }
        size(&s.input, n * n, 0)
        size(&s.playback, n * n, 0)
        size(&s.output, n, Fireface400.unityGain)
        size(&s.inputMute, n, false)
        size(&s.inputPhase, n, false)
        size(&s.inputSolo, n, false)
        size(&s.outputMute, n, false)
        size(&s.outputStereo, n / 2, false)
        return s
    }

    public static func load() -> MixerState {
        let url = storeURL
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(MixerState.self, from: data)
        else { return MixerState() }
        return state.normalized()
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
        stateDir.appendingPathComponent("snapshots", isDirectory: true)
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
              let state = try? JSONDecoder().decode(MixerState.self, from: data)
        else { return nil }
        return state.normalized()
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
