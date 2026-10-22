import SwiftUI
import AppKit
import OSLog
import ServiceManagement
import CoreAudio
import FFCore

private let trayLog = Logger(subsystem: "net.holms.fftray", category: "ui")

@main
struct FFTrayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Persistent status item + popover live in AppDelegate — the
        // panel is built once, not per-click like MenuBarExtra(.window).
        Settings { EmptyView() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = MixerModel()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let t0 = Date()
        let hosting = NSHostingController(
            rootView: ContentView().environmentObject(model))
        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = false
        pop.appearance = NSAppearance(named: .darkAqua)
        pop.contentViewController = hosting
        // Prewarm: size + lay out the whole view once at launch so even
        // the first click is fast. `ms` is what MenuBarExtra paid per open.
        hosting.view.frame = NSRect(origin: .zero, size: hosting.view.fittingSize)
        hosting.view.layoutSubtreeIfNeeded()
        pop.contentSize = hosting.view.fittingSize
        popover = pop

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = item.button {
            b.image = NSImage(systemSymbolName: "slider.horizontal.3",
                              accessibilityDescription: "FF400")
            b.imagePosition = .imageLeading
            b.title = "FF400"
            b.target = self
            b.action = #selector(togglePopover)
        }
        statusItem = item
        model.onDetach = { [weak pop] in pop?.performClose(nil) }
        trayLog.notice("panel built in \(Date().timeIntervalSince(t0) * 1000, privacy: .public) ms")
    }

    @objc private func togglePopover() {
        guard let pop = popover, let button = statusItem.button else { return }
        if pop.isShown {
            pop.performClose(nil)
        } else {
            pop.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
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
    /// Mirrors SMAppService.mainApp.status; re-read after every toggle.
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    /// Re-apply the saved mix when the FF400 reappears after a power
    /// cycle (mixer RAM is volatile). Persisted in UserDefaults.
    @Published var autoReapply =
        UserDefaults.standard.object(forKey: "autoReapply") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoReapply, forKey: "autoReapply") }
    }

    private var ctl: FirefaceController?
    private let hwq = WriteCoalescer()
    /// Watches the state.json directory for writes by ffctl (atomic saves
    /// replace the file, so the directory is watched, not the file).
    private var stateWatcher: DispatchSourceFileSystemObject?
    private var stateWatcherFD: Int32 = -1
    private var reloadScheduled = false
    /// State at our own most recent save. Touched ONLY on the hw queue —
    /// lets the file watcher tell our autosaves (and files read while a
    /// newer save is still queued behind the reload) from real external
    /// changes.
    private var lastSaved: MixerState?
    /// Called when the detached window opens — AppDelegate closes the
    /// popover so the mixer isn't shown in two places.
    var onDetach: (() -> Void)?
    /// CoreAudio device-list listener + edge detector for auto re-apply.
    private var deviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var presenceTracker: DevicePresence.Tracker?

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
            publish(c.state)
            lastSaved = c.state
        } catch {
            lastError = "\(error)"
        }
        watchStateFile()
        watchDevicePresence()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appWillTerminate),
            name: NSApplication.willTerminateNotification, object: nil)
    }

    deinit {
        stateWatcher?.cancel()
        if let block = deviceListenerBlock {
            var addr = Self.devicesAddress
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &addr,
                DispatchQueue.main, block)
        }
    }

    private static var devicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// True when any CoreAudio device name matches the Fireface 400.
    private static func firefacePresent() -> Bool {
        var addr = devicesAddress
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr
        else { return false }
        var ids = [AudioDeviceID](repeating: 0,
                                count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr
        else { return false }
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        for id in ids {
            var name: CFString = "" as CFString
            var ns = UInt32(MemoryLayout<CFString>.size)
            if AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &ns, &name) == noErr,
               DevicePresence.isFireface400(name: name as String) { return true }
        }
        return false
    }

    /// Watch the CoreAudio device list; an absent→present edge on the
    /// FF400 means a power cycle wiped the mixer RAM, so re-apply (after
    /// a short settle delay) when autoReapply is on.
    private func watchDevicePresence() {
        presenceTracker = DevicePresence.Tracker(present: Self.firefacePresent())
        var addr = Self.devicesAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            guard self.presenceTracker?.update(present: Self.firefacePresent()) == true,
                  self.autoReapply else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self else { return }
                self.applyAll()
                trayLog.notice("FF400 reappeared — re-applied mix")
            }
        }
        deviceListenerBlock = block
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, DispatchQueue.main, block)
    }

    /// Register/unregister FFTray as a login item (macOS 13+ SMAppService).
    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            lastError = "launch at login: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Push a MixerState into every @Published property.
    private func publish(_ s: MixerState) {
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
            guard s != c.state, s != self.lastSaved else { return }
            c.restoreState(s)
            self.lastSaved = s
            trayLog.notice("reloaded state changed externally")
            DispatchQueue.main.async { self.publish(s) }
        }
    }

    /// Flush pending writes and persist state before the process exits.
    @objc private func appWillTerminate(_ note: Notification) {
        hwq.waitUntilIdle()
        if let c = ctl { c.saveState(); lastSaved = c.state }
    }

    /// Run a hardware operation on the serial write queue; report failure
    /// back on the main thread. UI state is updated optimistically by the
    /// caller so faders stay responsive while transactions drain. State is
    /// auto-saved (coalesced) after each change.
    private func hw(_ key: String, _ failMsg: String = "write failed",
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
        hw("mono") { c in c.setMonoBus(on: on) }
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

    // MARK: - Drag previews (hardware write only — no @Published churn)

    /// Live output-fader preview during a drag. Uses the same coalescing
    /// keys as `setOutput` so the commit on release lands cleanly.
    func previewOutput(_ ch: Int, gain: UInt32) {
        let peer = ch ^ 1, linked = outputStereo[ch / 2]
        hw("out.\(ch)") { c in c.setOutputFader(ch: ch, gain: gain) }
        if linked {
            hw("out.\(peer)") { c in c.setOutputFader(ch: peer, gain: gain) }
        }
    }

    func previewInputSend(_ src: Int, gain: UInt32) {
        let pair = busPairs[monitorBus]
        hw("send.\(src)", "send write failed") { c in
            var ok = c.setInputFader(src: src, dest: pair.a, gain: gain)
            ok = c.setInputFader(src: src, dest: pair.b, gain: gain) && ok
            return ok
        }
    }

    func previewMicGain(_ i: Int, dB: Double) {
        let idx = i == 0 ? Fireface400.AmpGain.mic1.rawValue : Fireface400.AmpGain.mic2.rawValue
        hw("mic.\(i)") { c in c.setAmpGain(index: idx, dB: dB) }
    }

    func previewInGain(_ i: Int, dB: Double) {
        let idx = i == 0 ? Fireface400.AmpGain.input3.rawValue : Fireface400.AmpGain.input4.rawValue
        hw("ingain.\(i)") { c in c.setAmpGain(index: idx, dB: dB) }
    }

    // MARK: - MAIN row (one control for a stereo output pair)

    /// Drag preview for the MAIN slider — hardware writes only.
    func previewMain(pair: Int, gain: UInt32) {
        let l = pair * 2, r = l + 1
        hw("out.\(l)") { c in c.setOutputFader(ch: l, gain: gain) }
        hw("out.\(r)") { c in c.setOutputFader(ch: r, gain: gain) }
    }

    func setMain(pair: Int, gain: UInt32) {
        let l = pair * 2, r = l + 1
        output[l] = gain
        output[r] = gain
        hw("out.\(l)") { c in c.setOutputFader(ch: l, gain: gain) }
        hw("out.\(r)") { c in c.setOutputFader(ch: r, gain: gain) }
    }

    func setMainMute(pair: Int, on: Bool) {
        let l = pair * 2, r = l + 1
        outputMute[l] = on
        outputMute[r] = on
        hw("mainmute.\(pair)") { c in c.setPairMute(pair: pair, on: on) }
    }

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
        hwq.submit("save") { [weak self] in
            guard let c = self?.ctl else { return }
            c.saveState(); self?.lastSaved = c.state
        }
    }

    // MARK: - Detached window

    private var detachedWindow: NSWindow?

    /// Open the same UI in a persistent titled window that survives focus
    /// changes (the menu-bar panel auto-closes whenever it loses focus).
    func openDetached() {
        onDetach?()
        if detachedWindow == nil {
            let host = NSHostingController(
                rootView: ContentView(detached: true).environmentObject(self))
            let w = NSWindow(contentViewController: host)
            w.title = "Fireface 400 Mixer"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 660,
                                      height: host.view.fittingSize.height)
            w.delegate = self
            w.center()
            detachedWindow = w
            // Make the window Cmd-Tab reachable while it's open.
            NSApp.setActivationPolicy(.regular)
        }
        detachedWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension MixerModel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === detachedWindow {
            detachedWindow = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
