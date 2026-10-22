import Foundation
import FFCore

func usage() -> Never {
    print("""
    ffctl — RME Fireface 400 mixer control via the ASFW user client

      ffctl mon [in] [outs...]     route input -> outputs at 0 dB   (default: in0 -> out0,out1)
      ffctl mix <in> <out> <g>     input fader cell     g = hex/dec/…dB  (0x8000 = 0 dB, 0 = mute)
      ffctl pb <pb> <out> <g>      playback fader cell  (what Mac audio uses)
      ffctl outvol <ch> <g>        output master fader  (also syncs hw amp gain)
      ffctl main <g> [pair]        main volume for a stereo pair (default: pair 0 = AN1/2)
      ffctl mainmute <on|off> [p]  mute/unmute a stereo pair
      ffctl gain <idx> <dB>        hw amp gain: 0-1 mic, 2-3 inputs 3/4, 4-9 out1-6,
                                   10-11 phones, 12-13 spdif, 14-21 adat
      ffctl phantom <1|2> <on|off> +48V phantom on mic input
      ffctl pad <3|4> <on|off>     -20 dB pad on input 3/4
      ffctl instr <3|4> <on|off>   instrument mode on input 3/4
      ffctl mute <in> <on|off>   mute input row on all outputs
      ffctl solo <in> <on|off>   exclusive solo on monitor bus (AN1/2)
      ffctl phase <in> <on|off>  phase invert input row (negative gain)
      ffctl outmute <ch> <on|off> mute output master fader
      ffctl mono <on|off>        mono-lock the AN1/2 bus pair
      ffctl stereo <pair> <on|off> stereo-link output pair (0=AN1/2, 3=PHONES…)
      ffctl cfg <key> <val>        config fields: ilevel/olevel/phlevel
                                   (logain|4dbu|10dbv), spdifpro on|off
      ffctl config                 show tracked config + quadlets
      ffctl 1to1                   restore playback i -> out i at 0 dB
      ffctl mute-all               zero every input -> output fader
      ffctl apply                  re-write entire saved mixer state
      ffctl state [--json]         print tracked mixer state summary

    Automation:
      ffctl save <name>            snapshot current mix state as a named preset
      ffctl load <name>            load a snapshot and apply it to the hardware
      ffctl snaps                  list saved snapshots
      ffctl rmsnap <name>          delete a snapshot
      ffctl batch <file|->         run ffctl commands from a file or stdin
                                   (one command per line, # comments, one
                                   user-client session for the whole batch)

    Gain arguments accept: 0x8000, decimal, dB like "-6dB", or a relative
    step like "+3dB"/"-3dB" (applied to the tracked value — handy for
    hotkey-driven volume scripts).
    """)
    exit(0)
}

func onOff(_ s: String) -> Bool? { ["on": true, "off": false][s] }

let args = CommandLine.arguments
guard args.count > 1 else { usage() }

let ctl: FirefaceController
do {
    ctl = try FirefaceController()
} catch {
    print("error: cannot connect to ASFWDriver user client: \(error)")
    print("(is ASFW installed and is this binary signed with the userclient-access entitlement?)")
    exit(1)
}

func ok(_ b: Bool, _ what: String) -> Bool {
    print(b ? "ok: \(what)" : "FAILED: \(what)")
    return b
}

/// One command = one slice of arguments; returns the exit code.
func run(_ a: ArraySlice<String>, _ ctl: FirefaceController) -> Int32 {
    guard let cmd = a.first else { usage() }
    let a = Array(a)
    switch cmd {
    case "mon":
        let src = a.count > 1 ? Int(a[1]) ?? 0 : 0
        let outs = a.count > 2 ? a[2...].compactMap { Int($0) } : [0, 1]
        for o in outs {
            if !ok(ctl.setInputFader(src: src, dest: o, gain: Fireface400.unityGain),
                   "input \(src) -> out \(o) @ 0dB") { return 1 }
        }
    case "mix":
        guard a.count > 3, let src = Int(a[1]), let dest = Int(a[2]),
              let g = Fireface400.parseGainArgument(
                  a[3], current: ctl.state.input[MixerState.index(src: src, dest: dest)])
        else { usage() }
        guard ok(ctl.setInputFader(src: src, dest: dest, gain: g), "mix cell") else { return 1 }
    case "pb":
        guard a.count > 3, let src = Int(a[1]), let dest = Int(a[2]),
              let g = Fireface400.parseGainArgument(
                  a[3], current: ctl.state.playback[MixerState.index(src: src, dest: dest)])
        else { usage() }
        guard ok(ctl.setPlaybackFader(src: src, dest: dest, gain: g), "playback cell") else { return 1 }
    case "outvol":
        guard a.count > 2, let ch = Int(a[1]), (0..<Fireface400.channelCount).contains(ch),
              let g = Fireface400.parseGainArgument(a[2], current: ctl.state.output[ch])
        else { usage() }
        guard ok(ctl.setOutputFader(ch: ch, gain: g), "output fader") else { return 1 }
        if ctl.state.outputStereo[ch / 2] {
            _ = ok(ctl.setOutputFader(ch: ch ^ 1, gain: g), "output fader (linked peer)")
        }
    case "main":
        guard a.count > 1, let pair = a.count > 2 ? Int(a[2]) : 0,
              (0..<Fireface400.channelCount / 2).contains(pair),
              let g = Fireface400.parseGainArgument(a[1], current: ctl.state.output[pair * 2])
        else { usage() }
        guard ok(ctl.setPairFader(pair: pair, gain: g), "main pair \(pair)") else { return 1 }
    case "mainmute":
        guard a.count > 1, let on = onOff(a[1]),
              let pair = a.count > 2 ? Int(a[2]) : 0 else { usage() }
        guard ok(ctl.setPairMute(pair: pair, on: on), "mainmute \(pair)") else { return 1 }
    case "phantom":
        guard a.count > 2, let ch = Int(a[1]), (1...2).contains(ch),
              let on = onOff(a[2]) else { usage() }
        guard ok(ctl.setPhantom(ch: ch - 1, on: on), "phantom \(a[1]) \(a[2])") else { return 1 }
    case "pad":
        guard a.count > 2, let ch = Int(a[1]), (3...4).contains(ch),
              let on = onOff(a[2]) else { usage() }
        guard ok(ctl.setPad(ch: ch - 1, on: on), "pad \(a[1]) \(a[2])") else { return 1 }
    case "instr":
        guard a.count > 2, let ch = Int(a[1]), (3...4).contains(ch),
              let on = onOff(a[2]) else { usage() }
        guard ok(ctl.setInstrument(ch: ch - 1, on: on), "instr \(a[1]) \(a[2])") else { return 1 }
    case "mute":
        guard a.count > 2, let src = Int(a[1]), let on = onOff(a[2]) else { usage() }
        guard ok(ctl.setInputMute(src: src, on: on), "mute in \(src)") else { return 1 }
    case "solo":
        guard a.count > 2, let src = Int(a[1]), let on = onOff(a[2]) else { usage() }
        guard ok(ctl.setInputSolo(src: src, on: on), "solo in \(src)") else { return 1 }
    case "phase":
        guard a.count > 2, let src = Int(a[1]), let on = onOff(a[2]) else { usage() }
        guard ok(ctl.setInputPhase(src: src, on: on), "phase in \(src)") else { return 1 }
    case "outmute":
        guard a.count > 2, let ch = Int(a[1]), let on = onOff(a[2]) else { usage() }
        guard ok(ctl.setOutputMute(ch: ch, on: on), "outmute \(ch)") else { return 1 }
    case "mono":
        guard a.count > 1, let on = onOff(a[1]) else { usage() }
        guard ok(ctl.setMonoBus(on: on), "mono \(on)") else { return 1 }
    case "stereo":
        guard a.count > 2, let p = Int(a[1]), let on = onOff(a[2]) else { usage() }
        guard ok(ctl.setOutputStereo(pair: p, on: on), "stereo pair \(p)") else { return 1 }
    case "cfg":
        guard a.count > 2 else { usage() }
        var c = ctl.config
        let lv: Fireface400.TriLevel? = ["logain": .lowGain, "4dbu": .plus4dBu, "10dbv": .minus10dBV][a[2]]
        let flag = onOff(a[2])
        switch a[1] {
        case "ilevel":   guard let lv else { usage() }; c.inputLevel = lv
        case "olevel":   guard let lv else { usage() }; c.outputLevel = lv
        case "phlevel":  guard let lv else { usage() }; c.phonesLevel = lv
        case "spdifpro": guard let flag else { usage() }; c.spdifPro = flag
        case "syncref":
            guard let r: Fireface400.SyncRef = ["adat1": .adat1, "adat2": .adat2,
                            "spdif": .spdif, "wclk": .wordClock, "tco": .timecode][a[2]]
            else { usage() }
            c.syncRef = r
        default: usage()
        }
        guard ok(ctl.writeConfig(c), "cfg \(a[1]) \(a[2])") else { return 1 }
    case "config":
        let c = ctl.config, q = c.quadlets
        print("phantom1=\(c.phantom1) phantom2=\(c.phantom2) pad3=\(c.pad3) pad4=\(c.pad4)")
        print("instr3=\(c.instr3) instr4=\(c.instr4) ilevel=\(c.inputLevel.label) olevel=\(c.outputLevel.label) phlevel=\(c.phonesLevel.label)")
        print("clockMaster=\(c.clockMaster) syncRef=\(c.syncRef.label) spdifPro=\(c.spdifPro)")
        print(String(format: "config quadlets: %08x %08x %08x", q.0, q.1, q.2))
    case "gain":
        guard a.count > 2, let idx = Int(a[1]), let db = Double(a[2]) else { usage() }
        guard ok(ctl.setAmpGain(index: idx, dB: db), "amp gain") else { return 1 }
    case "1to1":
        for i in 0..<Fireface400.channelCount {
            if !ok(ctl.setPlaybackFader(src: i, dest: i, gain: Fireface400.unityGain),
                   "pb \(i) -> out \(i)") { return 1 }
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
        if r.failed > 0 { return 1 }
    case "state":
        let s = ctl.state
        if a.count > 1, a[1] == "--json" {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? enc.encode(s),
                  let text = String(data: data, encoding: .utf8)
            else { print("FAILED: encode state"); return 1 }
            print(text)
            return 0
        }
        var n = 0
        for i in 0..<s.input.count where s.input[i] != 0 {
            print(String(format: "  in%d -> out%d = 0x%05x", i/18, i%18, s.input[i])); n += 1
        }
        for i in 0..<s.playback.count where s.playback[i] != 0 {
            print(String(format: "  pb%d -> out%d = 0x%05x", i/18, i%18, s.playback[i])); n += 1
        }
        print("tracked non-zero cells: \(n); ampGains: \(s.ampGains)")
    case "save":
        guard a.count > 1 else { usage() }
        ctl.saveState()
        guard ok(ctl.state.saveSnapshot(name: a[1]), "snapshot '\(a[1])'") else { return 1 }
    case "load":
        guard a.count > 1 else { usage() }
        guard let s = MixerState.loadSnapshot(name: a[1]) else {
            print("FAILED: no snapshot '\(a[1])' (see: ffctl snaps)")
            return 1
        }
        ctl.restoreState(s)
        let r = ctl.applyAll()
        print("loaded '\(a[1])': \(r.written) writes, \(r.failed) failed")
        if r.failed > 0 { return 1 }
    case "snaps":
        let names = MixerState.snapshotNames()
        print(names.isEmpty ? "no snapshots" : names.joined(separator: "\n"))
    case "rmsnap":
        guard a.count > 1 else { usage() }
        guard ok(MixerState.deleteSnapshot(name: a[1]), "rm snapshot '\(a[1])'") else { return 1 }
    case "batch":
        guard a.count > 1 else { usage() }
        let text: String?
        if a[1] == "-" {
            text = String(data: FileHandle.standardInput.readDataToEndOfFile(), encoding: .utf8)
        } else {
            text = try? String(contentsOfFile: a[1], encoding: .utf8)
        }
        guard let text else { print("FAILED: cannot read \(a[1])"); return 1 }
        var rc: Int32 = 0
        for (i, line) in text.components(separatedBy: .newlines).enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("#") { continue }
            let parts = t.split(separator: " ").map(String.init)
            if run(parts[...], ctl) != 0 { print("batch: line \(i+1) failed: \(t)"); rc = 1; break }
        }
        return rc
    default:
        usage()
    }
    return 0
}

let rc = run(args[1...], ctl)
ctl.saveState()
exit(rc)
