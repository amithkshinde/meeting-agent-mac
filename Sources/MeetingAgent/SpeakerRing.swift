import Foundation

/// A rectangle in pixels, with the origin at the top left of the frame.
struct PixelBox: Equatable {
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var area: Int { w * h }
}

/// Finds the thin bright outline that Google Meet (and most call apps) draw around the person who is
/// speaking. It looks for long, thin, bright horizontal and vertical lines and keeps the rectangles
/// they form. Works on a plain grey-scale copy of the frame, so it has no dependencies.
enum SpeakerRing {
    private struct Run {
        var fixed: Int    // y for a horizontal run, x for a vertical one
        var from: Int
        var to: Int
    }

    /// Tunable, but these values were checked against real Google Meet recordings.
    static let minBrightness = 130
    static let minContrast = 55
    static let minRun = 60

    /// The rectangles that look like an "active speaker" outline, biggest first.
    static func find(luma: [UInt8], width: Int, height: Int) -> [PixelBox] {
        guard width > 160, height > 120, luma.count >= width * height else { return [] }
        let horizontal = runs(luma: luma, width: width, height: height, horizontal: true)
        let vertical = runs(luma: luma, width: width, height: height, horizontal: false)
        guard horizontal.count >= 2, vertical.count >= 2 else { return [] }

        let frameArea = width * height
        var found: [PixelBox] = []
        for (i, top) in horizontal.enumerated() {
            for bottom in horizontal[(i + 1)...] {
                let gap = bottom.fixed - top.fixed
                guard gap >= 50 else { continue }
                guard abs(top.from - bottom.from) <= 18, abs(top.to - bottom.to) <= 18 else { continue }
                let left = top.from - 22
                let right = top.to + 22
                // A vertical line must run down each side, covering most of the gap.
                let hasLeft = vertical.contains { run in
                    run.fixed >= left - 6 && run.fixed <= top.from + 8 && run.from <= top.fixed + 34 && run.to >= bottom.fixed - 34
                }
                let hasRight = vertical.contains { run in
                    run.fixed >= top.to - 8 && run.fixed <= right + 6 && run.from <= top.fixed + 34 && run.to >= bottom.fixed - 34
                }
                guard hasLeft, hasRight else { continue }
                let box = PixelBox(x: top.from - 12, y: top.fixed, w: (top.to - top.from) + 24, h: gap)
                guard box.area >= 4000, box.area <= frameArea * 6 / 10 else { continue }
                found.append(box)
            }
        }
        return dedupe(found).sorted { $0.area > $1.area }
    }

    /// Several nearly identical boxes come from a ring that is a few pixels thick. Keep one of each.
    private static func dedupe(_ boxes: [PixelBox]) -> [PixelBox] {
        var kept: [PixelBox] = []
        for box in boxes.sorted(by: { $0.area > $1.area }) {
            let same = kept.contains { abs($0.x - box.x) < 30 && abs($0.y - box.y) < 30 && abs($0.w - box.w) < 40 && abs($0.h - box.h) < 40 }
            if !same { kept.append(box) }
        }
        return kept
    }

    // MARK: - Lines

    private static func runs(luma: [UInt8], width: Int, height: Int, horizontal: Bool) -> [Run] {
        let step = horizontal ? width : 1          // distance to the pixel above/below (or left/right)
        let margin = 4
        let minBrightness = Self.minBrightness
        let minContrast = Self.minContrast
        let minRun = Self.minRun

        var result: [Run] = []
        luma.withUnsafeBufferPointer { g in
            let outer = horizontal ? height : width
            let inner = horizontal ? width : height
            for line in margin..<(outer - margin) {
                var start = -1
                var last = -1
                var index = margin
                while index <= inner - margin {
                    var hit = false
                    if index < inner - margin {
                        let position = horizontal ? line * width + index : index * width + line
                        let value = Int(g[position])
                        if value >= minBrightness {
                            let before = Int(g[position - margin * step])
                            let after = Int(g[position + margin * step])
                            hit = value - before > minContrast && value - after > minContrast
                        }
                    }
                    if hit {
                        if start < 0 { start = index }
                        last = index
                    } else if start >= 0 && index - last > 3 {
                        if last - start + 1 >= minRun { result.append(Run(fixed: line, from: start, to: last)) }
                        start = -1
                    }
                    index += 1
                }
            }
        }
        return merge(result)
    }

    /// A ring a few pixels thick shows up on neighbouring rows. Merge those into one line.
    private static func merge(_ runs: [Run]) -> [Run] {
        let sorted = runs.sorted { $0.fixed == $1.fixed ? $0.from < $1.from : $0.fixed < $1.fixed }
        var merged: [Run] = []
        for run in sorted {
            if let index = merged.lastIndex(where: { run.fixed - $0.fixed <= 3 && min($0.to, run.to) - max($0.from, run.from) > 30 }) {
                merged[index].from = min(merged[index].from, run.from)
                merged[index].to = max(merged[index].to, run.to)
            } else {
                merged.append(run)
            }
        }
        return merged
    }
}

/// Pulls a person's name out of the text read from a call tile.
enum TileName {
    /// `lines` are the text lines read from the tile, with `bottom` the distance of each from the
    /// bottom edge (0 = at the bottom, 1 = at the top). Meet puts the name at the bottom left.
    static func pick(from lines: [(text: String, bottom: Double, left: Double)]) -> String? {
        let candidates = lines
            .filter { $0.bottom < 0.45 }
            .sorted { $0.bottom < $1.bottom }
        for line in candidates {
            if let name = clean(line.text) { return name }
        }
        return nil
    }

    static func clean(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Long names are cut short by the call app ("Ananya Kan..."). Keep a marker so they can be matched to the full name later.
        let truncated = text.hasSuffix("...") || text.hasSuffix("…")
        for suffix in ["(Presentation)", "(Presenting)", "(You)", "(Host)", "(Co-host)", "(Guest)", "(Me)"] {
            text = text.replacingOccurrences(of: suffix, with: "", options: .caseInsensitive)
        }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " ·•|-–—_.,:;"))
        guard text.count >= 2, text.count <= 40 else { return nil }
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letters >= 2, Double(letters) >= Double(text.count) * 0.6 else { return nil }
        let lower = text.lowercased()
        // Short all-lowercase scraps ("ee", "dl") are icons the reader mistook for text.
        if text.count < 5, text == lower { return nil }
        let notNames = ["mute", "unmute", "pin", "more options", "presenting", "you", "camera", "microphone", "chat", "leave call", "raise hand"]
        guard !notNames.contains(lower) else { return nil }
        return truncated ? text + "…" : text
    }
}
