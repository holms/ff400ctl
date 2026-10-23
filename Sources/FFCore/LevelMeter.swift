import Foundation

/// RMS/peak metering over Float32 sample buffers (dBFS, 20·log10).
/// Silence — all zeros or no samples — reports -200 so JSON consumers
/// always get a number.
public enum LevelMeter {
    public static func measure(_ samples: UnsafeBufferPointer<Float>)
        -> (rmsDB: Double, peakDB: Double) {
        var acc = Accumulator()
        acc.add(samples)
        return (acc.rmsDB, acc.peakDB)
    }

    /// Streaming form: feed each tap buffer, then read the dB values.
    public struct Accumulator {
        public private(set) var count = 0
        private var sumSq = 0.0
        private var peak: Float = 0

        public init() {}

        public mutating func add(_ samples: UnsafeBufferPointer<Float>) {
            for v in samples {
                sumSq += Double(v) * Double(v)
                peak = max(peak, abs(v))
            }
            count += samples.count
        }

        public var rmsDB: Double {
            guard count > 0, sumSq > 0 else { return -200 }
            return 20 * log10((sumSq / Double(count)).squareRoot())
        }

        public var peakDB: Double {
            peak > 0 ? 20 * log10(Double(peak)) : -200
        }
    }
}
