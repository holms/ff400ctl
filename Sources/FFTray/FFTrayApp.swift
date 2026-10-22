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

final class MixerModel: ObservableObject {
    @Published var connected = false
    @Published var lastError: String?
    @Published var matrixTab = 0          // 0 = inputs, 1 = playback
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

    func toggleInput(src: Int, dest: Int) {
        let newVal: UInt32 = input[idx(src, dest)] == 0 ? Fireface400.unityGain : 0
        if ctl?.setInputFader(src: src, dest: dest, gain: newVal) ?? false {
            input[idx(src, dest)] = newVal
        }
    }

    func togglePlayback(src: Int, dest: Int) {
        let newVal: UInt32 = playback[idx(src, dest)] == 0 ? Fireface400.unityGain : 0
        if ctl?.setPlaybackFader(src: src, dest: dest, gain: newVal) ?? false {
            playback[idx(src, dest)] = newVal
        }
    }

    func setOutput(_ ch: Int, gain: UInt32) {
        if ctl?.setOutputFader(ch: ch, gain: gain) ?? false {
            output[ch] = gain
        }
    }

    func setMicGain(_ i: Int, dB: Double) {
        let idx = i == 0 ? Fireface400.AmpGain.mic1.rawValue : Fireface400.AmpGain.mic2.rawValue
        if ctl?.setAmpGain(index: idx, dB: dB) ?? false { micGain[i] = dB }
    }

    func setInGain(_ i: Int, dB: Double) {
        let idx = i == 0 ? Fireface400.AmpGain.input3.rawValue : Fireface400.AmpGain.input4.rawValue
        if ctl?.setAmpGain(index: idx, dB: dB) ?? false { inGain[i] = dB }
    }

    func applyAll() {
        let r = ctl?.applyAll()
        if let r { lastError = r.failed == 0 ? nil : "\(r.failed) writes failed" }
        let s = ctl?.state
        if let s { input = s.input; playback = s.playback; output = s.output }
    }

    func save() { ctl?.saveState() }
}
