import Foundation
@testable import FFCore
@testable import FFModel

// Minimal test harness (no XCTest dependency — runs under Command Line Tools).
var failures = 0
var checks = 0

// Keep all file I/O in a throwaway dir — the snapshot/save tests must never
// touch the real ~/Library/Application Support/ff400ctl.
let testStateDir = NSTemporaryDirectory()
    + "ff400ctl-fftests-\(ProcessInfo.processInfo.processIdentifier)"
setenv("FFCTL_STATE_DIR", testStateDir, 1)
try? FileManager.default.createDirectory(atPath: testStateDir, withIntermediateDirectories: true)

func check(_ cond: @autoclosure () -> Bool, _ name: String) {
    checks += 1
    if !cond() {
        failures += 1
        print("FAIL: \(name)")
    }
}

func eq<T: Equatable>(_ a: @autoclosure () -> T, _ b: @autoclosure () -> T, _ name: String) {
    check(a() == b(), "\(name) — got \(a()), expected \(b())")
}

func close(_ a: Double, _ b: Double, _ tol: Double, _ name: String) {
    check(abs(a - b) <= tol, "\(name) — got \(a), expected \(b) ±\(tol)")
}

// MARK: - Mixer addressing (values cross-checked against FFADO set_hardware_mixergain)

eq(Fireface400.mixAddress(kind: .input, src: 0, dest: 0), 0x8008_0000, "in0->out0")
eq(Fireface400.mixAddress(kind: .input, src: 0, dest: 1), 0x8008_0090, "in0->out1")
eq(Fireface400.mixAddress(kind: .input, src: 1, dest: 0), 0x8008_0004, "in1->out0")
eq(Fireface400.mixAddress(kind: .input, src: 5, dest: 2), 0x8008_0134, "in5->out2")
eq(Fireface400.mixAddress(kind: .input, src: 17, dest: 17), 0x8008_09d4, "in17->out17")

eq(Fireface400.mixAddress(kind: .playback, src: 0, dest: 0), 0x8008_0048, "pb0->out0")
eq(Fireface400.mixAddress(kind: .playback, src: 0, dest: 1), 0x8008_00d8, "pb0->out1")
eq(Fireface400.mixAddress(kind: .playback, src: 17, dest: 17), 0x8008_0a1c, "pb17->out17")

eq(Fireface400.outputFaderAddress(ch: 0), 0x8008_0f80, "outfader 0")
eq(Fireface400.outputFaderAddress(ch: 7), 0x8008_0f9c, "outfader 7")
eq(Fireface400.outputFaderAddress(ch: 17), 0x8008_0fc4, "outfader 17")

check(Fireface400.mixAddress(kind: .input, src: -1, dest: 0) == nil, "src<0 rejected")
check(Fireface400.mixAddress(kind: .input, src: 0, dest: 18) == nil, "dest>17 rejected")
check(Fireface400.mixAddress(kind: .playback, src: 18, dest: 0) == nil, "src>17 rejected")
check(Fireface400.outputFaderAddress(ch: 18) == nil, "outfader>17 rejected")

// every matrix cell unique; playback cells disjoint from input cells and faders
var seen = Set<UInt32>()
var unique = true
for s in 0..<18 { for d in 0..<18 {
    if !seen.insert(Fireface400.mixAddress(kind: .input, src: s, dest: d)!).inserted { unique = false }
}}
check(unique, "all 324 input cells unique")
var disjoint = true
for s in 0..<18 { for d in 0..<18 {
    if seen.contains(Fireface400.mixAddress(kind: .playback, src: s, dest: d)!) { disjoint = false }
}}
for ch in 0..<18 where seen.contains(Fireface400.outputFaderAddress(ch: ch)!) { disjoint = false }
check(disjoint, "playback cells and output faders disjoint from input cells")

// MARK: - Gain conversion

eq(Fireface400.gain(fromDB: 0), 0x8000, "0dB = 0x8000")
close(Double(Fireface400.gain(fromDB: 6.02)), 0x10000, 5, "+6dB ~ 0x10000")
close(Double(Fireface400.gain(fromDB: -6.0206)), 0x4000, 20, "-6dB ~ 0x4000")
eq(Fireface400.gain(fromDB: -90), 0, "-90dB = 0")
eq(Fireface400.gain(fromDB: -200), 0, "very low = 0")

for db in stride(from: -60.0, through: 6.0, by: 3.0) {
    // quantization: below -50 dB one LSB is ~0.26 dB
    let tol = db <= -50 ? 0.3 : 0.05
    close(Fireface400.db(fromGain: Fireface400.gain(fromDB: db)), db, tol, "round-trip \(db)dB")
}
eq(Fireface400.db(fromGain: 0), -.infinity, "gain 0 = -inf dB")

eq([UInt8](Fireface400.payload(for: 0x8000)), [0x00, 0x80, 0x00, 0x00], "LE payload 0x8000")
eq([UInt8](Fireface400.payload(for: 0x00040006)), [0x06, 0x00, 0x04, 0x00], "LE payload reg")

// MARK: - Amp gains (regval = index << 16 | devval)

eq(Fireface400.ampGainValue(index: 0, dB: 20), 0x0000_0014, "mic1 @20dB")
eq(Fireface400.ampGainValue(index: 1, dB: 5), 0x0001_0000, "mic2 <10dB -> 0")
eq(Fireface400.ampGainValue(index: 0, dB: 90), 0x0000_0041, "mic1 clamp 65")
eq(Fireface400.ampGainValue(index: 2, dB: 10), 0x0002_0014, "in3 dB*2")
eq(Fireface400.ampGainValue(index: 3, dB: -10), 0x0003_0000, "in4 negative -> 0")
eq(Fireface400.ampGainValue(index: 4, dB: 0), 0x0004_0006, "out1 @0dB = 6")
eq(Fireface400.ampGainValue(index: 4, dB: -10), 0x0004_0010, "out1 @-10dB = 16")
eq(Fireface400.ampGainValue(index: 4, dB: -47), 0x0004_0035, "out1 @-47dB = 53 (not mute)")
eq(Fireface400.ampGainValue(index: 4, dB: -48), 0x0004_003f, "out1 @-48dB = mute")
eq(Fireface400.ampGainValue(index: 4, dB: -60), 0x0004_003f, "out1 deep att = mute")
eq(Fireface400.ampGainValue(index: 10, dB: -6), 0x000a_000c, "phonesL @-6dB = 12")
eq(Fireface400.ampGainValue(index: 9, dB: -.infinity), 0x0009_003f, "-inf = mute")
check(Fireface400.ampGainValue(index: 22, dB: 0) == nil, "index>21 rejected")
check(Fireface400.ampGainValue(index: -1, dB: 0) == nil, "index<0 rejected")

// MARK: - Mixer state

let s = MixerState()
eq(s.input.count, 324, "input array size")
eq(s.playback.count, 324, "playback array size")
eq(s.output.count, 18, "output array size")
var defaultOK = true
for i in 0..<18 {
    if s.playback[i * 18 + i] != 0x8000 { defaultOK = false }
    if s.input[i * 18 + i] != 0 { defaultOK = false }
    if s.output[i] != 0x8000 { defaultOK = false }
}
check(defaultOK, "default state: pb 1:1 unity, inputs muted, outputs unity")
eq(s.playback[1], 0, "off-diagonal playback muted")

check(MixerState.storeURL.path.hasPrefix(testStateDir),
      "FFCTL_STATE_DIR overrides storeURL")
check(MixerState.snapshotsDir.path.hasPrefix(testStateDir),
      "FFCTL_STATE_DIR overrides snapshotsDir")

eq(MixerState.index(src: 0, dest: 0), 0, "idx(0,0)")
eq(MixerState.index(src: 0, dest: 1), 1, "idx(0,1)")
eq(MixerState.index(src: 1, dest: 0), 18, "idx(1,0)")
eq(MixerState.index(src: 17, dest: 17), 323, "idx(17,17)")

do {
    var st = MixerState()
    st.input[MixerState.index(src: 0, dest: 1)] = 0x4000
    st.ampGains["4"] = 6
    let data = try JSONEncoder().encode(st)
    let back = try JSONDecoder().decode(MixerState.self, from: data)
    eq(back, st, "Codable round trip")
} catch {
    check(false, "Codable round trip threw \(error)")
}

// MARK: -

// MARK: - Config block encoding (FFADO set_hardware_params / ASFW EncodeConfig)

do {
    var c = Fireface400.ConfigBlock()
    var q = c.quadlets
    // defaults: +4dBu in/out/phones, clock master, wclk sync, spdifPro
    eq(q.0, 0x0000_0810, "config q0 default")
    eq(q.1, 0x0000_001a, "config q1 default")
    eq(q.2, 0x8400_003f, "config q2 default")

    // ffado test vector: 0x00020811 = phones higain + out +4dBu + in +4dBu + phantom mic1
    c.phonesLevel = .lowGain   // "high gain" phones
    c.phantom1 = true
    eq(c.quadlets.0, 0x0002_0811, "config q0 phantom1 + phones higain (ffado vector)")
    c.phantom1 = false
    eq(c.quadlets.0, 0x0002_0810, "config q0 phantom off (ffado vector)")

    c = Fireface400.ConfigBlock()
    c.phantom2 = true
    check(c.quadlets.0 & 0x80 != 0, "phantom2 sets q0 bit7")
    c = Fireface400.ConfigBlock()
    c.pad3 = true; c.pad4 = true
    check(c.quadlets.0 & 0x100 != 0, "pad3 sets q0 bit8")
    check(c.quadlets.0 & 0x02 != 0, "pad4 sets q0 bit1")
    c = Fireface400.ConfigBlock()
    c.instr3 = true; c.instr4 = true
    check(c.quadlets.0 & 0x200 != 0, "instr3 sets q0 bit9")
    check(c.quadlets.0 & 0x04 != 0, "instr4 sets q0 bit2")

    // clock master bit + mandatory bits always present
    check(c.quadlets.2 & 0x8000_001f == 0x8000_001f,
          "q2 always has dropAndStop+rates+master")
    c.clockMaster = false
    check(c.quadlets.2 & 0x01 == 0, "autosync clears bit0")

    // payload is 12 LE bytes
    let p = c.payload
    eq(p.count, 12, "config payload length")
}

// Re-print summary including the new block (the earlier exit() was moved below).
// MARK: - Mute / solo / phase / mono (controller + sink)

do {
    var writes: [(UInt32, UInt32)] = []
    let sink: (UInt32, UInt32) -> Bool = { a, v in writes.append((a, v)); return true }
    let ctl = FirefaceController(testing: MixerState(), sink: sink)

    // phase: cell written as negative gain
    _ = ctl.setInputFader(src: 2, dest: 0, gain: 0x8000)
    _ = ctl.setInputPhase(src: 2, on: true)
    // last write to in2->out0 should be -0x8000
    let cellAddr = Fireface400.mixAddress(kind: .input, src: 2, dest: 0)!
    let last = writes.last(where: { $0.0 == cellAddr })!.1
    eq(last, UInt32(bitPattern: Int32(-0x8000)), "phase writes negative gain")

    // phase of a zero cell maps to -1 (FFADO glitch guard)
    _ = ctl.setInputPhase(src: 5, on: true)
    let zeroCell = Fireface400.mixAddress(kind: .input, src: 5, dest: 0)!
    eq(writes.last(where: { $0.0 == zeroCell })!.1,
       UInt32(bitPattern: Int32(-1)), "phase of 0 cell -> -1")

    // mute: fader write stores value but hardware gets 0
    let ctl2 = FirefaceController(testing: MixerState(), sink: sink)
    _ = ctl2.setInputMute(src: 0, on: true)
    _ = ctl2.setInputFader(src: 0, dest: 0, gain: 0x8000)
    eq(ctl2.state.input[0], 0x8000, "muted fader value still tracked")
    let c00 = Fireface400.mixAddress(kind: .input, src: 0, dest: 0)!
    eq(writes.last(where: { $0.0 == c00 })!.1, 0, "muted cell writes 0")
    _ = ctl2.setInputMute(src: 0, on: false)
    eq(writes.last(where: { $0.0 == c00 })!.1, 0x8000, "unmute restores fader")

    // solo on bus pair (0,1): others get 0 on bus cells only
    let ctl3 = FirefaceController(testing: MixerState(), sink: sink)
    _ = ctl3.setInputFader(src: 3, dest: 0, gain: 0x8000)
    _ = ctl3.setInputFader(src: 3, dest: 1, gain: 0x8000)
    _ = ctl3.setInputFader(src: 3, dest: 7, gain: 0x8000)  // phones — NOT on bus
    _ = ctl3.setInputSolo(src: 2, on: true)
    let c30 = Fireface400.mixAddress(kind: .input, src: 3, dest: 0)!
    let c37 = Fireface400.mixAddress(kind: .input, src: 3, dest: 7)!
    eq(writes.last(where: { $0.0 == c30 })!.1, 0, "non-soloed input -> 0 on bus cell")
    eq(writes.last(where: { $0.0 == c37 })!.1, 0x8000, "non-soloed input untouched off-bus")
    _ = ctl3.setInputSolo(src: 2, on: false)
    eq(writes.last(where: { $0.0 == c30 })!.1, 0x8000, "unsolo restores bus cell")

    // exclusive solo
    _ = ctl3.setInputSolo(src: 1, on: true)
    check(ctl3.state.inputSolo[1] && !ctl3.state.inputSolo[2], "solo is exclusive")

    // mono: L+R average written to both pair cells, stored cells untouched
    let ctl4 = FirefaceController(testing: MixerState(), sink: sink)
    _ = ctl4.setInputFader(src: 4, dest: 0, gain: 0x8000)
    _ = ctl4.setInputFader(src: 4, dest: 1, gain: 0)
    _ = ctl4.setMonoBus(on: true)
    let c40 = Fireface400.mixAddress(kind: .input, src: 4, dest: 0)!
    let c41 = Fireface400.mixAddress(kind: .input, src: 4, dest: 1)!
    eq(writes.last(where: { $0.0 == c40 })!.1, 0x4000, "mono averages L cell")
    eq(writes.last(where: { $0.0 == c41 })!.1, 0x4000, "mono averages R cell")
    eq(ctl4.state.input[MixerState.index(src: 4, dest: 0)], 0x8000,
       "mono leaves stored L untouched")
    eq(ctl4.state.input[MixerState.index(src: 4, dest: 1)], 0,
       "mono leaves stored R untouched")
    _ = ctl4.setMonoBus(on: false)
    eq(writes.last(where: { $0.0 == c40 })!.1, 0x8000, "mono off restores L")
    eq(writes.last(where: { $0.0 == c41 })!.1, 0, "mono off restores R")

    // output mute: fader + amp gain muted, fader value kept
    let ctl5 = FirefaceController(testing: MixerState(), sink: sink)
    _ = ctl5.setOutputFader(ch: 0, gain: 0x8000)
    _ = ctl5.setOutputMute(ch: 0, on: true)
    eq(writes.last(where: { $0.0 == 0x8008_0f80 })!.1, 0, "outmute writes fader 0")
    check(ctl5.state.output[0] == 0x8000, "outmute keeps fader value")
    _ = ctl5.setOutputMute(ch: 0, on: false)
    eq(writes.last(where: { $0.0 == 0x8008_0f80 })!.1, 0x8000, "unmute restores out fader")
}
// MARK: - Gain argument parsing (CLI automation)

do {
    eq(Fireface400.parseGainArgument("0x8000"), 0x8000, "parse hex")
    eq(Fireface400.parseGainArgument("32768"), 0x8000, "parse decimal")
    eq(Fireface400.parseGainArgument("-6dB"), Fireface400.gain(fromDB: -6), "parse absolute dB")
    eq(Fireface400.parseGainArgument("+3dB", current: 0x8000),
       Fireface400.gain(fromDB: 3), "relative +3dB on unity")
    eq(Fireface400.parseGainArgument("-3dB", current: 0x8000),
       Fireface400.gain(fromDB: -3), "relative -3dB on unity")
    let half = Fireface400.gain(fromDB: -6)
    eq(Fireface400.parseGainArgument("+6dB", current: half),
       Fireface400.gain(fromDB: 0), "relative +6dB on -6dB cell")
    eq(Fireface400.parseGainArgument("+3dB", current: 0),
       Fireface400.gain(fromDB: -87), "relative step on muted cell starts at -90dB")
    eq(Fireface400.parseGainArgument("+3dB"), Fireface400.gain(fromDB: 3),
       "+3dB without current falls back to absolute")
    check(Fireface400.parseGainArgument("bogus") == nil, "garbage rejected")
    check(Fireface400.parseGainArgument("+3dB", current: 0x8000)! > 0x8000,
          "relative step increases value")
}

// MARK: - Snapshots

do {
    var s = MixerState()
    s.input[MixerState.index(src: 3, dest: 7)] = 0x1234
    s.outputMute[2] = true
    s.config.phantom1 = true
    check(s.saveSnapshot(name: "fftest-snap"), "snapshot saves")
    check(MixerState.snapshotNames().contains("fftest-snap"), "snapshot listed")
    let loaded = MixerState.loadSnapshot(name: "fftest-snap")
    check(loaded != nil, "snapshot loads")
    eq(loaded?.input[MixerState.index(src: 3, dest: 7)], 0x1234, "cell survives snapshot")
    check(loaded?.outputMute[2] == true, "flag survives snapshot")
    check(loaded?.config.phantom1 == true, "config survives snapshot")
    check(MixerState.loadSnapshot(name: "no-such-snap-xyz") == nil, "missing snapshot -> nil")
    check(MixerState.deleteSnapshot(name: "fftest-snap"), "snapshot deletes")
    check(!MixerState.snapshotNames().contains("fftest-snap"), "snapshot gone after delete")
    // names sanitize to a filename-safe form
    check(MixerState.snapshotURL(name: "../etc/passwd").lastPathComponent == "etcpasswd.json",
          "snapshot name sanitized")
}

// MARK: - Stereo output pairs

do {
    var s = MixerState()
    check(s.outputStereo.count == 9, "9 stereo pair flags by default")
    check(s.outputStereo.allSatisfy { !$0 }, "pairs unlinked by default")

    let ctl = FirefaceController(testing: s, sink: { _, _ in true })
    check(ctl.setOutputStereo(pair: 0, on: true), "link pair 0")
    check(ctl.state.outputStereo[0] == true, "pair 0 linked in state")
    check(!ctl.setOutputStereo(pair: 9, on: true), "pair 9 out of range")
    check(!ctl.setOutputStereo(pair: -1, on: true), "negative pair rejected")

    // persists through Codable
    let data = try! JSONEncoder().encode(ctl.state)
    let back = try! JSONDecoder().decode(MixerState.self, from: data)
    check(back.outputStereo[0] == true, "stereo link survives round-trip")
    s = back
    s.outputStereo = []
}

// MARK: - WriteCoalescer (same-key coalescing, FIFO, position-preserving replace)

do {
    // (a) 50 same-key submits while blocked -> blocker + one merged run
    let wq = WriteCoalescer()
    let started = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)
    var execs = 0
    var recorded: [Int] = []
    wq.submit("block") { started.signal(); gate.wait(); execs += 1 }
    started.wait()
    for i in 0..<50 { wq.submit("k") { recorded.append(i) } }
    gate.signal()
    wq.waitUntilIdle()
    eq(execs, 1, "blocker ran once")
    eq(recorded, [49], "50 same-key submits coalesced to the latest")

    // (b) distinct keys all run, FIFO
    let wq2 = WriteCoalescer()
    let st2 = DispatchSemaphore(value: 0), g2 = DispatchSemaphore(value: 0)
    var order: [String] = []
    wq2.submit("block") { st2.signal(); g2.wait() }
    st2.wait()
    for k in ["a", "b", "c"] { wq2.submit(k) { order.append(k) } }
    g2.signal()
    wq2.waitUntilIdle()
    eq(order, ["a", "b", "c"], "distinct keys run FIFO")

    // (c) replacing a pending key keeps its queue position
    let wq3 = WriteCoalescer()
    let st3 = DispatchSemaphore(value: 0), g3 = DispatchSemaphore(value: 0)
    var order3: [String] = []
    wq3.submit("block") { st3.signal(); g3.wait() }
    st3.wait()
    wq3.submit("a") { order3.append("a1") }
    wq3.submit("b") { order3.append("b") }
    wq3.submit("a") { order3.append("a2") }
    g3.signal()
    wq3.waitUntilIdle()
    eq(order3, ["a2", "b"], "same-key replace keeps position")

    // waitUntilIdle returns immediately on an empty queue
    let wq4 = WriteCoalescer()
    wq4.waitUntilIdle()
    check(true, "waitUntilIdle on empty queue returns")
}

// MARK: - ampGainDB inverse

do {
    eq(Fireface400.ampGainDB(index: 0, devval: 20), 20, "mic 20dB inverse")
    eq(Fireface400.ampGainDB(index: 2, devval: 21), 10.5, "in3 0.5dB units inverse")
    eq(Fireface400.ampGainDB(index: 4, devval: 16), -10, "out -10dB inverse")
    eq(Fireface400.ampGainDB(index: 4, devval: 0x3f), -.infinity, "out mute inverse")
    check(Fireface400.ampGainDB(index: 22, devval: 0) == nil, "ampGainDB bad index -> nil")
    // round-trips
    if let rv = Fireface400.ampGainValue(index: 0, dB: 20) {
        eq(Fireface400.ampGainDB(index: 0, devval: rv & 0xffff), 20, "mic round-trip")
    }
    if let rv = Fireface400.ampGainValue(index: 2, dB: 10.5) {
        eq(Fireface400.ampGainDB(index: 2, devval: rv & 0xffff), 10.5, "in3 round-trip")
    }
    if let rv = Fireface400.ampGainValue(index: 4, dB: -10) {
        eq(Fireface400.ampGainDB(index: 4, devval: rv & 0xffff), -10, "out round-trip")
    }
}

// MARK: - setBusPair (solo follows the bus)

do {
    var w5: [(UInt32, UInt32)] = []
    let c5 = FirefaceController(testing: MixerState(),
                                sink: { a, v in w5.append((a, v)); return true })
    _ = c5.setInputFader(src: 5, dest: 0, gain: 0x8000)
    _ = c5.setInputFader(src: 5, dest: 2, gain: 0x8000)
    _ = c5.setInputSolo(src: 2, on: true)     // solo on pair (0,1) silences src5 there
    check(c5.setBusPair(a: 2, b: 3), "setBusPair accepted")
    eq(c5.busPair.a, 2, "busPair updated")
    let c50 = Fireface400.mixAddress(kind: .input, src: 5, dest: 0)!
    let c52 = Fireface400.mixAddress(kind: .input, src: 5, dest: 2)!
    eq(w5.last(where: { $0.0 == c50 })!.1, 0x8000,
       "old bus cell restored on bus change")
    eq(w5.last(where: { $0.0 == c52 })!.1, 0,
       "new bus cell silenced by active solo")
    check(!c5.setBusPair(a: 18, b: 0), "setBusPair a=18 rejected")
    check(!c5.setBusPair(a: 0, b: -1), "setBusPair b=-1 rejected")
}

// MARK: - MixerState.normalized

do {
    var s = MixerState()
    s.inputMute = [true]
    s.outputStereo = []
    s.input = [0x8000]
    let data = try JSONEncoder().encode(s)
    let back = try JSONDecoder().decode(MixerState.self, from: data).normalized()
    eq(back.inputMute.count, 18, "inputMute padded to 18")
    check(back.inputMute[0], "inputMute[0] kept")
    eq(back.outputStereo.count, 9, "outputStereo padded to 9")
    eq(back.input.count, 324, "input padded to 324")
    eq(back.input[0], 0x8000, "input[0] kept")
    var over = MixerState()
    over.outputMute = [Bool](repeating: true, count: 30)
    eq(over.normalized().outputMute.count, 18, "outputMute truncated to 18")
}

// MARK: - Mono sum semantics (inputs + playback, non-destructive)

do {
    var w: [(UInt32, UInt32)] = []
    let sink: (UInt32, UInt32) -> Bool = { a, v in w.append((a, v)); return true }
    func last(_ addr: UInt32) -> UInt32 { w.last(where: { $0.0 == addr })!.1 }

    // playback sources average too
    let c = FirefaceController(testing: MixerState(), sink: sink)
    _ = c.setPlaybackFader(src: 7, dest: 0, gain: 0x8000)
    _ = c.setPlaybackFader(src: 7, dest: 1, gain: 0x2000)
    _ = c.setMonoBus(on: true)
    let p70 = Fireface400.mixAddress(kind: .playback, src: 7, dest: 0)!
    let p71 = Fireface400.mixAddress(kind: .playback, src: 7, dest: 1)!
    eq(last(p70), 0x5000, "mono averages playback L")
    eq(last(p71), 0x5000, "mono averages playback R")
    eq(c.state.playback[MixerState.index(src: 7, dest: 0)], 0x8000,
       "stored playback L untouched")
    _ = c.setMonoBus(on: false)
    eq(last(p70), 0x8000, "mono off restores playback L")
    eq(last(p71), 0x2000, "mono off restores playback R")

    // mono + phase: average computed, then negated
    let c2 = FirefaceController(testing: MixerState(), sink: sink)
    _ = c2.setInputFader(src: 4, dest: 0, gain: 0x8000)
    _ = c2.setInputFader(src: 4, dest: 1, gain: 0)
    _ = c2.setInputPhase(src: 4, on: true)
    _ = c2.setMonoBus(on: true)
    let i40 = Fireface400.mixAddress(kind: .input, src: 4, dest: 0)!
    let i41 = Fireface400.mixAddress(kind: .input, src: 4, dest: 1)!
    eq(last(i40), UInt32(bitPattern: Int32(-0x4000)), "mono+phase negates avg L")
    eq(last(i41), UInt32(bitPattern: Int32(-0x4000)), "mono+phase negates avg R")

    // editing one pair cell while mono is on rewrites BOTH pair cells
    let c3 = FirefaceController(testing: MixerState(), sink: sink)
    _ = c3.setInputFader(src: 4, dest: 0, gain: 0x8000)
    _ = c3.setInputFader(src: 4, dest: 1, gain: 0)
    _ = c3.setMonoBus(on: true)
    _ = c3.setInputFader(src: 4, dest: 1, gain: 0x4000)
    eq(last(i40), 0x6000, "fader edit under mono rewrites L with new avg")
    eq(last(i41), 0x6000, "fader edit under mono rewrites R with new avg")

    // same for playback faders
    let c4 = FirefaceController(testing: MixerState(), sink: sink)
    _ = c4.setPlaybackFader(src: 2, dest: 0, gain: 0x8000)
    _ = c4.setPlaybackFader(src: 2, dest: 1, gain: 0)
    _ = c4.setMonoBus(on: true)
    _ = c4.setPlaybackFader(src: 2, dest: 1, gain: 0x8000)
    let p20 = Fireface400.mixAddress(kind: .playback, src: 2, dest: 0)!
    eq(last(p20), 0x8000, "pb fader edit under mono rewrites sibling")

    // bus change with mono on: old pair restored, new pair averaged
    let c5 = FirefaceController(testing: MixerState(), sink: sink)
    _ = c5.setInputFader(src: 4, dest: 0, gain: 0x8000)
    _ = c5.setInputFader(src: 4, dest: 1, gain: 0)
    _ = c5.setInputFader(src: 4, dest: 2, gain: 0x8000)
    _ = c5.setInputFader(src: 4, dest: 3, gain: 0)
    _ = c5.setMonoBus(on: true)
    _ = c5.setBusPair(a: 2, b: 3)
    let i42 = Fireface400.mixAddress(kind: .input, src: 4, dest: 2)!
    eq(last(i40), 0x8000, "mono bus change restores old L")
    eq(last(i41), 0, "mono bus change restores old R")
    eq(last(i42), 0x4000, "mono bus change averages new pair")

    // applyAll writes effective playback values (mono still on, pair 2/3)
    _ = c5.setPlaybackFader(src: 4, dest: 2, gain: 0x8000)
    _ = c5.setPlaybackFader(src: 4, dest: 3, gain: 0)
    _ = c5.applyAll()
    let p40 = Fireface400.mixAddress(kind: .playback, src: 4, dest: 0)!
    eq(last(p40), c5.state.playback[MixerState.index(src: 4, dest: 0)],
       "applyAll writes stored playback off-pair")
    eq(last(Fireface400.mixAddress(kind: .playback, src: 4, dest: 2)!), 0x4000,
       "applyAll writes averaged playback on-pair")
}

// MARK: - applyAll re-derives output amp gains (stale 2x values dropped)

do {
    var st = MixerState()
    st.output[0] = Fireface400.gain(fromDB: -10)
    st.ampGains["4"] = 26          // stale pre-fix (2x) encoding
    st.ampGains["0"] = 20          // mic1 still replayed
    var w: [(UInt32, UInt32)] = []
    let c = FirefaceController(testing: st,
                               sink: { a, v in w.append((a, v)); return true })
    _ = c.applyAll()
    let gains = w.filter { $0.0 == Fireface400.gainRegister }
    let g4 = gains.last(where: { ($0.1 >> 16) == 4 })!
    eq(g4.1 & 0xffff, 16, "applyAll re-derives out1 amp gain = 16")
    eq(c.state.ampGains["4"], 16, "state.ampGains refreshed")
    check(!gains.contains(where: { $0.1 == (4 << 16) | 26 }),
          "stale raw amp gain never written")
    let g0 = gains.last(where: { ($0.1 >> 16) == 0 })!
    eq(g0.1 & 0xffff, 20, "mic1 amp gain still replayed")
}

// MARK: - MatrixHitTest (canvas grid tap mapping)

do {
    // cellW 26, cellH 18, gap 2 -> pitch 28×20
    func hit(_ x: Double, _ y: Double) -> (row: Int, col: Int)? {
        MatrixHitTest.cell(at: x, y: y, cellW: 26, cellH: 18, gap: 2, count: 18)
    }
    eq(hit(13, 9)?.row, 0, "center of cell (0,0) row")
    eq(hit(13, 9)?.col, 0, "center of cell (0,0) col")
    eq(hit(17 * 28 + 13, 17 * 20 + 9)?.row, 17, "center of cell (17,17) row")
    eq(hit(17 * 28 + 13, 17 * 20 + 9)?.col, 17, "center of cell (17,17) col")
    check(hit(27, 9) == nil, "tap in column gap -> nil")
    check(hit(13, 19) == nil, "tap in row gap -> nil")
    check(hit(-1, 9) == nil, "negative x -> nil")
    check(hit(13, -1) == nil, "negative y -> nil")
    check(hit(18 * 28, 9) == nil, "beyond grid -> nil")
    check(hit(18 * 28, 18 * 20) == nil, "past last cell -> nil")
    eq(hit(17 * 28 + 25, 17 * 20 + 17)?.row, 17, "just inside last row")
    eq(hit(17 * 28 + 25, 17 * 20 + 17)?.col, 17, "just inside last col")
}
// MARK: - MAIN pair controls + slider mapping

do {
    var w: [(UInt32, UInt32)] = []
    let c = FirefaceController(testing: MixerState(),
                               sink: { a, v in w.append((a, v)); return true })
    func last(_ addr: UInt32) -> UInt32? { w.last(where: { $0.0 == addr })?.1 }

    check(c.setPairFader(pair: 0, gain: 0x4000), "setPairFader ok")
    eq(last(0x8008_0f80)!, 0x4000, "pair fader L written")
    eq(last(0x8008_0f84)!, 0x4000, "pair fader R written")
    var gains = w.filter { $0.0 == Fireface400.gainRegister }
    check(gains.contains { ($0.1 >> 16) == 4 }, "pair amp gain index 4 written")
    check(gains.contains { ($0.1 >> 16) == 5 }, "pair amp gain index 5 written")
    check(!c.setPairFader(pair: 9, gain: 0x4000), "setPairFader pair 9 rejected")

    check(c.setPairMute(pair: 3, on: true), "setPairMute ok")
    eq(last(Fireface400.outputFaderAddress(ch: 6)!)!, 0, "pair mute writes 0 L")
    eq(last(Fireface400.outputFaderAddress(ch: 7)!)!, 0, "pair mute writes 0 R")
    gains = w.filter { $0.0 == Fireface400.gainRegister }
    eq(gains.last(where: { ($0.1 >> 16) == 10 })!.1 & 0xffff, 0x3f,
       "pair mute amp index 10 muted")
    eq(gains.last(where: { ($0.1 >> 16) == 11 })!.1 & 0xffff, 0x3f,
       "pair mute amp index 11 muted")
    eq(c.state.output[6], Fireface400.unityGain, "pair mute keeps fader value")

    eq(Fireface400.mainSliderGain(0), 0, "slider pos 0 = mute")
    eq(Fireface400.mainSliderGain(-0.5), 0, "slider pos <0 = mute")
    close(Double(Fireface400.mainSliderGain(1)),
          Double(Fireface400.gain(fromDB: 6)), 1, "slider pos 1 = +6dB")
    close(Fireface400.mainSliderPos(Fireface400.unityGain), 60.0 / 66.0, 0.001,
          "unity gain pos ≈ 60/66")
    for p in [0.25, 0.5, 0.75] {
        close(Fireface400.mainSliderPos(Fireface400.mainSliderGain(p)), p, 0.01,
              "slider round-trip \(p)")
    }
    eq(Fireface400.mainSliderPos(0), 0, "gain 0 -> pos 0")
    eq(Fireface400.mainSliderPos(Fireface400.gain(fromDB: 10)), 1, ">=+6dB -> pos 1")
}

// MARK: - MixerModel (UI actions -> device writes, fake hardware)

do {
    var w: [(UInt32, UInt32)] = []
    let sink: (UInt32, UInt32) -> Bool = { a, v in w.append((a, v)); return true }
    func last(_ addr: UInt32) -> UInt32? { w.last(where: { $0.0 == addr })?.1 }
    func makeModel(_ state: MixerState = MixerState()) -> MixerModel {
        MixerModel(testing: FirefaceController(testing: state, sink: sink))
    }
    // let @Published / lastError dispatches to main land
    func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    // send fader writes BOTH cells of the monitor bus pair
    let m = makeModel()
    m.setInputSend(3, gain: 0x8000)
    m.flush()
    eq(last(Fireface400.mixAddress(kind: .input, src: 3, dest: 0)!)!, 0x8000,
       "UI send writes bus cell L")
    eq(last(Fireface400.mixAddress(kind: .input, src: 3, dest: 1)!)!, 0x8000,
       "UI send writes bus cell R")
    eq(m.input[3 * 18 + 0], 0x8000, "UI send updates published L")
    eq(m.input[3 * 18 + 1], 0x8000, "UI send updates published R")

    // matrix toggle flips a cell on/off
    m.toggleInput(src: 1, dest: 2)
    m.flush()
    eq(last(Fireface400.mixAddress(kind: .input, src: 1, dest: 2)!)!, 0x8000,
       "UI matrix toggle on")
    m.toggleInput(src: 1, dest: 2)
    m.flush()
    eq(last(Fireface400.mixAddress(kind: .input, src: 1, dest: 2)!)!, 0,
       "UI matrix toggle off")

    // MAIN row: both faders + amp gains for both channels
    let m2 = makeModel()
    m2.setMain(pair: 0, gain: 0x4000)
    m2.flush()
    eq(last(0x8008_0f80)!, 0x4000, "UI main writes fader L")
    eq(last(0x8008_0f84)!, 0x4000, "UI main writes fader R")
    let gains = w.filter { $0.0 == Fireface400.gainRegister }
    check(gains.contains { ($0.1 >> 16) == 4 }, "UI main writes amp idx 4")
    check(gains.contains { ($0.1 >> 16) == 5 }, "UI main writes amp idx 5")

    // MAIN mute flags both channels; hardware gets 0 + amp mute
    m2.setMainMute(pair: 0, on: true)
    m2.flush()
    eq(last(0x8008_0f80)!, 0, "UI mainmute zeroes L fader")
    eq(last(0x8008_0f84)!, 0, "UI mainmute zeroes R fader")
    check(m2.outputMute[0] && m2.outputMute[1], "UI mainmute flags both")

    // ST link: enabling adopts L's value into R; later set moves both
    let m3 = makeModel()
    _ = { w.removeAll() }()
    m3.setOutput(2, gain: 0x6000)
    m3.flush()
    m3.setStereoPair(1, on: true)
    m3.flush()
    eq(last(0x8008_0f88)!, 0x6000, "UI ST adopts L value into R")
    eq(m3.output[3], 0x6000, "UI ST published R follows L")
    m3.setOutput(2, gain: 0x2000)
    m3.flush()
    eq(last(0x8008_0f8c)!, 0x2000, "UI linked set writes peer")

    // preamp config chips -> 3-quadlet config block
    let m4 = makeModel()
    _ = { w.removeAll() }()
    m4.setPhantom(0, on: true)
    m4.flush()
    eq(w.filter { $0.0 == Fireface400.configReg }.last!.1, 0x0000_0811,
       "UI phantom writes config q0")
    m4.setPad(0, on: true)   // pad on input 3 -> q0 bit8
    m4.flush()
    check(w.filter { $0.0 == Fireface400.configReg }.last!.1 & 0x100 != 0,
          "UI pad sets q0 bit8")

    // monitor bus change with an active solo rewrites old+new bus cells
    let m5 = makeModel()
    _ = { w.removeAll() }()
    m5.setInputSend(4, gain: 0x8000)
    m5.flush()
    m5.setInputSolo(9, on: true)   // solo ch 9 -> ch 4 silenced on bus
    m5.flush()
    m5.monitorBus = 1              // AN 3/4
    m5.syncBusPair()
    m5.flush()
    eq(last(Fireface400.mixAddress(kind: .input, src: 4, dest: 0)!)!, 0x8000,
       "UI bus change restores old bus cell")
    eq(last(Fireface400.mixAddress(kind: .input, src: 4, dest: 2)!)!, 0,
       "UI bus change silences new bus cell (solo follows)")

    // mono: UI toggle writes averaged pair cells for inputs AND playback
    let m6 = makeModel()
    _ = { w.removeAll() }()
    m6.toggleInput(src: 5, dest: 0)      // L only = 0x8000, R stays 0
    m6.flush()
    m6.setMono(true)
    m6.flush()
    let avg: UInt32 = 0x4000             // (0x8000 + 0) / 2
    eq(last(Fireface400.mixAddress(kind: .input, src: 5, dest: 0)!)!, avg,
       "UI mono averages input L")
    eq(last(Fireface400.mixAddress(kind: .input, src: 5, dest: 1)!)!, avg,
       "UI mono averages input R")
    eq(last(Fireface400.mixAddress(kind: .playback, src: 0, dest: 0)!)!,
       avg, "UI mono averages playback (default 1:1 unity -> 0x4000)")

    // playback matrix toggle flips the cell on/off
    let m7 = makeModel()
    _ = { w.removeAll() }()
    m7.togglePlayback(src: 2, dest: 5)
    m7.flush()
    eq(last(Fireface400.mixAddress(kind: .playback, src: 2, dest: 5)!)!,
       0x8000, "UI pb toggle on")
    m7.togglePlayback(src: 2, dest: 5)
    m7.flush()
    eq(last(Fireface400.mixAddress(kind: .playback, src: 2, dest: 5)!)!,
       0, "UI pb toggle off")

    // instr chips: model maps i -> setInstrument(ch: i+2); q0 bits
    let m8 = makeModel()
    _ = { w.removeAll() }()
    m8.setInstr(0, on: true)
    m8.flush()
    check(w.filter { $0.0 == Fireface400.configReg }.last!.1 & 0x200 != 0,
          "UI instr3 sets config q0 bit 0x200")
    m8.setInstr(1, on: true)
    m8.flush()
    check(w.filter { $0.0 == Fireface400.configReg }.last!.1 & 0x04 != 0,
          "UI instr4 sets config q0 bit 0x04")

    // drag previews + the commit coalesce into ONE write on the same key
    let m9 = makeModel()
    let started = DispatchSemaphore(value: 0)
    let gate = DispatchSemaphore(value: 0)
    m9.hwq.submit("block") { started.signal(); _ = gate.wait(timeout: .now() + 10) }
    check(started.wait(timeout: .now() + 2) == .success, "queue blocked")
    _ = { w.removeAll() }()
    m9.previewOutput(0, gain: 0x1000)
    m9.previewOutput(0, gain: 0x2000)
    m9.setOutput(0, gain: 0x3000)
    gate.signal()
    m9.flush()
    let outWrites = w.filter { $0.0 == 0x8008_0f80 }
    eq(outWrites.count, 1, "preview+commit coalesced to one fader write")
    eq(outWrites.first?.1 ?? 0, 0x3000, "coalesced write carries the commit gain")

    // disconnected model: action sets lastError, emits no writes
    let md = MixerModel(testing: nil)
    _ = { w.removeAll() }()
    md.setOutput(0, gain: 0x4000)
    md.flush()
    check(w.isEmpty, "disconnected model writes nothing")
    pump()
    eq(md.lastError!, "not connected — change not applied",
       "disconnected model reports error")
}

// MARK: - MixerModel reconnect on deviceReappeared

do {
    func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    // reconnect routes the re-apply to the NEW controller; tracked
    // state and the monitor bus pair carry over
    var wa: [(UInt32, UInt32)] = []
    var wb: [(UInt32, UInt32)] = []
    let sinkA: (UInt32, UInt32) -> Bool = { a, v in wa.append((a, v)); return true }
    let sinkB: (UInt32, UInt32) -> Bool = { a, v in wb.append((a, v)); return true }
    var ctlB: FirefaceController!
    let m = MixerModel(testing: FirefaceController(testing: MixerState(), sink: sinkA))
    m.monitorBus = 1; m.syncBusPair(); m.flush()
    m.setOutput(0, gain: 0x2000); m.flush()
    m.makeController = { s in
        let c = FirefaceController(testing: s, sink: sinkB)
        ctlB = c
        return c
    }
    wa.removeAll()
    m.deviceReappeared(); m.flush(); pump()
    check(wa.isEmpty, "reconnect writes nothing to the dead controller")
    check(wb.count >= 600, "reconnect re-applied full state — got \(wb.count)")
    eq(wb.last(where: { $0.0 == 0x8008_0f80 })?.1 ?? 0, 0x2000,
       "reconnect carries tracked output fader")
    check(ctlB.busPair == (2, 3), "reconnect carries monitor bus pair")
    check(m.connected, "connected after reconnect")

    // a throwing makeController keeps the old controller alive
    var wa2: [(UInt32, UInt32)] = []
    let sinkA2: (UInt32, UInt32) -> Bool = { a, v in wa2.append((a, v)); return true }
    let m2 = MixerModel(testing: FirefaceController(testing: MixerState(), sink: sinkA2))
    m2.makeController = { _ in throw NSError(domain: "test", code: 1) }
    m2.deviceReappeared(); m2.flush(); pump()
    check(m2.lastError?.hasPrefix("reconnect failed") == true,
          "reconnect failure reported")
    m2.setOutput(1, gain: 0x1111); m2.flush()
    eq(wa2.last(where: { $0.0 == 0x8008_0f84 })?.1 ?? 0, 0x1111,
       "old controller still used after failed reconnect")

    // launched disconnected: the first reappearance connects
    var wb2: [(UInt32, UInt32)] = []
    let sinkB2: (UInt32, UInt32) -> Bool = { a, v in wb2.append((a, v)); return true }
    let m3 = MixerModel(testing: nil)
    m3.makeController = { s in FirefaceController(testing: s, sink: sinkB2) }
    m3.deviceReappeared(); m3.flush(); pump()
    check(m3.connected, "disconnected model connects on reappear")
    check(!wb2.isEmpty, "new controller received the apply")
}

// MARK: - ExternalStateWatcher.shouldAdopt (reload rule)

do {
    var a = MixerState(), b = MixerState()
    a.input[0] = 0x8000                     // "current" tracked state
    b.input[5] = 0x1234                     // "file" written by ffctl

    check(ExternalStateWatcher.shouldAdopt(file: b, current: a, lastSaved: nil),
          "external change adopted")
    check(!ExternalStateWatcher.shouldAdopt(file: a, current: a, lastSaved: nil),
          "file == current skipped")
    check(!ExternalStateWatcher.shouldAdopt(file: a, current: b, lastSaved: a),
          "own autosave (file == lastSaved) skipped")
    // stale-save case: file still equals lastSaved while a newer save is
    // queued behind the reload — restoring it would rewind a live drag.
    var newer = a; newer.input[0] = 0x2222  // drag in progress, save queued
    check(!ExternalStateWatcher.shouldAdopt(file: a, current: newer, lastSaved: a),
          "stale file (== lastSaved, != current) skipped")
    // but a file differing from BOTH is a real external write -> adopt
    var external = a; external.input[0] = 0x1111
    check(ExternalStateWatcher.shouldAdopt(file: external, current: b, lastSaved: a),
          "genuinely different external file adopted")
}

// MARK: - DirectoryWatcher (FS integration, generous timeouts)

do {
    let dir = testStateDir + "/watch-\(ProcessInfo.processInfo.processIdentifier)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    var fires = 0
    let watcher = DirectoryWatcher(directory: URL(fileURLWithPath: dir),
                                   debounce: 0.05) { fires += 1 }
    check(watcher != nil, "DirectoryWatcher created")
    // burst of 3 writes -> one debounced handler call
    for i in 0..<3 {
        try? "x\(i)".write(toFile: dir + "/f.json", atomically: true, encoding: .utf8)
    }
    let deadline = Date().addingTimeInterval(2)
    while fires == 0 && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    eq(fires, 1, "burst of writes -> one debounced callback")
    // keep pumping past the debounce window — a double-fire would only
    // show up after the loop above already exited
    let settle = Date().addingTimeInterval(0.4)
    while Date() < settle {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }
    eq(fires, 1, "burst produced exactly one callback")
}

// MARK: - Version

do {
    check(FFVersion.string.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil,
          "FFVersion.string is semver")
}

// MARK: - DevicePresence

do {
    check(DevicePresence.isFireface400(name: "RME Fireface 400 — ASFW"),
          "FF400 name matched")
    check(!DevicePresence.isFireface400(name: "Fireface 800"),
          "Fireface 800 not matched")
    check(!DevicePresence.isFireface400(name: "MacBook Pro Speakers"),
          "speakers not matched")

    var t = DevicePresence.Tracker(present: true)
    check(!t.update(present: true), "present at launch: no edge")
    t = DevicePresence.Tracker(present: true)
    _ = t.update(present: false)
    check(t.update(present: true), "absent->present edge fires")
    check(!t.update(present: true), "repeated present: no edge")
}
print("\(checks - failures)/\(checks) checks passed")
try? FileManager.default.removeItem(atPath: testStateDir)
exit(failures == 0 ? 0 : 1)
