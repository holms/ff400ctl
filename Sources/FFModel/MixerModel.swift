import Foundation
import Combine
import OSLog
import FFCore

let modelLog = Logger(subsystem: "net.holms.fftray", category: "model")

/// Monitor bus = a stereo output pair the INPUT send faders write to.
public let busPairs: [(name: String, a: Int, b: Int)] = [
    ("AN 1/2", 0, 1), ("AN 3/4", 2, 3), ("AN 5/6", 4, 5),
    ("PHONES", 6, 7), ("SPDIF", 8, 9),
    ("ADAT 1/2", 10, 11), ("ADAT 3/4", 12, 13),
    ("ADAT 5/6", 14, 15), ("ADAT 7/8", 16, 17),
]

/// View model for the FF400 mixer. Owns the FirefaceController, the
/// serial hardware queue, and all UI-facing state. No AppKit — app-only
/// concerns (device presence, launch-at-login, detached window) live in
/// the FFTray target and call back into this model.
public final class MixerModel: NSObject, ObservableObject {
    @Published public var connected = false
    @Published public var lastError: String?
    @Published public var matrixTab = 0          // 0 = inputs, 1 = playback
    @Published public var monitorBus = 0         // index into busPairs
    @Published public var input: [UInt32]
    @Published public var playback: [UInt32]
    @Published public var output: [UInt32]
    @Published public var outputStereo = [Bool](repeating: false, count: 9)
    @Published public var micGain: [Double] = [0, 0]
    @Published public var inGain: [Double] = [0, 0]
    @Published public var phantom: [Bool] = [false, false]
    @Published public var pad: [Bool] = [false, false]
    @Published public var instr: [Bool] = [false, false]
    @Published public var inputMute = [Bool](repeating: false, count: 18)
    @Published public var inputPhase = [Bool](repeating: false, count: 18)
    @Published public var inputSolo = [Bool](repeating: false, count: 18)
    @Published public var outputMute = [Bool](repeating: false, count: 18)
    @Published public var monoBus = false
    /// Mirrors SMAppService.mainApp.status; the FFTray target syncs this
    /// (the API only exists for a bundled app).
    @Published public var launchAtLogin = false
    /// Re-apply the saved mix when the FF400 reappears after a power
    /// cycle (mixer RAM is volatile). Persisted in UserDefaults.
    @Published public var autoReapply =
        UserDefaults.standard.object(forKey: "autoReapply") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReapply, forKey: "autoReapply") }
    }

    var ctl: FirefaceController?
    let hwq = WriteCoalescer()
    /// Watches the state.json directory for writes by ffctl (atomic saves
    /// replace the file, so the directory is watched, not the file).
    private var stateWatcher: DispatchSourceFileSystemObject?
    private var stateWatcherFD: Int32 = -1
    private var reloadScheduled = false
    /// State at our own most recent save. Touched ONLY on the hw queue —
    /// lets the file watcher tell our autosaves (and files read while a
    /// newer save is still queued behind the reload) from real external
    /// changes.
    var lastSaved: MixerState?
    /// Called when the detached window opens — the app closes the
    /// popover so the mixer isn't shown in two places.
    public var onDetach: (() -> Void)?
    /// Called to open the persistent detached window (implemented by the
    /// app's DetachWindowController).
    public var onOpenDetached: (() -> Void)?

    /// Production init — connect to ASFW and watch the state file.
    /// The app additionally wires the CoreAudio presence watcher.
    public override init() {
        let s = MixerState.load()
        input = s.input
        playback = s.playback
        output = s.output
        super.init()
        do {
            let c = try FirefaceController()
            adopt(c)
        } catch {
            lastError = "\(error)"
        }
        watchStateFile()
    }

    /// Testing init — inject a (possibly nil) controller and a state;
    /// no hardware connect attempt, no file watcher.
    /// `controller: nil` yields a disconnected model.
    public init(testing controller: FirefaceController?,
                state: MixerState = .load()) {
        input = state.input
        playback = state.playback
        output = state.output
        super.init()
        if let c = controller { adopt(c, state: state) }
    }

    private func adopt(_ c: FirefaceController, state: MixerState? = nil) {
        ctl = c
        connected = true
        let p = busPairs[monitorBus]
        c.busPair = (p.a, p.b)
        publish(c.state)
        lastSaved = c.state
    }

    deinit {
        stateWatcher?.cancel()
    }

    /// Re-apply the tracked mix — called by the app's presence watcher
    /// when the FF400 reappears after a power cycle.
    public func deviceReappeared() {
        applyAll()
        modelLog.notice("FF400 reappeared — re-applied mix")
    }

    /// Drain pending hw-queue work (tests + shutdown).
    public func flush() { hwq.waitUntilIdle() }

    /// Persist state now (app termination).
    public func flushAndSave() {
        hwq.waitUntilIdle()
        if let c = ctl { c.saveState(); lastSaved = c.state }
    }

    /// Push a MixerState into every @Published property.
    func publish(_ s: MixerState) {
        input = s.input
        playback = s.playback
        output = s.output
        inputMute = s.inputMute
        inputPhase = s.inputPhase
        inputSolo = s.inputSolo
        outputMute = s.outputMute
        monoBus = s.monoBus
        outputStereo = s.outputStereo
        phantom = [s.config.phantom1, s.config.phantom2]
        pad = [s.config.pad3, s.config.pad4]
        instr = [s.config.instr3, s.config.instr4]
        micGain = [Fireface400.ampGainDB(index: 0, devval: s.ampGains["0"] ?? 0) ?? 0,
                   Fireface400.ampGainDB(index: 1, devval: s.ampGains["1"] ?? 0) ?? 0]
        inGain = [Fireface400.ampGainDB(index: 2, devval: s.ampGains["2"] ?? 0) ?? 0,
                  Fireface400.ampGainDB(index: 3, devval: s.ampGains["3"] ?? 0) ?? 0]
    }

    private func watchStateFile() {
        let dir = MixerState.storeURL.deletingLastPathComponent()
        stateWatcherFD = open(dir.path, O_EVTONLY)
        guard stateWatcherFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: stateWatcherFD, eventMask: .write, queue: .main)
        let fd = stateWatcherFD
        src.setEventHandler { [weak self] in self?.stateFileChanged() }
        src.setCancelHandler { close(fd) }
        src.resume()
        stateWatcher = src
    }

    /// Debounce rapid save bursts (~200 ms) before reloading.
    private func stateFileChanged() {
        if reloadScheduled { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.reloadScheduled = false
            self.reloadStateIfChanged()
        }
    }

    /// Re-read state.json on the hw queue; adopt it when it differs from
    /// the controller's tracked state (ffctl wrote the hardware already —
    /// just realign the model; our own autosaves compare equal).
    private func reloadStateIfChanged() {
        hwq.submit("reload") { [weak self] in
            guard let self, let c = self.ctl else { return }
            let s = MixerState.load()
            // Skip our own saves — and stale ones: a save queued behind
            // this reload hasn't landed yet, so the file can be older
            // than c.state; restoring it would rewind a live drag.
            guard ExternalStateWatcher.shouldAdopt(file: s, current: c.state,
                                                   lastSaved: self.lastSaved)
            else { return }
            c.restoreState(s)
            self.lastSaved = s
            modelLog.notice("reloaded state changed externally")
            DispatchQueue.main.async { self.publish(s) }
        }
    }

    /// Run a hardware operation on the serial write queue; report failure
    /// back on the main thread. UI state is updated optimistically by the
    /// caller so faders stay responsive while transactions drain. State is
    /// auto-saved (coalesced) after each change.
    func hw(_ key: String, _ failMsg: String = "write failed",
            _ work: @escaping (FirefaceController) -> Bool) {
        guard ctl != nil else {
            lastError = "not connected — change not applied"
            return
        }
        hwq.submit(key) { [weak self] in
            guard let self, let c = self.ctl else { return }
            if !work(c) {
                DispatchQueue.main.async { self.lastError = failMsg }
            }
            self.hwq.submit("save") { c.saveState(); self.lastSaved = c.state }
        }
    }

    private func idx(_ src: Int, _ dest: Int) -> Int { MixerState.index(src: src, dest: dest) }

    // MARK: - Input sends (input -> monitor bus pair, stereo linked)

    public func inputSend(_ src: Int) -> UInt32 {
        input[idx(src, busPairs[monitorBus].a)]
    }

    public func syncBusPair() {
        let p = busPairs[monitorBus]
        hw("bus") { c in c.setBusPair(a: p.a, b: p.b) }
    }

    public func setInputSend(_ src: Int, gain: UInt32) {
        let pair = busPairs[monitorBus]
        input[idx(src, pair.a)] = gain
        input[idx(src, pair.b)] = gain
        hw("send.\(src)", "send write failed") { c in
            var ok = c.setInputFader(src: src, dest: pair.a, gain: gain)
            ok = c.setInputFader(src: src, dest: pair.b, gain: gain) && ok
            return ok
        }
    }

    public func setInputMute(_ src: Int, on: Bool) {
        inputMute[src] = on
        hw("imute.\(src)") { c in c.setInputMute(src: src, on: on) }
    }

    public func setInputPhase(_ src: Int, on: Bool) {
        inputPhase[src] = on
        hw("iphase.\(src)") { c in c.setInputPhase(src: src, on: on) }
    }

    public func setInputSolo(_ src: Int, on: Bool) {
        for i in 0..<18 { inputSolo[i] = (i == src) && on }
        hw("solo") { c in c.setInputSolo(src: src, on: on) }
    }

    public func setOutputMute(_ ch: Int, on: Bool) {
        outputMute[ch] = on
        hw("omute.\(ch)") { c in c.setOutputMute(ch: ch, on: on) }
    }

    public func setMono(_ on: Bool) {
        monoBus = on
        hw("mono") { c in c.setMonoBus(on: on) }
    }

    public func inputSendDB(_ src: Int) -> Double {
        Fireface400.db(fromGain: inputSend(src))
    }

    // MARK: - Matrix cells

    public func toggleInput(src: Int, dest: Int) {
        let newVal: UInt32 = input[idx(src, dest)] == 0 ? Fireface400.unityGain : 0
        input[idx(src, dest)] = newVal
        hw("cell.i.\(src).\(dest)") { c in c.setInputFader(src: src, dest: dest, gain: newVal) }
    }

    public func togglePlayback(src: Int, dest: Int) {
        let newVal: UInt32 = playback[idx(src, dest)] == 0 ? Fireface400.unityGain : 0
        playback[idx(src, dest)] = newVal
        hw("cell.p.\(src).\(dest)") { c in c.setPlaybackFader(src: src, dest: dest, gain: newVal) }
    }

    // MARK: - Outputs

    // MARK: - Drag previews (hardware write only — no @Published churn)

    /// Live output-fader preview during a drag. Uses the same coalescing
    /// keys as `setOutput` so the commit on release lands cleanly.
    public func previewOutput(_ ch: Int, gain: UInt32) {
        let peer = ch ^ 1, linked = outputStereo[ch / 2]
        hw("out.\(ch)") { c in c.setOutputFader(ch: ch, gain: gain) }
        if linked {
            hw("out.\(peer)") { c in c.setOutputFader(ch: peer, gain: gain) }
        }
    }

    public func previewInputSend(_ src: Int, gain: UInt32) {
        let pair = busPairs[monitorBus]
        hw("send.\(src)", "send write failed") { c in
            var ok = c.setInputFader(src: src, dest: pair.a, gain: gain)
            ok = c.setInputFader(src: src, dest: pair.b, gain: gain) && ok
            return ok
        }
    }

    public func previewMicGain(_ i: Int, dB: Double) {
        let idx = i == 0 ? Fireface400.AmpGain.mic1.rawValue : Fireface400.AmpGain.mic2.rawValue
        hw("mic.\(i)") { c in c.setAmpGain(index: idx, dB: dB) }
    }

    public func previewInGain(_ i: Int, dB: Double) {
        let idx = i == 0 ? Fireface400.AmpGain.input3.rawValue : Fireface400.AmpGain.input4.rawValue
        hw("ingain.\(i)") { c in c.setAmpGain(index: idx, dB: dB) }
    }

    // MARK: - MAIN row (one control for a stereo output pair)

    /// Drag preview for the MAIN slider — hardware writes only.
    public func previewMain(pair: Int, gain: UInt32) {
        let l = pair * 2, r = l + 1
        hw("out.\(l)") { c in c.setOutputFader(ch: l, gain: gain) }
        hw("out.\(r)") { c in c.setOutputFader(ch: r, gain: gain) }
    }

    public func setMain(pair: Int, gain: UInt32) {
        let l = pair * 2, r = l + 1
        output[l] = gain
        output[r] = gain
        hw("out.\(l)") { c in c.setOutputFader(ch: l, gain: gain) }
        hw("out.\(r)") { c in c.setOutputFader(ch: r, gain: gain) }
    }

    public func setMainMute(pair: Int, on: Bool) {
        let l = pair * 2, r = l + 1
        outputMute[l] = on
        outputMute[r] = on
        hw("mainmute.\(pair)") { c in c.setPairMute(pair: pair, on: on) }
    }

    public func setOutput(_ ch: Int, gain: UInt32) {
        output[ch] = gain
        let peer = ch ^ 1, linked = outputStereo[ch / 2]
        if linked { output[peer] = gain }
        hw("out.\(ch)") { c in c.setOutputFader(ch: ch, gain: gain) }
        if linked {
            hw("out.\(peer)") { c in c.setOutputFader(ch: peer, gain: gain) }
        }
    }

    /// TotalMix-style stereo button: a linked pair moves as one fader.
    public func setStereoPair(_ pair: Int, on: Bool) {
        outputStereo[pair] = on
        if on {
            // adopt L's fader value for both, like TotalMix
            let g = output[pair * 2]
            output[pair * 2 + 1] = g
            hw("out.\(pair * 2 + 1)") { c in c.setOutputFader(ch: pair * 2 + 1, gain: g) }
        }
        hw("stereo.\(pair)") { c in c.setOutputStereo(pair: pair, on: on) }
    }

    public func outputDB(_ ch: Int) -> Double { Fireface400.db(fromGain: output[ch]) }

    // MARK: - Hardware preamp gains (only inputs 1-4 have them)

    public func setMicGain(_ i: Int, dB: Double) {
        micGain[i] = dB
        let idx = i == 0 ? Fireface400.AmpGain.mic1.rawValue : Fireface400.AmpGain.mic2.rawValue
        hw("mic.\(i)") { c in c.setAmpGain(index: idx, dB: dB) }
    }

    public func setInGain(_ i: Int, dB: Double) {
        inGain[i] = dB
        let idx = i == 0 ? Fireface400.AmpGain.input3.rawValue : Fireface400.AmpGain.input4.rawValue
        hw("ingain.\(i)") { c in c.setAmpGain(index: idx, dB: dB) }
    }

    public func setPhantom(_ i: Int, on: Bool) {
        phantom[i] = on
        hw("cfg.phantom.\(i)", "config write failed") { c in c.setPhantom(ch: i, on: on) }
    }

    public func setPad(_ i: Int, on: Bool) {
        pad[i] = on
        hw("cfg.pad.\(i)", "config write failed") { c in c.setPad(ch: i + 2, on: on) }
    }

    public func setInstr(_ i: Int, on: Bool) {
        instr[i] = on
        hw("cfg.instr.\(i)", "config write failed") { c in c.setInstrument(ch: i + 2, on: on) }
    }

    // MARK: - Bulk

    public func applyAll() {
        hwq.submit("apply") { [weak self] in
            guard let self, let r = self.ctl?.applyAll() else { return }
            let s = self.ctl?.state
            DispatchQueue.main.async {
                self.lastError = r.failed == 0 ? nil : "\(r.failed) writes failed"
                if let s { self.input = s.input; self.playback = s.playback; self.output = s.output }
            }
        }
    }

    public func save() {
        hwq.submit("save") { [weak self] in
            guard let c = self?.ctl else { return }
            c.saveState(); self?.lastSaved = c.state
        }
    }

    // MARK: - Detached window

    /// Detach button: close the popover and open the persistent window
    /// (the window itself is owned by the app's DetachWindowController).
    public func openDetached() {
        onDetach?()
        onOpenDetached?()
    }
}
