import Foundation
import FFCore

func usage() -> Never {
    print("""
    ffctl — RME Fireface 400 mixer control via the ASFW user client

      ffctl mon [in] [outs...]     route input -> outputs at 0 dB   (default: in0 -> out0,out1)
      ffctl mix <in> <out> <g>     input fader cell     g = hex/dec/…dB  (0x8000 = 0 dB, 0 = mute)
      ffctl pb <pb> <out> <g>      playback fader cell  (what Mac audio uses)
      ffctl outvol <ch> <g>        output master fader  (also syncs hw amp gain)
      ffctl gain <idx> <dB>        hw amp gain: 0-1 mic, 2-3 inputs 3/4, 4-9 out1-6,
                                   10-11 phones, 12-13 spdif, 14-21 adat
      ffctl phantom <1|2> <on|off> +48V phantom on mic input
      ffctl pad <3|4> <on|off>     -20 dB pad on input 3/4
      ffctl instr <3|4> <on|off>   instrument mode on input 3/4
      ffctl cfg <key> <val>        config fields: ilevel/olevel/phlevel
                                   (logain|4dbu|10dbv), spdifpro on|off
      ffctl config                 show tracked config + quadlets
      ffctl 1to1                   restore playback i -> out i at 0 dB
      ffctl mute-all               zero every input -> output fader
      ffctl apply                  re-write entire saved mixer state
      ffctl state                  print tracked mixer state summary

    Gain arguments accept: 0x8000, decimal, or dB like "-6dB".
    """)
    exit(0)
}

func onOff(_ s: String) -> Bool? { ["on": true, "off": false][s] }

func parseGain(_ s: String) -> UInt32? {
    if s.hasSuffix("dB"), let db = Double(s.dropLast(2)) {
        return Fireface400.gain(fromDB: db)
    }
    if let v = UInt32(s, radix: 0) { return v }
    return nil
}

let args = CommandLine.arguments
guard args.count > 1 else { usage() }

let client: ASFWClient
let ctl: FirefaceController
do {
    client = try ASFWClient()
    ctl = try FirefaceController(client: client)
} catch {
    print("error: cannot connect to ASFWDriver user client: \(error)")
    print("(is ASFW installed and is this binary signed with the userclient-access entitlement?)")
    exit(1)
}

func ok(_ b: Bool, _ what: String) {
    print(b ? "ok: \(what)" : "FAILED: \(what)")
    if !b { exit(1) }
}

switch args[1] {
case "mon":
    let src = args.count > 2 ? Int(args[2]) ?? 0 : 0
    let outs = args.count > 3 ? args[3...].compactMap { Int($0) } : [0, 1]
    for o in outs {
        ok(ctl.setInputFader(src: src, dest: o, gain: Fireface400.unityGain),
           "input \(src) -> out \(o) @ 0dB")
    }
case "mix":
    guard args.count > 4, let g = parseGain(args[4]) else { usage() }
    ok(ctl.setInputFader(src: Int(args[2])!, dest: Int(args[3])!, gain: g), "mix cell")
case "pb":
    guard args.count > 4, let g = parseGain(args[4]) else { usage() }
    ok(ctl.setPlaybackFader(src: Int(args[2])!, dest: Int(args[3])!, gain: g), "playback cell")
case "outvol":
    guard args.count > 3, let g = parseGain(args[3]) else { usage() }
    ok(ctl.setOutputFader(ch: Int(args[2])!, gain: g), "output fader")
case "phantom":
    guard args.count > 3, let ch = Int(args[2]), (1...2).contains(ch),
          let on = onOff(args[3]) else { usage() }
    ok(ctl.setPhantom(ch: ch - 1, on: on), "phantom \(args[2]) \(args[3])")
case "pad":
    guard args.count > 3, let ch = Int(args[2]), (3...4).contains(ch),
          let on = onOff(args[3]) else { usage() }
    ok(ctl.setPad(ch: ch - 1, on: on), "pad \(args[2]) \(args[3])")
case "instr":
    guard args.count > 3, let ch = Int(args[2]), (3...4).contains(ch),
          let on = onOff(args[3]) else { usage() }
    ok(ctl.setInstrument(ch: ch - 1, on: on), "instr \(args[2]) \(args[3])")
case "cfg":
    guard args.count > 3 else { usage() }
    var c = ctl.config
    let lv: Fireface400.TriLevel? = ["logain": .lowGain, "4dbu": .plus4dBu, "10dbv": .minus10dBV][args[3]]
    let flag = onOff(args[3])
    switch args[2] {
    case "ilevel":   guard let lv else { usage() }; c.inputLevel = lv
    case "olevel":   guard let lv else { usage() }; c.outputLevel = lv
    case "phlevel":  guard let lv else { usage() }; c.phonesLevel = lv
    case "spdifpro": guard let flag else { usage() }; c.spdifPro = flag
    case "syncref":
        guard let r: Fireface400.SyncRef = ["adat1": .adat1, "adat2": .adat2,
                        "spdif": .spdif, "wclk": .wordClock, "tco": .timecode][args[3]]
        else { usage() }
        c.syncRef = r
    default: usage()
    }
    ok(ctl.writeConfig(c), "cfg \(args[2]) \(args[3])")
case "config":
    let c = ctl.config, q = c.quadlets
    print("phantom1=\(c.phantom1) phantom2=\(c.phantom2) pad3=\(c.pad3) pad4=\(c.pad4)")
    print("instr3=\(c.instr3) instr4=\(c.instr4) ilevel=\(c.inputLevel.label) olevel=\(c.outputLevel.label) phlevel=\(c.phonesLevel.label)")
    print("clockMaster=\(c.clockMaster) syncRef=\(c.syncRef.label) spdifPro=\(c.spdifPro)")
    print(String(format: "config quadlets: %08x %08x %08x", q.0, q.1, q.2))
case "gain":
    guard args.count > 3, let idx = Int(args[2]), let db = Double(args[3]) else { usage() }
    ok(ctl.setAmpGain(index: idx, dB: db), "amp gain")
case "1to1":
    for i in 0..<Fireface400.channelCount {
        ok(ctl.setPlaybackFader(src: i, dest: i, gain: Fireface400.unityGain), "pb \(i) -> out \(i)")
    }
case "mute-all":
    for src in 0..<Fireface400.channelCount {
        for d in 0..<Fireface400.channelCount {
            _ = ctl.setInputFader(src: src, dest: d, gain: 0)
        }
    }
    print("ok: all input faders muted")
case "apply":
    let r = ctl.applyAll()
    print("applied: \(r.written) writes, \(r.failed) failed")
    if r.failed > 0 { exit(1) }
case "state":
    let s = ctl.state
    var n = 0
    for i in 0..<s.input.count where s.input[i] != 0 {
        print(String(format: "  in%d -> out%d = 0x%05x", i/18, i%18, s.input[i])); n += 1
    }
    for i in 0..<s.playback.count where s.playback[i] != 0 {
        print(String(format: "  pb%d -> out%d = 0x%05x", i/18, i%18, s.playback[i])); n += 1
    }
    print("tracked non-zero cells: \(n); ampGains: \(s.ampGains)")
default:
    usage()
}
ctl.saveState()
