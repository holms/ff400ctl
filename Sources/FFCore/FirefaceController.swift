import Foundation

/// High-level Fireface 400 control: writes mixer registers through the
/// ASFW user client and tracks the intended state in `MixerState`.
public final class FirefaceController {

    public let client: ASFWClient?
    /// FireWire node ID of the FF400 (bus 0xffc << 6 | physical node 0).
    public var nodeID: UInt16 = 0xffc0
    public private(set) var state: MixerState
    /// Set false for dry-run/testing: skips result polling.
    public var verifyWrites = true

    /// Called after every attempted register write with the target address.
    public var onWrite: ((UInt32, Bool) -> Void)?
    /// Output pair the send-level solo/mono logic applies to.
    public var busPair = (a: 0, b: 1)

    /// When set, register writes go to this sink instead of the user client
    /// (unit tests / dry runs).
    public var writeSink: ((UInt32, UInt32) -> Bool)?

    public init(client: ASFWClient? = nil, state: MixerState = .load()) throws {
        self.client = try client ?? ASFWClient()
        self.state = state
    }

    /// Hardware-free controller for tests.
    public init(testing state: MixerState,
                sink: @escaping (UInt32, UInt32) -> Bool) {
        self.client = nil
        self.state = state
        self.writeSink = sink
        self.verifyWrites = false
    }

    @discardableResult
    private func write(_ address: UInt32, _ value: UInt32) -> Bool {
        let ok: Bool
        if let sink = writeSink {
            ok = sink(address, value)
        } else {
            ok = client?.writeQuadlet(node: nodeID, address: address,
                                      value: value, verify: verifyWrites) ?? false
        }
        onWrite?(address, ok)
        return ok
    }

    // MARK: - Matrix faders

    @discardableResult
    public func setInputFader(src: Int, dest: Int, gain: UInt32) -> Bool {
        guard Fireface400.mixAddress(kind: .input, src: src, dest: dest) != nil else { return false }
        state.input[MixerState.index(src: src, dest: dest)] = gain
        return writeInputCell(src: src, dest: dest)
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
        guard Fireface400.outputFaderAddress(ch: ch) != nil else { return false }
        state.output[ch] = gain
        let effective: UInt32 = state.outputMute[ch] ? 0 : gain
        let ok = write(Fireface400.outputFaderAddress(ch: ch)!, effective)
        // FF400 keeps a hardware amp-gain in sync for output volume.
        let dB = state.outputMute[ch] ? -.infinity : Fireface400.db(fromGain: gain)
        _ = setAmpGain(index: Fireface400.AmpGain.output1.rawValue + ch, dB: dB)
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
            let v: UInt32 = state.outputMute[ch] ? 0 : state.output[ch]
            if let addr = Fireface400.outputFaderAddress(ch: ch),
               write(addr, v) { ok += 1 } else { fail += 1 }
        }
        for (key, devval) in state.ampGains {
            guard let idx = Int(key), idx < 22 else { continue }
            let regval = UInt32(idx << 16) | devval
            write(Fireface400.gainRegister, regval) ? (ok += 1) : (fail += 1)
        }
        return (ok, fail)
    }

    public func saveState() { state.save() }

    /// Replace the tracked state (e.g. after loading a snapshot).
    /// Call `applyAll()` afterwards to push it to the hardware.
    public func restoreState(_ newState: MixerState) { state = newState }
}

// MARK: - Device config block (phantom, pads, levels, clock)

extension FirefaceController {

    /// Current tracked config (write-only register — can't be read back).
    public var config: Fireface400.ConfigBlock { state.config }

    /// Write the whole 3-quadlet config block to the device.
    @discardableResult
    public func writeConfig(_ cfg: Fireface400.ConfigBlock) -> Bool {
        let ok: Bool
        if let sink = writeSink {
            // sink takes quadlets; fold the block into three calls
            let q = cfg.quadlets
            ok = sink(Fireface400.configReg, q.0) && sink(Fireface400.configReg + 4, q.1)
                && sink(Fireface400.configReg + 8, q.2)
        } else {
            ok = client?.writeBlock(node: nodeID, address: Fireface400.configReg,
                                    payload: cfg.payload, verify: verifyWrites) ?? false
        }
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

// MARK: - Channel flags: mute / solo / phase / mono
// TotalMix-style semantics implemented in software over the matrix cells,
// exactly like FFADO's setMixerGain(): MUTED writes 0 (fader value kept),
// INVERTED writes the negative of the fader (with the 0 -> 1 glitch guard).

extension FirefaceController {

    /// Signed value actually written to an input matrix cell, honoring
    /// mute, solo (on the bus pair only) and phase flags.
    public func effectiveInputCell(src: Int, dest: Int) -> Int32 {
        var v = Int32(bitPattern: state.input[MixerState.index(src: src, dest: dest)])
        if state.inputMute[src] { v = 0 }
        let anySolo = state.inputSolo.contains(true)
        if anySolo && !state.inputSolo[src] && (dest == busPair.a || dest == busPair.b) { v = 0 }
        if state.inputPhase[src] {
            // FFADO workaround: negating a 0 (-inf dB) cell causes a brief
            // level bump in the hardware; map to -1 (-90 dB) instead.
            if v == 0 { v = 1 }
            v = -v
        }
        return v
    }

    private func writeInputCell(src: Int, dest: Int) -> Bool {
        guard let addr = Fireface400.mixAddress(kind: .input, src: src, dest: dest) else { return false }
        return write(addr, UInt32(bitPattern: effectiveInputCell(src: src, dest: dest)))
    }

    /// Rewrite all cells of one input row (18 writes).
    @discardableResult
    private func rewriteInputRow(_ src: Int) -> Bool {
        var ok = true
        for d in 0..<Fireface400.channelCount where !writeInputCell(src: src, dest: d) { ok = false }
        return ok
    }

    /// Mute/unmute an input row across all outputs.
    @discardableResult
    public func setInputMute(src: Int, on: Bool) -> Bool {
        guard (0..<Fireface400.channelCount).contains(src) else { return false }
        state.inputMute[src] = on
        return rewriteInputRow(src)
    }

    /// Invert phase of an input row across all outputs.
    @discardableResult
    public func setInputPhase(src: Int, on: Bool) -> Bool {
        guard (0..<Fireface400.channelCount).contains(src) else { return false }
        state.inputPhase[src] = on
        return rewriteInputRow(src)
    }

    /// Exclusive solo on the monitor bus pair: soloing one input silences
    /// all other inputs' sends to the pair; unsoloing restores them.
    @discardableResult
    public func setInputSolo(src: Int, on: Bool) -> Bool {
        guard (0..<Fireface400.channelCount).contains(src) else { return false }
        for i in 0..<Fireface400.channelCount { state.inputSolo[i] = (i == src) && on }
        var ok = true
        for s in 0..<Fireface400.channelCount {
            if !writeInputCell(src: s, dest: busPair.a) { ok = false }
            if !writeInputCell(src: s, dest: busPair.b) { ok = false }
        }
        return ok
    }

    /// Switch the monitor bus pair. While a solo is active the old pair's
    /// silenced cells and the new pair's cells must be rewritten so the
    /// solo follows the bus; always call this on the hw queue — `busPair`
    /// is read by the solo/mono/effective-cell logic there.
    @discardableResult
    public func setBusPair(a: Int, b: Int) -> Bool {
        guard (0..<Fireface400.channelCount).contains(a),
              (0..<Fireface400.channelCount).contains(b) else { return false }
        let old = busPair
        busPair = (a, b)
        guard state.inputSolo.contains(true) else { return true }
        var ok = true
        for s in 0..<Fireface400.channelCount {
            // Rewrite with the NEW pair so effectiveInputCell evaluates
            // correctly for both the old dests (restore) and the new.
            if !writeInputCell(src: s, dest: old.a) { ok = false }
            if !writeInputCell(src: s, dest: old.b) { ok = false }
            if !writeInputCell(src: s, dest: a) { ok = false }
            if !writeInputCell(src: s, dest: b) { ok = false }
        }
        return ok
    }

    /// Mono-lock the monitor bus pair: mirror the left cell values into the
    /// right for every input, so both outputs carry the same mix.
    @discardableResult
    public func setMonoBus(on: Bool) -> Bool {
        state.monoBus = on
        guard on else { return true }      // off just stops enforcing
        var ok = true
        for s in 0..<Fireface400.channelCount {
            let l = state.input[MixerState.index(src: s, dest: busPair.a)]
            state.input[MixerState.index(src: s, dest: busPair.b)] = l
            if !writeInputCell(src: s, dest: busPair.b) { ok = false }
        }
        return ok
    }

    /// Stereo-link an output fader pair (0..<9 → channels 2i/2i+1).
    /// Software-only flag — the UI/CLI mirror fader writes across the pair.
    @discardableResult
    public func setOutputStereo(pair: Int, on: Bool) -> Bool {
        guard (0..<Fireface400.channelCount / 2).contains(pair) else { return false }
        state.outputStereo[pair] = on
        return true
    }

    /// Mute/unmute an output master fader (mixer fader + hw amp gain).
    @discardableResult
    public func setOutputMute(ch: Int, on: Bool) -> Bool {
        guard (0..<Fireface400.channelCount).contains(ch) else { return false }
        state.outputMute[ch] = on
        let ok1 = write(Fireface400.outputFaderAddress(ch: ch)!, on ? 0 : state.output[ch])
        let ok2 = setAmpGain(index: Fireface400.AmpGain.output1.rawValue + ch,
                             dB: on ? -.infinity : Fireface400.db(fromGain: state.output[ch]))
        return ok1 && ok2
    }
}
