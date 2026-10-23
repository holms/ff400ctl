import Foundation

/// Per-channel hardware meter levels read from the FF400 meter block
/// (`0x80100000`). All levels are dBFS in the range -90.03...0;
/// `-.infinity` means silence.
public struct MeterLevels: Equatable, Sendable {
    /// Physical inputs: 8 analog, 2 S/PDIF, 8 ADAT.
    public var physIn: [Double]
    /// Stream (playback) channels the Mac is sending.
    public var streamIn: [Double]
    /// Physical outputs: 8 analog, 2 S/PDIF, 8 ADAT.
    public var physOut: [Double]
    /// Overload flags per physical input (low byte of the meter word).
    public var physInClip: [Bool]
    public var physOutClip: [Bool]

    public init() {
        physIn = [Double](repeating: -.infinity, count: 18)
        streamIn = [Double](repeating: -.infinity, count: 18)
        physOut = [Double](repeating: -.infinity, count: 18)
        physInClip = [Bool](repeating: false, count: 18)
        physOutClip = [Bool](repeating: false, count: 18)
    }
}

/// Decoder for the FF400 meter block at `0x80100000` (RME "former"
/// protocol; layout per Sakamoto's ALSA firewire-ctl-services
/// `former.rs`/`ff400.rs`).
///
/// The block is 648 bytes in three regions: mixer-source levels,
/// pre-fader and post-fader output levels (2 quadlets each), then 54
/// per-channel quadlets — 18 physical inputs, 18 stream inputs,
/// 18 physical outputs. We use the last region. Each quadlet masked
/// with `0x7fffff00` is a *linear amplitude* (raw/max = amplitude
/// ratio, verified against a known -8.7 dBFS tone); dB = 20·log10,
/// display floor -90.03. The low byte reports the overload ratio
/// once saturated.
public enum HardwareMeters {
    public static let address: UInt32 = 0x8010_0000
    /// 8 * (18 + 18*2) octuples + 4 * (18 + 18 + 18) quadlets.
    public static let blockSize = 648
    private static let region3Offset = 432
    private static let levelMask: UInt32 = 0x7fff_ff00
    private static let floor: Double = -90.03

    public static func parse(_ data: Data) -> MeterLevels? {
        guard data.count >= blockSize else { return nil }
        var m = MeterLevels()
        var pos = region3Offset
        var streamClip = [Bool](repeating: false, count: 18)
        func readGroup(_ into: inout [Double], _ clip: inout [Bool]) {
            for i in 0..<18 {
                let q = UInt32(data[pos]) | UInt32(data[pos+1]) << 8
                    | UInt32(data[pos+2]) << 16 | UInt32(data[pos+3]) << 24
                into[i] = toDB(q)
                clip[i] = q & 0xff != 0
                pos += 4
            }
        }
        readGroup(&m.physIn, &m.physInClip)
        readGroup(&m.streamIn, &streamClip)
        readGroup(&m.physOut, &m.physOutClip)
        return m
    }

    static func toDB(_ raw: UInt32) -> Double {
        let m = raw & levelMask
        if m == 0 { return -.infinity }
        return max(floor, 20 * log10(Double(m) / Double(levelMask)))
    }
}
