import Foundation
@testable import FFCore

// Minimal test harness (no XCTest dependency — runs under Command Line Tools).
var failures = 0
var checks = 0

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
eq(Fireface400.ampGainValue(index: 4, dB: -10), 0x0004_001a, "out1 @-10dB = 26")
eq(Fireface400.ampGainValue(index: 4, dB: -60), 0x0004_003f, "out1 deep att = mute")
eq(Fireface400.ampGainValue(index: 10, dB: -6), 0x000a_0012, "phonesL @-6dB = 18")
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

    // mono: mirrors L cell into R on the bus pair
    let ctl4 = FirefaceController(testing: MixerState(), sink: sink)
    _ = ctl4.setInputFader(src: 4, dest: 0, gain: 0x4000)
    _ = ctl4.setInputFader(src: 4, dest: 1, gain: 0)
    _ = ctl4.setMonoBus(on: true)
    eq(ctl4.state.input[MixerState.index(src: 4, dest: 1)], 0x4000,
       "mono mirrors L cell into R")
    let c41 = Fireface400.mixAddress(kind: .input, src: 4, dest: 1)!
    eq(writes.last(where: { $0.0 == c41 })!.1, 0x4000, "mono writes R cell")

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
    // stale file with short array is tolerated on decode path? (not: decodeIfPresent keeps it)
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
print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
