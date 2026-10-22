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

final class MixerModel: ObservableObject {
    @Published var connected = false
    @Published var lastError: String?
    @Published var matrixTab = 0          // 0 = inputs, 1 = playback
    @Published var monitorBus = 0         // index into busPairs
    @Published var input: [UInt32]
    @Published var playback: [UInt32]
    @Published var output: [UInt32]
    @Published var micGain: [Double] = [0, 0]
    @Published var inGain: [Double] = [0, 0]

    private var ctl: FirefaceController?

    init() {
        let s = MixerState.load()
        input = s.input
        playback = s.playback
        output = s.output
        do {
            let c = try FirefaceController()
            ctl = c
            connected = true
        } catch {
            lastError = "\(error)"
        }
    }

    private func idx(_ src: Int, _ dest: Int) -> Int { MixerState.index(src: src, dest: dest) }

    // MARK: - Input sends (input -> monitor bus pair, stereo linked)

    func inputSend(_ src: Int) -> UInt32 {
        input[idx(src, busPairs[monitorBus].a)]
    }

    func setInputSend(_ src: Int, gain: UInt32) {
        let pair = busPairs[monitorBus]
        var ok = false
        if ctl?.setInputFader(src: src, dest: pair.a, gain: gain) ?? false {
            input[idx(src, pair.a)] = gain; ok = true
        }
        if ctl?.setInputFader(src: src, dest: pair.b, gain: gain) ?? false {
            input[idx(src, pair.b)] = gain; ok = true
        }
        if !ok { lastError = "send write failed" }
    }

    func inputSendDB(_ src: Int) -> Double {
        Fireface400.db(fromGain: inputSend(src))
    }

    // MARK: - Matrix cells

    func toggleInput(src: Int, dest: Int) {
        let newVal: UInt32 = input[idx(src, dest)] == 0 ? Fireface400.unityGain : 0
        if ctl?.setInputFader(src: src, dest: dest, gain: newVal) ?? false {
            input[idx(src, dest)] = newVal
        } else { lastError = "write failed" }
    }

    func togglePlayback(src: Int, dest: Int) {
        let newVal: UInt32 = playback[idx(src, dest)] == 0 ? Fireface400.unityGain : 0
        if ctl?.setPlaybackFader(src: src, dest: dest, gain: newVal) ?? false {
            playback[idx(src, dest)] = newVal
        } else { lastError = "write failed" }
    }

    // MARK: - Outputs

    func setOutput(_ ch: Int, gain: UInt32) {
        if ctl?.setOutputFader(ch: ch, gain: gain) ?? false {
            output[ch] = gain
        } else { lastError = "write failed" }
    }

    func outputDB(_ ch: Int) -> Double { Fireface400.db(fromGain: output[ch]) }

    // MARK: - Hardware preamp gains (only inputs 1-4 have them)

    func setMicGain(_ i: Int, dB: Double) {
        let idx = i == 0 ? Fireface400.AmpGain.mic1.rawValue : Fireface400.AmpGain.mic2.rawValue
        if ctl?.setAmpGain(index: idx, dB: dB) ?? false { micGain[i] = dB }
        else { lastError = "write failed" }
    }

    func setInGain(_ i: Int, dB: Double) {
        let idx = i == 0 ? Fireface400.AmpGain.input3.rawValue : Fireface400.AmpGain.input4.rawValue
        if ctl?.setAmpGain(index: idx, dB: dB) ?? false { inGain[i] = dB }
        else { lastError = "write failed" }
    }

    // MARK: - Bulk

    func applyAll() {
        let r = ctl?.applyAll()
        if let r { lastError = r.failed == 0 ? nil : "\(r.failed) writes failed" }
        if let s = ctl?.state { input = s.input; playback = s.playback; output = s.output }
    }

    func save() { ctl?.saveState() }
}
