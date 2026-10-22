import SwiftUI
import FFCore

private let cellSize: CGFloat = 26
private let faderColW: CGFloat = 30
private let faderTravel: CGFloat = 96
private let labelWidth: CGFloat = 56

/// ASFW "Studio Dark" palette.
private enum Theme {
    static let bg        = Color(red: 0.070, green: 0.086, blue: 0.106)
    static let text      = Color.white
    static let secondary = Color(red: 0.72, green: 0.78, blue: 0.84)
    static let inputOn   = Color(red: 0.22, green: 0.78, blue: 0.44)
    static let pbOn      = Color(red: 0.30, green: 0.62, blue: 0.94)
    static let offCell   = Color.white.opacity(0.07)
}

// MARK: - Reusable pieces

/// A dB (or plain number) label you can click to type a new value.
struct EditableValue: View {
    let text: String
    var width: CGFloat = 30
    let onCommit: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 9, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { f in if !f { commit() } }
            } else {
                Text(text)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        draft = text.replacingOccurrences(of: "dB", with: "")
                            .replacingOccurrences(of: "−", with: "-")
                            .replacingOccurrences(of: "∞", with: "-90")
                            .trimmingCharacters(in: .whitespaces)
                        editing = true
                        focused = true
                    }
            }
        }
        .frame(width: width, height: 12)
    }

    private func commit() {
        if editing { onCommit(draft) }
        editing = false
    }
}

/// One vertical fader column: travel slider + name + editable value.
struct VFader: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let display: String
    let onText: (String) -> Void

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                if let step {
                    Slider(value: $value, in: range, step: step)
                } else {
                    Slider(value: $value, in: range)
                }
            }
            .frame(width: faderTravel)
            .rotationEffect(.degrees(-90))
            .frame(width: faderColW - 6, height: faderTravel)

            Text(title)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            EditableValue(text: display, width: faderColW - 2, onCommit: onText)
        }
        .frame(width: faderColW)
    }
}

private func fmtDB(_ db: Double) -> String {
    if !db.isFinite { return "-∞" }
    return String(format: "%.1f", db)
}

private func parseDB(_ s: String) -> Double? {
    var t = s.trimmingCharacters(in: .whitespaces)
        .replacingOccurrences(of: "db", with: "", options: .caseInsensitive)
    t = t.replacingOccurrences(of: ",", with: ".")
    return Double(t)
}

// MARK: - Main view

struct ContentView: View {
    @EnvironmentObject private var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Picker("Matrix", selection: $model.matrixTab) {
                Text("Inputs").tag(0)
                Text("Playback").tag(1)
            }
            .pickerStyle(.segmented)

            MatrixView(
                cells: model.matrixTab == 0 ? model.input : model.playback,
                rowNames: model.matrixTab == 0 ? Fireface400.inputNames : Fireface400.playbackNames,
                onColor: model.matrixTab == 0 ? Theme.inputOn : Theme.pbOn,
                onToggle: { s, d in
                    if model.matrixTab == 0 { model.toggleInput(src: s, dest: d) }
                    else { model.togglePlayback(src: s, dest: d) }
                })

            inputSendStrip
            outputStrip
            preampStrip
            footer
        }
        .padding(12)
        .frame(width: 660)
        .background(Theme.bg)
        .colorScheme(.dark)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.connected ? Color.green : Color.red)
                .frame(width: 8, height: 8)
            Text("Fireface 400")
                .font(.headline)
                .foregroundStyle(Theme.text)
            Text(model.connected ? "node 0xffc0 · live mixer" : "driver not connected")
                .font(.caption.monospaced())
                .foregroundStyle(Theme.secondary)
            Spacer()
            if let e = model.lastError {
                Text(e).font(.caption).foregroundStyle(.orange).lineLimit(1)
            }
        }
    }

    /// INPUT send faders — each input's level into the selected monitor bus pair.
    private var inputSendStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("INPUTS →")
                    .font(.caption2.weight(.semibold)).foregroundStyle(Theme.secondary)
                Picker("Bus", selection: $model.monitorBus) {
                    ForEach(0..<busPairs.count, id: \.self) { i in
                        Text(busPairs[i].name).tag(i)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 110)
                .onChange(of: model.monitorBus) { _ in model.syncBusPair() }
                Text("send level")
                    .font(.caption2).foregroundStyle(Theme.secondary)
                FlagButton("MONO", on: model.monoBus, color: Theme.inputOn) {
                    model.setMono(!model.monoBus)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 2) {
                    ForEach(0..<Fireface400.channelCount, id: \.self) { src in
                        VFader(
                            title: "\(src + 1)",
                            value: Binding(
                                get: { Double(model.inputSend(src)) / Double(Fireface400.unityGain) },
                                set: { model.setInputSend(src, gain: UInt32(clamping: Int(($0 * Double(Fireface400.unityGain)).rounded()))) }
                            ),
                            range: 0...2,
                            display: fmtDB(model.inputSendDB(src)),
                            onText: { t in
                                if let db = parseDB(t) {
                                    model.setInputSend(src, gain: Fireface400.gain(fromDB: db))
                                }
                            })
                        VStack(spacing: 2) {
                            FlagButton("M", on: model.inputMute[src], color: .orange) {
                                model.setInputMute(src, on: !model.inputMute[src])
                            }
                            FlagButton("S", on: model.inputSolo[src], color: .yellow) {
                                model.setInputSolo(src, on: !model.inputSolo[src])
                            }
                            FlagButton("Ø", on: model.inputPhase[src], color: Theme.pbOn) {
                                model.setInputPhase(src, on: !model.inputPhase[src])
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Text("row 1-4 = front jacks · 5-8 = rear line · 9-10 = SPDIF · 11-18 = ADAT")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Theme.secondary.opacity(0.7))
        }
    }

    /// One output master fader column (fader + M chip).
    private func outFader(_ ch: Int, title: String) -> some View {
        VStack(spacing: 2) {
            VFader(
                title: title,
                value: Binding(
                    get: { Double(model.output[ch]) / Double(Fireface400.unityGain) },
                    set: { model.setOutput(ch, gain: UInt32(clamping: Int(($0 * Double(Fireface400.unityGain)).rounded()))) }
                ),
                range: 0...2,
                display: fmtDB(model.outputDB(ch)),
                onText: { t in
                    if let db = parseDB(t) {
                        model.setOutput(ch, gain: Fireface400.gain(fromDB: db))
                    }
                })
            FlagButton("M", on: model.outputMute[ch], color: .orange) {
                model.setOutputMute(ch, on: !model.outputMute[ch])
            }
        }
    }

    /// Output master faders, in stereo pairs. The ST chip links a pair
    /// into a single fader, like TotalMix's stereo button.
    private var outputStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OUTPUTS")
                .font(.caption2.weight(.semibold)).foregroundStyle(Theme.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 6) {
                    ForEach(0..<Fireface400.channelCount / 2, id: \.self) { p in
                        let l = p * 2, r = p * 2 + 1
                        HStack(alignment: .top, spacing: 2) {
                            if model.outputStereo[p] {
                                VStack(spacing: 2) {
                                    VFader(
                                        title: "\(l + 1)·\(r + 1)",
                                        value: Binding(
                                            get: { Double(model.output[l]) / Double(Fireface400.unityGain) },
                                            set: { model.setOutput(l, gain: UInt32(clamping: Int(($0 * Double(Fireface400.unityGain)).rounded()))) }
                                        ),
                                        range: 0...2,
                                        display: fmtDB(model.outputDB(l)),
                                        onText: { t in
                                            if let db = parseDB(t) {
                                                model.setOutput(l, gain: Fireface400.gain(fromDB: db))
                                            }
                                        })
                                    HStack(spacing: 2) {
                                        FlagButton("M", on: model.outputMute[l], color: .orange) {
                                            model.setOutputMute(l, on: !model.outputMute[l])
                                        }
                                        FlagButton("M", on: model.outputMute[r], color: .orange) {
                                            model.setOutputMute(r, on: !model.outputMute[r])
                                        }
                                    }
                                }
                            } else {
                                outFader(l, title: "\(l + 1)")
                                outFader(r, title: "\(r + 1)")
                            }
                            FlagButton("ST", on: model.outputStereo[p], color: Theme.pbOn) {
                                model.setStereoPair(p, on: !model.outputStereo[p])
                            }
                            .padding(.top, 40)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            Text("1-6 = analog · 7-8 = phones · 9-10 = SPDIF · 11-18 = ADAT · ST links a pair into one fader")
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(Theme.secondary.opacity(0.7))
        }
    }

    /// Hardware preamp gains — only inputs 1-4 have them on the FF400.
    private var preampStrip: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PREAMP (hardware gain — inputs 1-4 only)")
                .font(.caption2.weight(.semibold)).foregroundStyle(Theme.secondary)
            HStack(alignment: .top, spacing: 10) {
                ForEach(0..<2, id: \.self) { i in
                    VStack(spacing: 3) {
                        VFader(
                            title: "Mic \(i + 1)",
                            value: Binding(
                                get: { model.micGain[i] },
                                set: { model.setMicGain(i, dB: $0) }
                            ),
                            range: 0...65, step: 1,
                            display: String(format: "%.0f dB", model.micGain[i]),
                            onText: { t in if let db = parseDB(t) { model.setMicGain(i, dB: db) } })
                        FlagButton("48V", on: model.phantom[i], color: .yellow) {
                            model.setPhantom(i, on: !model.phantom[i])
                        }
                    }
                }
                ForEach(0..<2, id: \.self) { i in
                    VStack(spacing: 3) {
                        VFader(
                            title: "In \(i + 3)",
                            value: Binding(
                                get: { model.inGain[i] },
                                set: { model.setInGain(i, dB: $0) }
                            ),
                            range: 0...30, step: 0.5,
                            display: String(format: "%.1f dB", model.inGain[i]),
                            onText: { t in if let db = parseDB(t) { model.setInGain(i, dB: db) } })
                        HStack(spacing: 2) {
                            FlagButton("PAD", on: model.pad[i], color: .orange) {
                                model.setPad(i, on: !model.pad[i])
                            }
                            FlagButton("INST", on: model.instr[i], color: Theme.pbOn) {
                                model.setInstr(i, on: !model.instr[i])
                            }
                        }
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button("Re-apply mix") { model.applyAll() }
            Button("Save state") { model.save() }
            Spacer()
            Text("mixer RAM is volatile — re-apply after power cycle")
                .font(.caption2).foregroundStyle(Theme.secondary)
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

/// Small toggle chip used for phantom/pad/instrument flags.
private struct FlagButton: View {
    let title: String
    let on: Bool
    let color: Color
    let action: () -> Void
    init(_ t: String, on: Bool, color: Color, action: @escaping () -> Void) {
        title = t; self.on = on; self.color = color; self.action = action
    }
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 7, weight: .bold, design: .monospaced))
                .padding(.horizontal, 3).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 3)
                    .fill(on ? color.opacity(0.9) : Theme.offCell))
                .foregroundStyle(on ? .black : Theme.secondary)
        }
        .buttonStyle(.plain)
    }
}

private struct MatrixView: View {
    let cells: [UInt32]
    let rowNames: [String]
    let onColor: Color
    let onToggle: (Int, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                Text("IN \\ OUT")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: labelWidth, alignment: .leading)
                ForEach(0..<Fireface400.channelCount, id: \.self) { d in
                    Text("\(d + 1)")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: cellSize)
                }
            }
            ForEach(0..<Fireface400.channelCount, id: \.self) { src in
                HStack(spacing: 2) {
                    Text(rowNames[src])
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: labelWidth, alignment: .leading)
                    ForEach(0..<Fireface400.channelCount, id: \.self) { dest in
                        let i = MixerState.index(src: src, dest: dest)
                        let on = i < cells.count && cells[i] != 0
                        Button { onToggle(src, dest) } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(on ? onColor : Theme.offCell)
                                .frame(width: cellSize - 4, height: 18)
                        }
                        .buttonStyle(.plain)
                        .frame(width: cellSize)
                    }
                }
            }
        }
    }
}
