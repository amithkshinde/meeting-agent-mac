import Foundation

/// Decides when the shared screen has changed enough to be worth a screenshot, for example when
/// someone moves to the next Figma frame or the next slide. It works on a tiny summary of each frame.
struct ScreenChangeDetector {
    static let columns = 32
    static let rows = 20

    private var keyframe: [UInt8]?
    private var previous: [UInt8]?
    private var lastSaved = -100.0
    private(set) var count = 0

    /// Average brightness of each block of the frame, 32 x 20 blocks.
    static func digest(luma: [UInt8], width: Int, height: Int) -> [UInt8] {
        guard width >= columns, height >= rows, luma.count >= width * height else { return [] }
        var sums = [Int](repeating: 0, count: columns * rows)
        var counts = [Int](repeating: 0, count: columns * rows)
        // Sampling every 3rd pixel in each direction is plenty for block averages.
        luma.withUnsafeBufferPointer { g in
            var y = 0
            while y < height {
                let row = min(rows - 1, y * rows / height)
                var x = 0
                while x < width {
                    let column = min(columns - 1, x * columns / width)
                    sums[row * columns + column] += Int(g[y * width + x])
                    counts[row * columns + column] += 1
                    x += 3
                }
                y += 3
            }
        }
        return (0..<(columns * rows)).map { UInt8(counts[$0] == 0 ? 0 : sums[$0] / counts[$0]) }
    }

    /// The share of blocks (0...1) whose brightness differs by more than `threshold`.
    static func difference(_ a: [UInt8], _ b: [UInt8], threshold: Int = 22) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        var changed = 0
        for i in 0..<a.count where abs(Int(a[i]) - Int(b[i])) > threshold { changed += 1 }
        return Double(changed) / Double(a.count)
    }

    /// Call once a second. Returns true when this frame should be saved as a new screen.
    mutating func feed(digest: [UInt8], at time: Double) -> Bool {
        defer { previous = digest }
        guard !digest.isEmpty, count < 150 else { return false }
        guard let key = keyframe else {
            // The first screen: save it once the picture has settled.
            if let previous, Self.difference(previous, digest) < 0.05, time >= 2 {
                keyframe = digest
                lastSaved = time
                count += 1
                return true
            }
            return false
        }
        guard time - lastSaved >= 8 else { return false }
        // A real change from the last saved screen, and no longer moving (so a transition isn't captured half way).
        if Self.difference(key, digest) > 0.30, let previous, Self.difference(previous, digest) < 0.06 {
            keyframe = digest
            lastSaved = time
            count += 1
            return true
        }
        return false
    }
}
