import Foundation

/// Translates a transcript into English, on request. The original is never changed.
enum Translation {
    static let system = """
    You translate call transcript lines into clear, natural English. Each line looks like "[mm:ss] Speaker: text". \
    The speech may be Hindi (in Devanagari or Roman letters), Hinglish, Kannada, or English. \
    Translate the text of each line, and keep the timestamp and the speaker label exactly as they are. \
    Lines that are already English stay as they are. Keep names, product names and numbers. \
    Keep every line, in the same order. Do not summarise or add anything. Reply with the lines only, nothing before or after.
    """

    static func url(_ folder: URL) -> URL { folder.appendingPathComponent("transcript-en.txt") }

    /// Translates the lines a few at a time. `progress` goes from 0 to 1.
    static func translate(_ lines: [TLine], key: String, progress: @escaping (Double) -> Void) async throws -> [TLine] {
        let limit = key == AIAccess.localKey ? 1800 : 5000
        var chunks: [[TLine]] = []
        var current: [TLine] = []
        var size = 0
        for line in lines {
            let length = line.text.count + line.speaker.count + 12
            if size + length > limit, !current.isEmpty {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(line)
            size += length
        }
        if !current.isEmpty { chunks.append(current) }

        var output: [TLine] = []
        for (number, chunk) in chunks.enumerated() {
            progress(Double(number) / Double(max(1, chunks.count)))
            let prompt = "Transcript lines:\n" + chunk.map { Transcript.format($0) }.joined(separator: "\n")
            var reply: String?
            for attempt in 0..<2 {
                do {
                    reply = try await ChatService.complete(key: key, system: system, prompt: prompt, maxTokens: 2800)
                    break
                } catch ChatError.badKey {
                    throw ChatError.badKey
                } catch {
                    if attempt == 1 { throw error }
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                }
            }
            let rows = (reply ?? "").components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("[") }
            if rows.count == chunk.count {
                for (original, row) in zip(chunk, rows) {
                    var translated = Transcript.parseLine(row, id: original.id)
                    // Trust our own stamp and label, whatever the AI wrote.
                    translated.time = original.time
                    translated.speaker = original.speaker
                    output.append(translated)
                }
            } else {
                output += chunk   // the answer didn't line up, so keep the original lines for this stretch
            }
        }
        progress(1)
        return output
    }
}

/// Reads the talk about each screen and writes the feedback and decisions for it, for design reviews.
enum ScreenReview {
    static let system = """
    You help a designer after a design review call. You get the transcript split by the screen that was being shown, in order. \
    "You" is the user. Lines may start with a person's name. The transcript is automatic speech recognition, so expect small mistakes. \
    For each screen, write: a short title saying what the screen seems to be, judging only from what people said (or "Screen N" if unclear); \
    "feedback": the comments, requests and concerns people raised about it, as short bullets that say who said it when the name is known; \
    and "decisions": anything agreed or decided about it. Use only what the transcript says. Leave a list empty if there was nothing. \
    Reply with JSON only, in exactly this shape: {"screens": [{"n": 1, "title": "...", "feedback": ["..."], "decisions": ["..."]}]}. \
    Include every screen number you were given.
    """

    static func generate(lines: [TLine], screens: [ScreenShot], key: String) async throws -> [ScreenFeedback] {
        let groups = ScreenIndex.group(lines, by: screens)
        var parts: [String] = []
        for (index, group) in groups.enumerated() {
            let body = group.isEmpty ? "(nothing was said)" : group.map { Transcript.format($0) }.joined(separator: "\n")
            parts.append("Screen \(index + 1) (shown at \(Transcript.clock(screens[index].t))):\n\(body)")
        }
        var prompt = parts.joined(separator: "\n\n")
        if prompt.count > 50_000 { prompt = String(prompt.prefix(50_000)) }
        let reply = try await ChatService.complete(key: key, system: system, prompt: prompt + "\n\nReturn the JSON now.", json: true, maxTokens: 2400)
        guard let object = CallProcessor.jsonObject(from: reply), let list = object["screens"] as? [[String: Any]] else {
            throw ChatError.message("I couldn't read the AI's answer. Try again.")
        }
        func strings(_ value: Any?) -> [String] {
            ((value as? [Any]) ?? []).compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        var result: [ScreenFeedback] = []
        for entry in list {
            let number = (entry["n"] as? Int) ?? Int((entry["n"] as? Double) ?? 0)
            guard number >= 1, number <= screens.count else { continue }
            result.append(ScreenFeedback(
                n: number,
                title: ((entry["title"] as? String) ?? "Screen \(number)").trimmingCharacters(in: .whitespacesAndNewlines),
                feedback: strings(entry["feedback"]),
                decisions: strings(entry["decisions"])
            ))
        }
        return result.sorted { $0.n < $1.n }
    }
}
