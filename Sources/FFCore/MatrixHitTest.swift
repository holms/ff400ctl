import Foundation

/// Maps a point in the matrix-cell grid to a cell, shared between the
/// FFTray Canvas tap handler and unit tests.
public enum MatrixHitTest {
    /// Grid cells of `cellW`×`cellH` points laid out at pitch
    /// (cell + gap), `count` per side. Returns the (row, col) cell under
    /// the point, or nil for points inside a gap or outside the grid.
    public static func cell(at x: Double, y: Double,
                            cellW: Double, cellH: Double, gap: Double,
                            count: Int) -> (row: Int, col: Int)? {
        func axis(_ p: Double, _ cell: Double) -> Int? {
            guard p >= 0 else { return nil }
            let pitch = cell + gap
            let i = Int(p / pitch)
            guard i < count, p - Double(i) * pitch < cell else { return nil }
            return i
        }
        guard let row = axis(y, cellH), let col = axis(x, cellW) else { return nil }
        return (row, col)
    }
}
