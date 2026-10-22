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
    /// - inputs 3/4: `dB` is in units of 0.5 dB (caller passes dB×2 semantics via `dB` already doubled? —
    ///   FFADO passes the raw dB value; device units are 0.5 dB).
    /// - outputs/phones/spdif/adat: `dB` is attenuation; `devval = 6 - round(dB*2)`,
    ///   >0x35 is replaced by 0x3f (mute). 0 dB → 6.
    public static func ampGainValue(index: Int, dB: Double) -> UInt32? {
        guard (0..<22).contains(index) else { return nil }
        let devval: UInt32
        if index <= AmpGain.mic2.rawValue {
            devval = dB >= 10 ? UInt32(min(dB, 65).rounded()) : 0
        } else if index <= AmpGain.input4.rawValue {
            devval = dB.isFinite ? UInt32(clamping: Int((dB * 2).rounded())) : 0
        } else {
            var v = dB.isFinite ? 6 - Int((dB * 2).rounded()) : 0x3f
            if v > 53 { v = 0x3f }            // mute
            if v < 0 { v = 0 }                // device maximum
            devval = UInt32(v)
        }
        return UInt32(index << 16) | (devval & 0xffff)
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
