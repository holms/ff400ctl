import SwiftUI
import FFCore
import FFModel

private let cellSize: CGFloat = 26
private let faderColW: CGFloat = 40
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
    var fontSize: CGFloat = 11
    let onCommit: (String) -> Void
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: fontSize, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.text)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { f in if !f { commit() } }
            } else {
                label
                    .font(.system(size: fontSize, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        draft = text.replacingOccurrences(of: "dB", with: "")
                            .replacingOccurrences(of: "−", with: "-")
                            .replacingOccurrences(of: "-∞", with: "-90")
                            .replacingOccurrences(of: "∞", with: "-90")
                            .trimmingCharacters(in: .whitespaces)
                        editing = true
                        focused = true
                    }
            }
        }
        .frame(width: width, height: 14)
    }

    /// The monospaced ∞ glyph is tiny next to digits — draw it in the
    /// proportional system font at a larger size so "-∞" reads like "0.0".
    private var label: Text {
        guard let r = text.range(of: "∞") else { return Text(text) }
        return Text(text[..<r.lowerBound])
            + Text("∞").font(.system(size: fontSize * 1.45, weight: .medium))
            + Text(text[r.upperBound...])
    }

    private func commit() {
        if editing { onCommit(draft) }
        editing = false
    }
}

/// One channel's live level for the bar next to a fader.
struct MeterBarData {
    let db: Double
    let clip: Bool
}

/// Slim vertical level bar: -60..0 dBFS, green→yellow→red, red cap on
/// overload (device clip flag or a nearly-full reading).
struct MeterBar: View {
    let data: MeterBarData
    private static let span: Double = 60

    var body: some View {
        GeometryReader { g in
            let h = g.size.height
            let frac = data.db.isFinite
                ? min(1, max(0, (data.db + Self.span) / Self.span)) : 0
            ZStack {
                RoundedRectangle(cornerRadius: 2).fill(Theme.offCell)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(LinearGradient(colors: [.green, .yellow, .red],
                                             startPoint: .bottom, endPoint: .top))
                        .frame(height: frac * h)
                }
                if data.clip || data.db > -1 {
                    VStack(spacing: 0) {
                        RoundedRectangle(cornerRadius: 1).fill(Color.red)
                            .frame(height: 3)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}

/// One vertical fader column: meter bar(s) + travel slider + name +
/// editable value. During a drag the slider position lives in `live`
/// (view-local), so a fast drag doesn't republish the model and
/// re-render the whole panel per tick; `onLive` still fires a coalesced
/// hardware preview write. The model is committed once, on release,
/// through `value`'s setter.
struct VFader: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    let format: (Double) -> String
    let onLive: (Double) -> Void
    let onText: (String) -> Void
    var colWidth: CGFloat = faderColW
    /// 0–2 live meter bars drawn beside the slider.
    var meters: [MeterBarData] = []
    @State private var live: Double?

    private var meterWidth: CGFloat {
        meters.isEmpty ? 0 : CGFloat(meters.count) * 5 + 4
    }

    private var dragBinding: Binding<Double> {
        Binding(get: { live ?? value }, set: { live = $0; onLive($0) })
    }

    private func commit(_ editing: Bool) {
        if !editing, let v = live { value = v; live = nil }
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                ForEach(Array(meters.enumerated()), id: \.offset) { _, m in
                    MeterBar(data: m).frame(width: 5, height: faderTravel)
                }
                ZStack {
                    if let step {
                        Slider(value: dragBinding, in: range, step: step,
                               onEditingChanged: commit)
                    } else {
                        Slider(value: dragBinding, in: range,
                               onEditingChanged: commit)
                    }
                }
                .frame(width: faderTravel)
                .rotationEffect(.degrees(-90))
                .frame(width: colWidth - 6, height: faderTravel)
            }

            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.leading, meterWidth)
            EditableValue(text: format(live ?? value), width: colWidth - 2, onCommit: onText)
                .padding(.leading, meterWidth)
        }
        .frame(width: colWidth + meterWidth)
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
    /// Which stereo output pair the MAIN row drives (persisted per user).
    @AppStorage("mainPair") private var mainPair = 0
    /// True when hosted in the detached NSWindow (hides Detach/Quit buttons).
    var detached = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            mainRow
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
            .equatable()

            inputSendStrip
            outputStrip
            preampStrip
            footer
        }
        .padding(12)
        .frame(minWidth: 660, maxWidth: detached ? .infinity : 660,
               alignment: .topLeading)
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

    /// MAIN volume — one prominent slider driving a stereo output pair.
    private var mainRow: some View {
        let l = mainPair * 2, r = l + 1
        return HStack(spacing: 10) {
            Text("MAIN")
                .font(.system(size: 13, weight: .bold, design: .monospaced))
                .foregroundStyle(Theme.text)
            Picker("Pair", selection: $mainPair) {
                ForEach(0..<busPairs.count, id: \.self) { i in
                    Text(busPairs[i].name).tag(i)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 100)
            MainSlider(
                gain: model.output[l],
                onCommit: { model.setMain(pair: mainPair, gain: $0) },
                onLive: { model.previewMain(pair: mainPair, gain: $0) },
                onText: { t in
                    if let db = parseDB(t) {
                        model.setMain(pair: mainPair, gain: Fireface400.gain(fromDB: db))
                    }
                })
            FlagButton("M", on: model.outputMute[l] && model.outputMute[r],
                       color: .orange) {
                model.setMainMute(pair: mainPair,
                                  on: !(model.outputMute[l] && model.outputMute[r]))
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
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(alignment: .top, spacing: 2) {
                    ForEach(0..<Fireface400.channelCount, id: \.self) { src in
                        VFader(
                            title: "\(src + 1)",
                            value: Binding(
                                get: { Double(model.inputSend(src)) / Double(Fireface400.unityGain) },
                                set: { model.setInputSend(src, gain: UInt32(clamping: Int(($0 * Double(Fireface400.unityGain)).rounded()))) }
                            ),
                            range: 0...2,
                            format: { fmtDB(Fireface400.db(fromGain: UInt32(clamping: Int(($0 * Double(Fireface400.unityGain)).rounded())))) },
                            onLive: { model.previewInputSend(src, gain: UInt32(clamping: Int(($0 * Double(Fireface400.unityGain)).rounded()))) },
                            onText: { t in
                                if let db = parseDB(t) {
                                    model.setInputSend(src, gain: Fireface400.gain(fromDB: db))
                                }
                            },
                            meters: [MeterBarData(db: model.meters.physIn[src],
                                                  clip: model.meters.physInClip[src])])
                        VStack(spacing: 3) {
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
                        .padding(.top, 30)
                    }
                }
                .padding(.vertical, 2)
                .padding(.trailing, 8)
                .padding(.bottom, 6)
            }
            Text("row 1-4 = front jacks · 5-8 = rear line · 9-10 = SPDIF · 11-18 = ADAT")
                .font(.system(size: 10, design: .monospaced))
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
                format: { fmtDB(Fireface400.db(fromGain: UInt32(clamping: Int(($0 * Double(Fireface400.unityGain)).rounded())))) },
                onLive: { model.previewOutput(ch, gain: UInt32(clamping: Int(($0 * Double(Fireface400.unityGain)).rounded()))) },
                onText: { t in
                    if let db = parseDB(t) {
                        model.setOutput(ch, gain: Fireface400.gain(fromDB: db))
                    }
                },
                meters: [MeterBarData(db: model.meters.physOut[ch],
                                      clip: model.meters.physOutClip[ch])])
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
            ScrollView(.horizontal, showsIndicators: true) {
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
                                        format: { fmtDB(Fireface400.db(fromGain: UInt32(clamping: Int(($0 * Double(Fireface400.unityGain)).rounded())))) },
                                        onLive: { model.previewOutput(l, gain: UInt32(clamping: Int(($0 * Double(Fireface400.unityGain)).rounded()))) },
                                        onText: { t in
                                            if let db = parseDB(t) {
                                                model.setOutput(l, gain: Fireface400.gain(fromDB: db))
                                            }
                                        },
                                        meters: [
                                            MeterBarData(db: model.meters.physOut[l],
                                                         clip: model.meters.physOutClip[l]),
                                            MeterBarData(db: model.meters.physOut[r],
                                                         clip: model.meters.physOutClip[r]),
                                        ])
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
                .padding(.trailing, 8)
                .padding(.bottom, 6)
            }
            Text("1-6 = analog · 7-8 = phones · 9-10 = SPDIF · 11-18 = ADAT · ST links a pair into one fader")
                .font(.system(size: 10, design: .monospaced))
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
                            format: { String(format: "%.0f dB", $0) },
                            onLive: { model.previewMicGain(i, dB: $0) },
                            onText: { t in if let db = parseDB(t) { model.setMicGain(i, dB: db) } },
                            colWidth: 64,
                            meters: [MeterBarData(db: model.meters.physIn[i],
                                                  clip: model.meters.physInClip[i])])
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
                            format: { String(format: "%.1f dB", $0) },
                            onLive: { model.previewInGain(i, dB: $0) },
                            onText: { t in if let db = parseDB(t) { model.setInGain(i, dB: db) } },
                            colWidth: 64,
                            meters: [MeterBarData(db: model.meters.physIn[i + 2],
                                                  clip: model.meters.physInClip[i + 2])])
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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Button("Re-apply mix") { model.applyAll() }
                Button("Save state") { model.save() }
                if !detached {
                    Button("Detach") { model.openDetached() }
                }
                Spacer()
                Text("v\(FFVersion.string)")
                    .font(.caption2).foregroundStyle(Theme.secondary)
                if !detached {
                    Button("Quit") { NSApplication.shared.terminate(nil) }
                }
            }
            HStack(spacing: 12) {
                Toggle("Meters", isOn: $model.metersOn)
                    .toggleStyle(.checkbox)
                Toggle("Auto re-apply after power cycle", isOn: $model.autoReapply)
                    .toggleStyle(.checkbox)
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }))
                    .toggleStyle(.checkbox)
                Spacer()
                Text(model.autoReapply
                     ? "mix is re-applied automatically after power cycle"
                     : "mixer RAM is volatile — re-apply after power cycle")
                    .foregroundStyle(model.autoReapply ? Theme.secondary : .orange)
            }
            .font(.caption2).foregroundStyle(Theme.secondary)
        }
        .buttonStyle(.borderless)
        .font(.caption)
    }
}

/// Horizontal main-volume slider: drag state stays view-local (preview
/// writes via onLive), commit through the model on release — same pattern
/// as VFader. Travel maps linearly over -60…+6 dB, bottom = mute.
private struct MainSlider: View {
    let gain: UInt32
    let onCommit: (UInt32) -> Void
    let onLive: (UInt32) -> Void
    let onText: (String) -> Void
    @State private var live: Double?

    var body: some View {
        HStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { live ?? Fireface400.mainSliderPos(gain) },
                    set: { live = $0; onLive(Fireface400.mainSliderGain($0)) }),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing, let p = live {
                        onCommit(Fireface400.mainSliderGain(p))
                        live = nil
                    }
                })
            EditableValue(
                text: fmtDB(Fireface400.db(fromGain:
                    live.map { Fireface400.mainSliderGain($0) } ?? gain)),
                width: 44, fontSize: 13, onCommit: onText)
        }
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
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .frame(minWidth: 26)
                .padding(.horizontal, 4).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 4)
                    .fill(on ? color.opacity(0.9) : Theme.offCell))
                .foregroundStyle(on ? .black : Theme.secondary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MatrixView: View, Equatable {
    static func == (l: MatrixView, r: MatrixView) -> Bool {
        l.cells == r.cells && l.rowNames == r.rowNames && l.onColor == r.onColor
    }
    let cells: [UInt32]
    let rowNames: [String]
    let onColor: Color
    let onToggle: (Int, Int) -> Void

    private let n = Fireface400.channelCount
    private let cellH: CGFloat = 18
    private let gap: CGFloat = 2

    private var gridW: CGFloat { CGFloat(n) * (cellSize + gap) - gap }
    private var gridH: CGFloat { CGFloat(n) * (cellH + gap) - gap }

    var body: some View {
        HStack(alignment: .top, spacing: gap) {
            VStack(alignment: .leading, spacing: gap) {
                Text("IN \\ OUT")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                    .frame(width: labelWidth, height: 14, alignment: .leading)
                ForEach(0..<n, id: \.self) { src in
                    Text(rowNames[src])
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: labelWidth, height: cellH, alignment: .leading)
                }
            }
            VStack(alignment: .leading, spacing: gap) {
                HStack(spacing: gap) {
                    ForEach(0..<n, id: \.self) { d in
                        Text("\(d + 1)")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                            .frame(width: cellSize, height: 14)
                    }
                }
                Canvas { ctx, _ in
                    for src in 0..<n {
                        for dest in 0..<n {
                            let i = MixerState.index(src: src, dest: dest)
                            let on = i < cells.count && cells[i] != 0
                            let rect = CGRect(
                                x: CGFloat(dest) * (cellSize + gap) + 2,
                                y: CGFloat(src) * (cellH + gap),
                                width: cellSize - 4, height: cellH)
                            ctx.fill(Path(roundedRect: rect, cornerRadius: 3),
                                     with: .color(on ? onColor : Theme.offCell))
                        }
                    }
                }
                .frame(width: gridW, height: gridH)
                .onTapGesture(coordinateSpace: .local) { p in
                    if let h = MatrixHitTest.cell(at: p.x, y: p.y,
                                                  cellW: cellSize, cellH: cellH,
                                                  gap: gap, count: n) {
                        onToggle(h.row, h.col)
                    }
                }
            }
        }
    }
}
