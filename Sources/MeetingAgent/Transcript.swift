import Foundation

/// One line of a transcript file: "[mm:ss] Speaker: text".
struct TLine: Identifiable, Equatable {
    let id: Int
    var time: Double?      // seconds from the start of the recording, nil if the line has no stamp
    var speaker: String
    var text: String
}

enum Transcript {
    /// Reads transcript.txt or transcript-clean.txt. Lines that don't fit the pattern are kept as plain text.
    static func parse(_ raw: String) -> [TLine] {
        var lines: [TLine] = []
        for (index, row) in raw.components(separatedBy: "\n").enumerated() {
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            lines.append(parseLine(trimmed, id: index))
        }
        return lines
    }

    static func parseLine(_ row: String, id: Int) -> TLine {
        guard row.hasPrefix("["), let close = row.firstIndex(of: "]") else {
            return TLine(id: id, time: nil, speaker: "", text: row)
        }
        let stamp = String(row[row.index(after: row.startIndex)..<close])
        let rest = row[row.index(after: close)...].trimmingCharacters(in: .whitespaces)
        let seconds = seconds(from: stamp)
        if let colon = rest.range(of: ": "), rest.distance(from: rest.startIndex, to: colon.lowerBound) <= 40 {
            let speaker = String(rest[rest.startIndex..<colon.lowerBound])
            let text = String(rest[colon.upperBound...])
            return TLine(id: id, time: seconds, speaker: speaker, text: text)
        }
        return TLine(id: id, time: seconds, speaker: "", text: rest)
    }

    /// "05:12" or "1:05:12" to seconds.
    static func seconds(from stamp: String) -> Double? {
        let parts = stamp.split(separator: ":").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        let numbers = parts.compactMap { $0 }
        switch numbers.count {
        case 2: return numbers[0] * 60 + numbers[1]
        case 3: return numbers[0] * 3600 + numbers[1] * 60 + numbers[2]
        default: return nil
        }
    }

    /// 75 -> "1:15", 3700 -> "1:01:40".
    static func clock(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// The same format the live transcriber writes.
    static func format(_ line: TLine) -> String {
        guard let time = line.time else { return line.text }
        let total = max(0, Int(time))
        let stamp = String(format: "[%02d:%02d] ", total / 60, total % 60)
        return line.speaker.isEmpty ? stamp + line.text : stamp + "\(line.speaker): \(line.text)"
    }

    /// Index of the line being spoken at `time`: the last line that starts no later than it.
    /// Lines are stamped when they END, so a line "covers" the seconds before its stamp.
    static func currentIndex(in lines: [TLine], at time: Double) -> Int? {
        var found: Int?
        for (index, line) in lines.enumerated() {
            guard let t = line.time else { continue }
            if t <= time + 1.5 { found = index } else { break }
        }
        return found
    }

    /// Where in the video to start when a line is clicked: a few seconds before it ends, because the stamp is the end of the sentence.
    static func seekTime(for line: TLine) -> Double? {
        guard let t = line.time else { return nil }
        return max(0, t - 5)
    }

    /// Every distinct speaker label, most frequent first.
    static func speakers(in lines: [TLine]) -> [String] {
        var counts: [String: Int] = [:]
        for line in lines where !line.speaker.isEmpty { counts[line.speaker, default: 0] += 1 }
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { $0.key }
    }

    /// Changes a speaker label everywhere in a transcript file's text.
    static func rename(speaker old: String, to new: String, in raw: String) -> String {
        raw.components(separatedBy: "\n").map { row -> String in
            let line = parseLine(row.trimmingCharacters(in: .whitespaces), id: 0)
            guard line.time != nil, line.speaker == old else { return row }
            var changed = line
            changed.speaker = new
            return format(changed)
        }.joined(separator: "\n")
    }
}
