import Foundation

/// High-level Fireface 400 control: writes mixer registers through the
/// ASFW user client and tracks the intended state in `MixerState`.
public final class FirefaceController {

    public let client: ASFWClient
    /// FireWire node ID of the FF400 (bus 0xffc << 6 | physical node 0).
    public var nodeID: UInt16 = 0xffc0
    public private(set) var state: MixerState
    /// Set false for dry-run/testing: skips result polling.
    public var verifyWrites = true

    /// Called after every attempted register write with the target address.
    public var onWrite: ((UInt32, Bool) -> Void)?

    public init(client: ASFWClient? = nil, state: MixerState = .load()) throws {
        self.client = try client ?? ASFWClient()
        self.state = state
    }

    @discardableResult
    private func write(_ address: UInt32, _ value: UInt32) -> Bool {
        let ok = client.writeQuadlet(node: nodeID, address: address,
                                     value: value, verify: verifyWrites)
        onWrite?(address, ok)
        return ok
    }

    // MARK: - Matrix faders

    @discardableResult
    public func setInputFader(src: Int, dest: Int, gain: UInt32) -> Bool {
        guard let addr = Fireface400.mixAddress(kind: .input, src: src, dest: dest) else { return false }
        let ok = write(addr, gain)
        if ok { state.input[MixerState.index(src: src, dest: dest)] = gain }
        return ok
    }

    @discardableResult
    public func setPlaybackFader(src: Int, dest: Int, gain: UInt32) -> Bool {
        guard let addr = Fireface400.mixAddress(kind: .playback, src: src, dest: dest) else { return false }
        let ok = write(addr, gain)
        if ok { state.playback[MixerState.index(src: src, dest: dest)] = gain }
        return ok
    }

    @discardableResult
    public func setOutputFader(ch: Int, gain: UInt32) -> Bool {
        guard let addr = Fireface400.outputFaderAddress(ch: ch) else { return false }
        let ok = write(addr, gain)
        if ok {
            state.output[ch] = gain
            // FF400 keeps a hardware amp-gain in sync for output volume.
            let dB = Fireface400.db(fromGain: gain)
            _ = setAmpGain(index: Fireface400.AmpGain.output1.rawValue + ch, dB: dB)
        }
        return ok
    }

    // MARK: - Hardware amp gains

    @discardableResult
    public func setAmpGain(index: Int, dB: Double) -> Bool {
        guard let regval = Fireface400.ampGainValue(index: index, dB: dB) else { return false }
        let ok = write(Fireface400.gainRegister, regval)
        if ok { state.ampGains[String(index)] = regval & 0xffff }
        return ok
    }

    // MARK: - Bulk ops

    /// Re-apply the entire tracked state (e.g. after power cycle, which
    /// restores the mixer from flash and loses RAM writes).
    public func applyAll() -> (written: Int, failed: Int) {
        var ok = 0, fail = 0
        for src in 0..<Fireface400.channelCount {
            for dest in 0..<Fireface400.channelCount {
                let i = MixerState.index(src: src, dest: dest)
                setInputFader(src: src, dest: dest, gain: state.input[i]) ? (ok += 1) : (fail += 1)
                setPlaybackFader(src: src, dest: dest, gain: state.playback[i]) ? (ok += 1) : (fail += 1)
            }
        }
        for ch in 0..<Fireface400.channelCount {
            // reuse raw write to avoid double amp-gain writes inside loop
            if let addr = Fireface400.outputFaderAddress(ch: ch),
               write(addr, state.output[ch]) { ok += 1 } else { fail += 1 }
        }
        for (key, devval) in state.ampGains {
            guard let idx = Int(key), idx < 22 else { continue }
            let regval = UInt32(idx << 16) | devval
            write(Fireface400.gainRegister, regval) ? (ok += 1) : (fail += 1)
        }
        return (ok, fail)
    }

    public func saveState() { state.save() }
}
