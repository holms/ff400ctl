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

// MARK: - Device config block (phantom, pads, levels, clock)

extension FirefaceController {

    /// Current tracked config (write-only register — can't be read back).
    public var config: Fireface400.ConfigBlock { state.config }

    /// Write the whole 3-quadlet config block to the device.
    @discardableResult
    public func writeConfig(_ cfg: Fireface400.ConfigBlock) -> Bool {
        let ok = client.writeBlock(node: nodeID, address: Fireface400.configReg,
                                   payload: cfg.payload, verify: verifyWrites)
        onWrite?(Fireface400.configReg, ok)
        if ok { state.config = cfg }
        return ok
    }

    /// Toggle +48V phantom on mic input `ch` (0 or 1).
    @discardableResult
    public func setPhantom(ch: Int, on: Bool) -> Bool {
        guard (0...1).contains(ch) else { return false }
        var cfg = state.config
        if ch == 0 { cfg.phantom1 = on } else { cfg.phantom2 = on }
        return writeConfig(cfg)
    }

    /// Toggle pad (-20 dB) on input 3/4 (`ch` = 2 or 3).
    @discardableResult
    public func setPad(ch: Int, on: Bool) -> Bool {
        var cfg = state.config
        if ch == 2 { cfg.pad3 = on } else if ch == 3 { cfg.pad4 = on } else { return false }
        return writeConfig(cfg)
    }

    /// Toggle instrument mode on input 3/4 (`ch` = 2 or 3).
    @discardableResult
    public func setInstrument(ch: Int, on: Bool) -> Bool {
        var cfg = state.config
        if ch == 2 { cfg.instr3 = on } else if ch == 3 { cfg.instr4 = on } else { return false }
        return writeConfig(cfg)
    }
}
