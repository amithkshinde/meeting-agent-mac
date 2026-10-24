import Foundation

// Small files that live next to a recording: bookmarks.json, screens.json and speakers.jsonl.

/// A moment the user marked during the call.
struct Bookmark: Codable, Identifiable, Equatable {
    var id: String
    var t: Double          // seconds from the start of the recording
    var note: String
}

enum BookmarkStore {
    static func url(_ folder: URL) -> URL { folder.appendingPathComponent("bookmarks.json") }

    static func load(_ folder: URL) -> [Bookmark] {
        guard let data = try? Data(contentsOf: url(folder)) else { return [] }
        return ((try? JSONDecoder().decode([Bookmark].self, from: data)) ?? []).sorted { $0.t < $1.t }
    }

    static func save(_ items: [Bookmark], to folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(items) { try? data.write(to: url(folder), options: .atomic) }
    }

    @discardableResult
    static func add(at seconds: Double, in folder: URL) -> [Bookmark] {
        var items = load(folder)
        items.append(Bookmark(id: UUID().uuidString, t: max(0, seconds), note: ""))
        items.sort { $0.t < $1.t }
        save(items, to: folder)
        return items
    }

    static func remove(id: String, in folder: URL) {
        save(load(folder).filter { $0.id != id }, to: folder)
    }

    static func setNote(id: String, note: String, in folder: URL) {
        var items = load(folder)
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].note = note }
        save(items, to: folder)
    }
}

/// A picture of the shared screen, saved when it changed.
struct ScreenShot: Codable, Identifiable, Equatable {
    var id: Int
    var t: Double
    var file: String       // relative to the call folder, e.g. "screens/001.jpg"
}

enum ScreenIndex {
    static func url(_ folder: URL) -> URL { folder.appendingPathComponent("screens.json") }

    static func load(_ folder: URL) -> [ScreenShot] {
        guard let data = try? Data(contentsOf: url(folder)) else { return [] }
        return ((try? JSONDecoder().decode([ScreenShot].self, from: data)) ?? []).sorted { $0.t < $1.t }
    }

    static func save(_ items: [ScreenShot], to folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(items) { try? data.write(to: url(folder), options: .atomic) }
    }

    /// Which screen each transcript line belongs to: the last screen shown at or before the line.
    /// Lines are stamped when they end, so the stamp minus a few seconds is when they began.
    static func screenIndex(for time: Double, in screens: [ScreenShot]) -> Int? {
        let start = time - 4
        var found: Int?
        for (index, shot) in screens.enumerated() where shot.t <= start + 0.5 { found = index }
        return found ?? (screens.isEmpty ? nil : 0)
    }
}

extension ScreenIndex {
    /// The transcript with a marker line wherever a new screen came up, for the AI.
    static func annotate(_ raw: String, screens: [ScreenShot]) -> String {
        var out: [String] = []
        var current: Int?
        for row in raw.components(separatedBy: "\n") {
            let text = row.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            let line = Transcript.parseLine(text, id: 0)
            if let t = line.time, let index = screenIndex(for: t, in: screens), index != current {
                current = index
                out.append("--- Screen \(index + 1) shown at \(Transcript.clock(screens[index].t)) ---")
            }
            out.append(text)
        }
        return out.joined(separator: "\n")
    }
}

/// Who was speaking, according to the video, once a second.
struct SpeakerSample: Codable, Equatable {
    var t: Double
    var name: String
}

enum SpeakerLog {
    static func url(_ folder: URL) -> URL { folder.appendingPathComponent("speakers.jsonl") }

    static func append(_ sample: SpeakerSample, to folder: URL) {
        guard let data = try? JSONEncoder().encode(sample) else { return }
        var line = data
        line.append(10)
        if let handle = try? FileHandle(forWritingTo: url(folder)) {
            handle.seekToEndOfFile()
            handle.write(line)
            try? handle.close()
        } else {
            try? line.write(to: url(folder))
        }
    }

    static func load(_ folder: URL) -> [SpeakerSample] {
        guard let text = try? String(contentsOf: url(folder), encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text.components(separatedBy: "\n").compactMap { row in
            guard !row.isEmpty, let data = row.data(using: .utf8) else { return nil }
            return try? decoder.decode(SpeakerSample.self, from: data)
        }
    }
}

/// Puts real names on the "Them" lines of a transcript, using who the video showed speaking.
enum SpeakerAttribution {
    struct Result {
        var text: String
        var named: Int
        var total: Int
        var names: [String]
    }

    /// Slightly different readings of the same name ("Bishwajeet Urma" / "Bishwajeet Urrna") become one.
    static func canonical(_ input: [SpeakerSample]) -> [SpeakerSample] {
        // Names cut short with "…" take the full name that starts the same way, if one was seen.
        var fullCounts: [String: Int] = [:]
        for sample in input where !sample.name.hasSuffix("…") { fullCounts[sample.name, default: 0] += 1 }
        let samples: [SpeakerSample] = input.map { sample in
            guard sample.name.hasSuffix("…") else { return sample }
            let prefix = String(sample.name.dropLast()).trimmingCharacters(in: .whitespaces).lowercased()
            let match = fullCounts.filter { $0.key.lowercased().hasPrefix(prefix) }.max { $0.value < $1.value }
            return SpeakerSample(t: sample.t, name: match?.key ?? String(sample.name.dropLast()).trimmingCharacters(in: .whitespaces))
        }
        var counts: [String: Int] = [:]
        for sample in samples { counts[sample.name, default: 0] += 1 }
        let ordered = counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map { $0.key }
        var target: [String: String] = [:]
        var masters: [String] = []
        for name in ordered {
            if let master = masters.first(where: { similar($0, name) }) {
                target[name] = master
            } else {
                masters.append(name)
                target[name] = name
            }
        }
        return samples.map { SpeakerSample(t: $0.t, name: target[$0.name] ?? $0.name) }
    }

    private static func similar(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased(), y = b.lowercased()
        if x == y { return true }
        guard min(x.count, y.count) >= 6 else { return false }
        return distance(Array(x), Array(y)) <= 2
    }

    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return previous[b.count]
    }

    /// True when two readings are the same person: equal, nearly equal, or one is a part of the other ("Amith" / "Amith Shinde").
    static func sameName(_ a: String, _ b: String) -> Bool {
        let x = a.lowercased().split(separator: " ").map(String.init)
        let y = b.lowercased().split(separator: " ").map(String.init)
        guard !x.isEmpty, !y.isEmpty else { return false }
        if similar(a, b) { return true }
        let shorter = x.count <= y.count ? x : y
        let longer = x.count <= y.count ? y : x
        return shorter.allSatisfy { longer.contains($0) }
    }

    /// `them` is the label used for everyone else in the call ("Them"). Names in `exclude` (the user's own)
    /// are never put on a "Them" line, because the user's own lines already say "You".
    static func apply(to raw: String, samples rawSamples: [SpeakerSample], them: String = "Them", exclude: [String] = []) -> Result {
        let samples = canonical(rawSamples)
            .filter { sample in !exclude.contains(where: { sameName($0, sample.name) }) }
            .sorted { $0.t < $1.t }
        let lines = Transcript.parse(raw)
        var output: [String] = []
        var named = 0
        var total = 0
        var seen = Set<String>()
        var previousThem = 0.0

        for line in lines {
            guard let t = line.time, line.speaker == them else {
                output.append(Transcript.format(line))
                continue
            }
            total += 1
            // The line covers the speech since the last "Them" line, at most 12 seconds, ending a moment before its stamp.
            let start = max(previousThem, t - 12)
            let window = samples.filter { $0.t >= start && $0.t <= t + 0.5 }
            previousThem = t
            var counts: [String: Int] = [:]
            for sample in window { counts[sample.name, default: 0] += 1 }
            if let best = counts.max(by: { $0.value < $1.value }), best.value >= 2, Double(best.value) >= Double(window.count) * 0.5 {
                var changed = line
                changed.speaker = best.key
                output.append(Transcript.format(changed))
                named += 1
                seen.insert(best.key)
            } else {
                output.append(Transcript.format(line))
            }
        }
        return Result(text: output.joined(separator: "\n") + "\n", named: named, total: total, names: seen.sorted())
    }
}

/// What the AI made of the talk about one screen. Saved as review.json.
struct ScreenFeedback: Codable, Identifiable, Equatable {
    var n: Int                 // the screen's number, starting at 1
    var title: String          // what the screen seems to be
    var feedback: [String]
    var decisions: [String]
    var id: Int { n }

    static func url(_ folder: URL) -> URL { folder.appendingPathComponent("review.json") }

    static func load(_ folder: URL) -> [ScreenFeedback] {
        guard let data = try? Data(contentsOf: url(folder)) else { return [] }
        return (try? JSONDecoder().decode([ScreenFeedback].self, from: data)) ?? []
    }

    static func save(_ items: [ScreenFeedback], to folder: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(items) { try? data.write(to: url(folder), options: .atomic) }
    }
}

extension ScreenIndex {
    /// The transcript lines that belong to each screen, in order. The result has one entry per screen.
    static func group(_ lines: [TLine], by screens: [ScreenShot]) -> [[TLine]] {
        var groups = Array(repeating: [TLine](), count: screens.count)
        for line in lines {
            guard let t = line.time, let index = screenIndex(for: t, in: screens) else { continue }
            groups[index].append(line)
        }
        return groups
    }
}
