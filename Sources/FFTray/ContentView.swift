import SwiftUI
import FFCore

private let cellSize: CGFloat = 24
private let labelWidth: CGFloat = 56

/// ASFW "Studio Dark" palette.
private enum Theme {
    static let bg        = Color(red: 0.070, green: 0.086, blue: 0.106)
    static let card      = Color(red: 0.105, green: 0.140, blue: 0.165)
    static let text      = Color.white
    static let secondary = Color(red: 0.72, green: 0.78, blue: 0.84)
    static let accent    = Color(red: 0.30, green: 0.62, blue: 0.94)
    static let inputOn   = Color(red: 0.22, green: 0.78, blue: 0.44)
    static let pbOn      = Color(red: 0.30, green: 0.62, blue: 0.94)
    static let offCell   = Color.white.opacity(0.07)
}

struct ContentView: View {
    @EnvironmentObject private var model: MixerModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Picker("Matrix", selection: $model.matrixTab) {
                Text("Inputs").tag(0)
                Text("Playback").tag(1)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            MatrixView(
                cells: model.matrixTab == 0 ? model.input : model.playback,
                rowNames: model.matrixTab == 0 ? Fireface400.inputNames : Fireface400.playbackNames,
                onColor: model.matrixTab == 0 ? Theme.inputOn : Theme.pbOn,
                onToggle: { s, d in
                    if model.matrixTab == 0 { model.toggleInput(src: s, dest: d) }
                    else { model.togglePlayback(src: s, dest: d) }
                })

            outputFaders
            inputGains
            footer
        }
        .padding(12)
        .frame(width: 640)
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

    private var outputFaders: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("OUTPUT").font(.caption2.weight(.semibold)).foregroundStyle(Theme.secondary)
            HStack(alignment: .top, spacing: 0) {
                Spacer().frame(width: labelWidth)
                ForEach(0..<Fireface400.channelCount, id: \.self) { ch in
                    VStack(spacing: 2) {
                        Slider(value: Binding(
                            get: { Double(model.output[ch]) / Double(Fireface400.unityGain) },
                            set: { model.setOutput(ch, gain: UInt32(clamping: Int(($0 * Double(Fireface400.unityGain)).rounded()))) }
                        ), in: 0...2)
                        .rotationEffect(.degrees(-90))
                        .frame(width: 36, height: 14)
                        .padding(.vertical, 11)
                        Text(String(format: "%d", ch + 1))
                            .font(.system(size: 7, design: .monospaced))
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(width: cellSize + 4)
                }
            }
        }
    }

    private var inputGains: some View {
        HStack(spacing: 20) {
            ForEach(0..<2, id: \.self) { i in
                HStack {
                    Text("Mic \(i + 1)")
                        .font(.caption).foregroundStyle(Theme.secondary)
                    Slider(value: Binding(
                        get: { model.micGain[i] },
                        set: { model.setMicGain(i, dB: $0) }
                    ), in: 0...65, step: 1)
                    Text(String(format: "%.0f dB", model.micGain[i]))
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.text)
                        .frame(width: 44)
                }
            }
            ForEach(0..<2, id: \.self) { i in
                HStack {
                    Text("In \(i + 3)")
                        .font(.caption).foregroundStyle(Theme.secondary)
                    Slider(value: Binding(
                        get: { model.inGain[i] },
                        set: { model.setInGain(i, dB: $0) }
                    ), in: -30...30, step: 0.5)
                    Text(String(format: "%.1f", model.inGain[i]))
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.text)
                        .frame(width: 36)
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

private struct MatrixView: View {
    let cells: [UInt32]
    let rowNames: [String]
    let onColor: Color
    let onToggle: (Int, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // column headers (output numbers)
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
                                .frame(width: cellSize, height: 16)
                        }
                        .buttonStyle(.plain)
                        .frame(width: cellSize)
                    }
                }
            }
            // legend
            HStack(spacing: 16) {
                ForEach([0, 6, 8, 10], id: \.self) { i in
                    Text("\(i + 1)=\(Fireface400.outputNames[i])")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Theme.secondary)
                }
                Text("…10=SPDIF R, 11-18=ADAT").font(.system(size: 8, design: .monospaced)).foregroundStyle(Theme.secondary)
            }
        }
    }
}
