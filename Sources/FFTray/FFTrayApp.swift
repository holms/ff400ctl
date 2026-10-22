import SwiftUI
import FFCore

@main
struct FFTrayApp: App {
    @StateObject private var model = MixerModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(model)
        } label: {
            Label("FF400", systemImage: "slider.horizontal.3")
                .labelStyle(.titleAndIcon)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Monitor bus = a stereo output pair the INPUT send faders write to.
let busPairs: [(name: String, a: Int, b: Int)] = [
    ("AN 1/2", 0, 1), ("AN 3/4", 2, 3), ("AN 5/6", 4, 5),
    ("PHONES", 6, 7), ("SPDIF", 8, 9),
    ("ADAT 1/2", 10, 11), ("ADAT 3/4", 12, 13),
    ("ADAT 5/6", 14, 15), ("ADAT 7/8", 16, 17),
]

final class MixerModel: NSObject, ObservableObject {
    @Published var connected = false
    @Published var lastError: String?
    @Published var matrixTab = 0          // 0 = inputs, 1 = playback
    @Published var monitorBus = 0         // index into busPairs
    @Published var input: [UInt32]
    @Published var playback: [UInt32]
    @Published var output: [UInt32]
    @Published var outputStereo = [Bool](repeating: false, count: 9)
    @Published var micGain: [Double] = [0, 0]
    @Published var inGain: [Double] = [0, 0]
    @Published var phantom: [Bool] = [false, false]
    @Published var pad: [Bool] = [false, false]
    @Published var instr: [Bool] = [false, false]
    @Published var inputMute = [Bool](repeating: false, count: 18)
    @Published var inputPhase = [Bool](repeating: false, count: 18)
    @Published var inputSolo = [Bool](repeating: false, count: 18)
    @Published var outputMute = [Bool](repeating: false, count: 18)
    @Published var monoBus = false

    private var ctl: FirefaceController?
    private let hwq = WriteCoalescer()

    override init() {
        let s = MixerState.load()
        input = s.input
        playback = s.playback
        output = s.output
        super.init()
        do {
            let c = try FirefaceController()
            ctl = c
            connected = true
            let p = busPairs[monitorBus]
            ctl?.busPair = (p.a, p.b)
            phantom = [c.config.phantom1, c.config.phantom2]
            pad = [c.config.pad3, c.config.pad4]
            instr = [c.config.instr3, c.config.instr4]
            inputMute = c.state.inputMute
            inputPhase = c.state.inputPhase
            inputSolo = c.state.inputSolo
            outputMute = c.state.outputMute
            monoBus = c.state.monoBus
            outputStereo = c.state.outputStereo
            micGain = [Fireface400.ampGainDB(index: 0, devval: c.state.ampGains["0"] ?? 0) ?? 0,
                       Fireface400.ampGainDB(index: 1, devval: c.state.ampGains["1"] ?? 0) ?? 0]
            inGain = [Fireface400.ampGainDB(index: 2, devval: c.state.ampGains["2"] ?? 0) ?? 0,
                      Fireface400.ampGainDB(index: 3, devval: c.state.ampGains["3"] ?? 0) ?? 0]
        } catch {
            lastError = "\(error)"
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil)
    }

    /// Flush pending writes and persist state before the process exits.
    @objc private func appWillTerminate(_ note: Notification) {
        hwq.waitUntilIdle()
        ctl?.saveState()
    }

    /// Run a hardware operation on the serial write queue; report failure
    /// back on the main thread. UI state is updated optimistically by the
    /// caller so faders stay responsive while transactions drain. State is
    /// auto-saved (coalesced) after each change.
    private func hw(_ key: String, _ failMsg: String = "write failed",
                    _ work: @escaping (FirefaceController) -> Bool) {
        hwq.submit(key) { [weak self] in
            guard let self, let c = self.ctl else { return }
            if !work(c) {
                DispatchQueue.main.async { self.lastError = failMsg }
            }
            self.hwq.submit("save") { c.saveState() }
        }
    }

    private func idx(_ src: Int, _ dest: Int) -> Int { MixerState.index(src: src, dest: dest) }

    // MARK: - Input sends (input -> monitor bus pair, stereo linked)

    func inputSend(_ src: Int) -> UInt32 {
        input[idx(src, busPairs[monitorBus].a)]
    }

    func syncBusPair() {
        let p = busPairs[monitorBus]
        hw("bus") { c in c.setBusPair(a: p.a, b: p.b) }
    }

    func setInputSend(_ src: Int, gain: UInt32) {
        let pair = busPairs[monitorBus]
        input[idx(src, pair.a)] = gain
        input[idx(src, pair.b)] = gain
        hw("send.\(src)", "send write failed") { c in
            var ok = c.setInputFader(src: src, dest: pair.a, gain: gain)
            ok = c.setInputFader(src: src, dest: pair.b, gain: gain) && ok
            return ok
        }
    }

    func setInputMute(_ src: Int, on: Bool) {
        inputMute[src] = on
        hw("imute.\(src)") { c in c.setInputMute(src: src, on: on) }
    }

    func setInputPhase(_ src: Int, on: Bool) {
        inputPhase[src] = on
        hw("iphase.\(src)") { c in c.setInputPhase(src: src, on: on) }
    }

    func setInputSolo(_ src: Int, on: Bool) {
        for i in 0..<18 { inputSolo[i] = (i == src) && on }
        hw("solo") { c in c.setInputSolo(src: src, on: on) }
    }

    func setOutputMute(_ ch: Int, on: Bool) {
        outputMute[ch] = on
        hw("omute.\(ch)") { c in c.setOutputMute(ch: ch, on: on) }
    }

    func setMono(_ on: Bool) {
        monoBus = on
        hw("mono") { c in
            let ok = c.setMonoBus(on: on)
            if ok, on {
                let cells = c.state.input
                DispatchQueue.main.async { self.input = cells }
            }
            return ok
        }
    }

    func inputSendDB(_ src: Int) -> Double {
        Fireface400.db(fromGain: inputSend(src))
    }

    // MARK: - Matrix cells

    func toggleInput(src: Int, dest: Int) {
        let newVal: UInt32 = input[idx(src, dest)] == 0 ? Fireface400.unityGain : 0
        input[idx(src, dest)] = newVal
        hw("cell.i.\(src).\(dest)") { c in c.setInputFader(src: src, dest: dest, gain: newVal) }
    }

    func togglePlayback(src: Int, dest: Int) {
        let newVal: UInt32 = playback[idx(src, dest)] == 0 ? Fireface400.unityGain : 0
        playback[idx(src, dest)] = newVal
        hw("cell.p.\(src).\(dest)") { c in c.setPlaybackFader(src: src, dest: dest, gain: newVal) }
    }

    // MARK: - Outputs

    func setOutput(_ ch: Int, gain: UInt32) {
        output[ch] = gain
        let peer = ch ^ 1, linked = outputStereo[ch / 2]
        if linked { output[peer] = gain }
        hw("out.\(ch)") { c in c.setOutputFader(ch: ch, gain: gain) }
        if linked {
            hw("out.\(peer)") { c in c.setOutputFader(ch: peer, gain: gain) }
        }
    }

    /// TotalMix-style stereo button: a linked pair moves as one fader.
    func setStereoPair(_ pair: Int, on: Bool) {
        outputStereo[pair] = on
        if on {
            // adopt L's fader value for both, like TotalMix
            let g = output[pair * 2]
            output[pair * 2 + 1] = g
            hw("out.\(pair * 2 + 1)") { c in c.setOutputFader(ch: pair * 2 + 1, gain: g) }
        }
        hw("stereo.\(pair)") { c in c.setOutputStereo(pair: pair, on: on) }
    }

    func outputDB(_ ch: Int) -> Double { Fireface400.db(fromGain: output[ch]) }

    // MARK: - Hardware preamp gains (only inputs 1-4 have them)

    func setMicGain(_ i: Int, dB: Double) {
        micGain[i] = dB
        let idx = i == 0 ? Fireface400.AmpGain.mic1.rawValue : Fireface400.AmpGain.mic2.rawValue
        hw("mic.\(i)") { c in c.setAmpGain(index: idx, dB: dB) }
    }

    func setInGain(_ i: Int, dB: Double) {
        inGain[i] = dB
        let idx = i == 0 ? Fireface400.AmpGain.input3.rawValue : Fireface400.AmpGain.input4.rawValue
        hw("ingain.\(i)") { c in c.setAmpGain(index: idx, dB: dB) }
    }

    func setPhantom(_ i: Int, on: Bool) {
        phantom[i] = on
        hw("cfg.phantom.\(i)", "config write failed") { c in c.setPhantom(ch: i, on: on) }
    }

    func setPad(_ i: Int, on: Bool) {
        pad[i] = on
        hw("cfg.pad.\(i)", "config write failed") { c in c.setPad(ch: i + 2, on: on) }
    }

    func setInstr(_ i: Int, on: Bool) {
        instr[i] = on
        hw("cfg.instr.\(i)", "config write failed") { c in c.setInstrument(ch: i + 2, on: on) }
    }

    // MARK: - Bulk

    func applyAll() {
        hwq.submit("apply") { [weak self] in
            guard let self, let r = self.ctl?.applyAll() else { return }
            let s = self.ctl?.state
            DispatchQueue.main.async {
                self.lastError = r.failed == 0 ? nil : "\(r.failed) writes failed"
                if let s { self.input = s.input; self.playback = s.playback; self.output = s.output }
            }
        }
    }

    func save() {
        hwq.submit("save") { [weak self] in self?.ctl?.saveState() }
    }

    // MARK: - Detached window

    private var detachedWindow: NSWindow?

    /// Open the same UI in a persistent titled window that survives focus
    /// changes (the menu-bar panel auto-closes whenever it loses focus).
    func openDetached() {
        if detachedWindow == nil {
            let host = NSHostingController(
                rootView: ContentView(detached: true).environmentObject(self))
            let w = NSWindow(contentViewController: host)
            w.title = "Fireface 400 Mixer"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            detachedWindow = w
        }
        detachedWindow?.center()
        detachedWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
