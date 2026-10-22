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

print("\(checks - failures)/\(checks) checks passed")
exit(failures == 0 ? 0 : 1)
