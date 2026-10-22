import Foundation

/// RME Fireface 400 register map and matrix-mixer math.
///
/// The mixer protocol was reverse-engineered by the FFADO project
/// (libffado, src/rme/fireface_hw.cpp). All device registers are
/// little-endian quadlets accessed as node offsets in the low 32 bits
/// of the 1394 address space (addressHigh = 0).
public enum Fireface400 {

    // MARK: - Register map

    /// Live matrix-mixer RAM. One quadlet per crosspoint gain.
    public static let mixerRAM: UInt32 = 0x8008_0000

    /// Bytes per per-output mixer block on the FF400
    /// (18 input cells + 18 playback cells = 36 quadlets = 0x90).
    public static let outputBlockSize: UInt32 = 0x48

    /// Base of the 18 output (master) faders inside mixer RAM.
    public static let outputFaderBase: UInt32 = 0x8008_0f80

    /// Hardware amplifier gain register. Value = (index << 16) | devval.
    public static let gainRegister: UInt32 = 0x801c_0180

    /// Channel mute mask (28 quadlets) — controls PCM fetch mute.
    public static let channelMuteMask: UInt32 = 0x801c_0000

    /// Output record flags (28 quadlets).
    public static let outputRecMask: UInt32 = 0x801c_0080

    public static let channelCount = 18

    // MARK: - Gain conversion

    /// Mixer gain for 0 dB.
    public static let unityGain: UInt32 = 0x8000
    /// Maximum mixer gain (+6 dB).
    public static let maxGain: UInt32 = 0x1_0000

    /// Convert a gain in dB to a mixer quadlet value.
    /// dB = 20 * log10(val / 32768); 0x8000 = 0 dB, 0x10000 = +6 dB, 0 = mute.
    public static func gain(fromDB db: Double) -> UInt32 {
        if db <= -90 { return 0 }
        let v = Int((32768.0 * pow(10.0, db / 20.0)).rounded())
        return UInt32(clamping: v)
    }

    /// Convert a mixer quadlet value back to dB.
    public static func db(fromGain gain: UInt32) -> Double {
        if gain == 0 { return -.infinity }
        return 20.0 * log10(Double(gain) / 32768.0)
    }

    // MARK: - MAIN slider mapping

    /// MAIN fader travel maps linearly over -60…+6 dB; position 0 is mute
    /// (gain 0, -∞ dB). Used by the tray's main volume row.
    public static func mainSliderGain(_ pos: Double) -> UInt32 {
        guard pos > 0 else { return 0 }
        return gain(fromDB: -60 + 66 * min(pos, 1))
    }

    /// Inverse of `mainSliderGain`: gain 0 → 0 (mute), ≥ +6 dB → 1.
    public static func mainSliderPos(_ gain: UInt32) -> Double {
        let dB = db(fromGain: gain)
        guard dB.isFinite else { return 0 }
        return min(max((dB + 60) / 66, 0), 1)
    }

    /// Parse a gain argument: absolute hex (`0x8000`), decimal, dB (`-6dB`),
    /// or a relative dB step (`+3dB` / `-3dB`) applied to `current`.
    /// A relative step on a muted cell (0) starts from -90 dB.
    public static func parseGainArgument(_ s: String, current: UInt32? = nil) -> UInt32? {
        if s.hasSuffix("dB"), let d = Double(s.dropLast(2)) {
            if s.hasPrefix("+") || s.hasPrefix("-"), let current {
                let base = current == 0 ? -90.0 : db(fromGain: current)
                return gain(fromDB: base + d)
            }
            return gain(fromDB: d)
        }
        if s.hasPrefix("0x") || s.hasPrefix("0X") { return UInt32(s.dropFirst(2), radix: 16) }
        return UInt32(s)
    }

    // MARK: - Mixer addressing

    public enum MixKind {
        /// Physical input → output crosspoint.
        case input
        /// Host playback channel → output crosspoint.
        case playback
    }

    /// Address of an input/playback crosspoint cell in mixer RAM.
    ///   input:    base + dest*0x90 + src*4
    ///   playback: base + dest*0x90 + src*4 + 0x48
    public static func mixAddress(kind: MixKind, src: Int, dest: Int) -> UInt32? {
        guard (0..<channelCount).contains(src), (0..<channelCount).contains(dest) else { return nil }
        var addr = mixerRAM &+ UInt32(dest) * 2 * outputBlockSize &+ UInt32(src) * 4
        if kind == .playback { addr &+= outputBlockSize }
        return addr
    }

    /// Address of the output master fader for channel `ch`.
    public static func outputFaderAddress(ch: Int) -> UInt32? {
        guard (0..<channelCount).contains(ch) else { return nil }
        return outputFaderBase &+ UInt32(ch) * 4
    }

    // MARK: - Hardware amp gains (0x801c0180)

    /// Amp gain register indices (FF400 only).
    public enum AmpGain: Int, CaseIterable {
        case mic1 = 0, mic2 = 1, input3 = 2, input4 = 3
        case output1 = 4, output2 = 5, output3 = 6, output4 = 7, output5 = 8, output6 = 9
        case phonesL = 10, phonesR = 11
        case spdif1 = 12, spdif2 = 13
        case adat1 = 14, adat2 = 15, adat3 = 16, adat4 = 17, adat5 = 18, adat6 = 19, adat7 = 20, adat8 = 21
    }

    /// Register value for `gainRegister`: `(index << 16) | devval`.
    ///
    /// - mic 1/2:  `dB` is gain in dB (0–65); below 10 dB selects 0.
    /// - inputs 3/4: device units are 0.5 dB; the caller passes dB.
    /// - outputs/phones/spdif/adat: `dB` is attenuation in whole dB;
    ///   `devval = 6 - round(dB)` (FFADO `set_hardware_ampgain`),
    ///   >0x35 is replaced by 0x3f (mute). 0 dB → 6.
    public static func ampGainValue(index: Int, dB: Double) -> UInt32? {
        guard (0..<22).contains(index) else { return nil }
        let devval: UInt32
        if index <= AmpGain.mic2.rawValue {
            devval = dB >= 10 ? UInt32(min(dB, 65).rounded()) : 0
        } else if index <= AmpGain.input4.rawValue {
            devval = dB.isFinite ? UInt32(clamping: Int((dB * 2).rounded())) : 0
        } else {
            var v = dB.isFinite ? 6 - Int(dB.rounded()) : 0x3f
            if v > 53 { v = 0x3f }            // mute
            if v < 0 { v = 0 }                // device maximum
            devval = UInt32(v)
        }
        return UInt32(index << 16) | (devval & 0xffff)
    }

    /// Inverse of `ampGainValue`: recover dB from a stored devval.
    /// mic → whole dB; inputs 3/4 → 0.5 dB units; outputs → 6 - devval
    /// (0x3f = -inf/mute). Returns nil for an out-of-range index.
    public static func ampGainDB(index: Int, devval: UInt32) -> Double? {
        guard (0..<22).contains(index) else { return nil }
        if index <= AmpGain.mic2.rawValue {
            return Double(devval)
        } else if index <= AmpGain.input4.rawValue {
            return Double(devval) / 2
        } else {
            return devval == 0x3f ? -.infinity : 6 - Double(devval)
        }
    }

    // MARK: - Channel names

    public static let inputNames: [String] = [
        "AN 1", "AN 2", "AN 3", "AN 4", "AN 5", "AN 6", "AN 7", "AN 8",
        "SPDIF L", "SPDIF R",
        "ADAT 1", "ADAT 2", "ADAT 3", "ADAT 4", "ADAT 5", "ADAT 6", "ADAT 7", "ADAT 8",
    ]

    public static let outputNames: [String] = [
        "AN 1", "AN 2", "AN 3", "AN 4", "AN 5", "AN 6",
        "PH L", "PH R",
        "SPDIF L", "SPDIF R",
        "ADAT 1", "ADAT 2", "ADAT 3", "ADAT 4", "ADAT 5", "ADAT 6", "ADAT 7", "ADAT 8",
    ]

    public static let playbackNames: [String] = [
        "SW 1", "SW 2", "SW 3", "SW 4", "SW 5", "SW 6", "SW 7", "SW 8",
        "SW 9", "SW 10", "SW 11", "SW 12", "SW 13", "SW 14", "SW 15", "SW 16", "SW 17", "SW 18",
    ]

    /// Serialize a mixer value into the 4-byte little-endian device payload.
    public static func payload(for value: UInt32) -> Data {
        var v = value.littleEndian
        return Data(bytes: &v, count: 4)
    }
}

// MARK: - Device configuration register block

extension Fireface400 {

    /// FF400 configuration register — 3 quadlets, write-only, must be
    /// written as one block (FFADO writes all three together).
    public static let configReg: UInt32 = 0x8010_0514

    public enum TriLevel: Int, Codable, CaseIterable {
        case lowGain, plus4dBu, minus10dBV
        public var label: String { ["LoGain", "+4 dBu", "-10 dBV"][rawValue] }
    }

    public enum SyncRef: Int, Codable, CaseIterable {
        case adat1, adat2, spdif, wordClock, timecode
        public var label: String { ["ADAT1", "ADAT2", "SPDIF", "WordClk", "TCO"][rawValue] }
    }

    /// The 3-quadlet config block (encoding per FFADO set_hardware_params /
    /// ASFW EncodeConfig, FF400 variant). Written whole — every bit of the
    /// block is meaningful, so toggling phantom requires rewriting all of it.
    public struct ConfigBlock: Codable, Equatable {
        public var phantom1 = false      // +48V on input 1   (q0 bit 0)
        public var phantom2 = false      // +48V on input 2   (q0 bit 7)
        public var pad3 = false          // -20 dB pad, in 3  (q0 bit 8)
        public var pad4 = false          // -20 dB pad, in 4  (q0 bit 1)
        public var instr3 = false        // instrument, in 3  (q0 bit 9)
        public var instr4 = false        // instrument, in 4  (q0 bit 2)
        public var inputLevel = TriLevel.plus4dBu    // rear inputs 5-8 ref level
        public var outputLevel = TriLevel.plus4dBu
        public var phonesLevel = TriLevel.plus4dBu
        public var clockMaster = true
        public var syncRef = SyncRef.adat1     // matches stored cfg (status1 mirror)
        public var spdifPro = true       // status shows this set on stored cfg
        public var spdifEmphasis = false
        public var spdifNonAudio = false
        public var spdifOutOptical = false
        public var spdifInOptical = false
        public var wordClockSingle = false

        public init() {}

        /// (q0, q1, q2) little-endian device quadlets.
        public var quadlets: (UInt32, UInt32, UInt32) {
            var q0: UInt32 = 0, q1: UInt32 = 0, q2: UInt32 = 0

            if phantom1 { q0 |= 0x01 }
            if phantom2 { q0 |= 0x80 }
            if pad4      { q0 |= 0x02 }   // CR0_FF400_CH4_PAD
            if instr4    { q0 |= 0x04 }   // CR0_FF400_CH4_INSTR
            if pad3      { q0 |= 0x100 }  // CR0_FF400_CH3_PAD
            if instr3    { q0 |= 0x200 }  // CR0_FF400_CH3_INSTR

            switch inputLevel {
            case .lowGain:    q0 |= 0x08; q1 |= 0x00
            case .plus4dBu:   q0 |= 0x10; q1 |= 0x02
            case .minus10dBV: q0 |= 0x20; q1 |= 0x03
            }
            switch outputLevel {
            case .lowGain:    q0 |= 0x0400; q1 |= 0x10  // "high gain" in ffado
            case .plus4dBu:   q0 |= 0x0800; q1 |= 0x18
            case .minus10dBV: q0 |= 0x1000; q1 |= 0x08
            }
            switch phonesLevel {
            case .lowGain:    q0 |= 0x20000 // higain
            case .plus4dBu:   break         // 0
            case .minus10dBV: q0 |= 0x10000
            }

            if clockMaster { q2 |= 0x01 }
            if spdifPro { q2 |= 0x20 }
            if spdifEmphasis { q2 |= 0x40 }
            if spdifNonAudio { q2 |= 0x80 }
            if spdifOutOptical { q2 |= 0x100 }
            if spdifInOptical { q2 |= 0x200 }
            if wordClockSingle { q2 |= 0x2000 }
            switch syncRef {
            case .adat1:     break           // 0x0000
            case .adat2:     q2 |= 0x0400
            case .spdif:     q2 |= 0x0c00
            case .wordClock: q2 |= 0x1000
            case .timecode:  q2 |= 0x1400
            }
            q2 |= 0x1e                       // FREQ0|FREQ1|DSPEED|QSSPEED
            q2 |= 0x8000_0000                // DROP_AND_STOP
            q2 |= 0x0400_0000                // CR2_FF400_BIT (MIDI TX offset 0)
            return (q0, q1, q2)
        }

        /// 12-byte block payload.
        public var payload: Data {
            var d = Data()
            for q in [quadlets.0, quadlets.1, quadlets.2] {
                var le = q.littleEndian
                d.append(Data(bytes: &le, count: 4))
            }
            return d
        }
    }
}
