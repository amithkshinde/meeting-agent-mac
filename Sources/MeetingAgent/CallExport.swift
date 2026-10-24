import Foundation

/// Turns a call into a Markdown document (which Notion, Obsidian and most editors open directly)
/// and into simple HTML (which becomes the PDF).
enum CallExport {
    static func markdown(call: CallRecord, folder: URL, promises: [Commitment], includeTranscript: Bool = true) -> String {
        let when = DateFormatter()
        when.dateStyle = .long
        when.timeStyle = .short
        let due = DateFormatter()
        due.dateStyle = .medium

        var out: [String] = []
        out.append("# \(call.title ?? "\(call.app) call")")
        var facts = [when.string(from: call.date), call.app]
        if call.client != MemoryStore.unassigned { facts.append("Project: \(call.client)") }
        out.append("*\(facts.joined(separator: " · "))*")
        if let people = call.attendees, !people.isEmpty {
            out.append("**With:** " + people.map { $0.name }.joined(separator: ", "))
        }
        out.append("")

        if call.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.append("## Summary\n\nNo summary was written for this call.")
        } else {
            out.append(call.summary.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        out.append("")

        let mine = promises.filter { $0.callId == call.id }
        if !mine.isEmpty {
            out.append("## Promises")
            out.append("")
            for item in mine {
                let who = item.isMine ? "You" : item.owner
                let date = item.due.map { " (by \(due.string(from: $0)))" } ?? ""
                out.append("- [\(item.done ? "x" : " ")] **\(who):** \(item.text)\(date)")
            }
            out.append("")
        }

        let transcript = readTranscript(folder)
        let marks = BookmarkStore.load(folder)
        if !marks.isEmpty {
            out.append("## Highlights")
            out.append("")
            for mark in marks {
                let said = line(after: mark.t, in: transcript)
                let note = mark.note.trimmingCharacters(in: .whitespaces)
                out.append("- **\(Transcript.clock(mark.t))**" + (note.isEmpty ? "" : " \(note)") + (said.isEmpty ? "" : " — “\(said)”"))
            }
            out.append("")
        }

        let screens = ScreenIndex.load(folder)
        if screens.count >= 1 {
            out.append("## Screens")
            out.append("")
            for (index, shot) in screens.enumerated() {
                out.append("- Screen \(index + 1) at \(Transcript.clock(shot.t)) (\(shot.file))")
            }
            out.append("")
        }

        if includeTranscript, !transcript.isEmpty {
            out.append("## Transcript")
            out.append("")
            for row in transcript {
                let stamp = row.time.map { "[\(Transcript.clock($0))] " } ?? ""
                let who = row.speaker.isEmpty ? "" : "**\(row.speaker):** "
                out.append("\(stamp)\(who)\(row.text)  ")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    /// The cleaned transcript if there is one, otherwise the raw one.
    static func readTranscript(_ folder: URL) -> [TLine] {
        let clean = folder.appendingPathComponent("transcript-clean.txt")
        let raw = folder.appendingPathComponent("transcript.txt")
        let url = FileManager.default.fileExists(atPath: clean.path) ? clean : raw
        return Transcript.parse((try? String(contentsOf: url, encoding: .utf8)) ?? "")
    }

    /// The first thing said after a moment, to remind the reader what the bookmark was about.
    static func line(after time: Double, in lines: [TLine]) -> String {
        guard let found = lines.first(where: { ($0.time ?? -1) >= time }) else { return "" }
        let text = found.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > 140 ? String(text.prefix(140)) + "…" : text
    }

    // MARK: - HTML (for the PDF)

    /// A small Markdown to HTML converter: headings, bullets, numbered lists, bold, italics, paragraphs.
    static func html(fromMarkdown markdown: String, title: String) -> String {
        var body: [String] = []
        var inList = false
        var inOrdered = false

        func closeLists() {
            if inList { body.append("</ul>"); inList = false }
            if inOrdered { body.append("</ol>"); inOrdered = false }
        }

        for rawRow in markdown.components(separatedBy: "\n") {
            let row = rawRow.trimmingCharacters(in: .whitespaces)
            if row.isEmpty { closeLists(); continue }
            if row.hasPrefix("### ") { closeLists(); body.append("<h3>\(inline(String(row.dropFirst(4))))</h3>"); continue }
            if row.hasPrefix("## ") { closeLists(); body.append("<h2>\(inline(String(row.dropFirst(3))))</h2>"); continue }
            if row.hasPrefix("# ") { closeLists(); body.append("<h1>\(inline(String(row.dropFirst(2))))</h1>"); continue }
            if row.hasPrefix("- ") || row.hasPrefix("* ") {
                if inOrdered { body.append("</ol>"); inOrdered = false }
                if !inList { body.append("<ul>"); inList = true }
                var item = String(row.dropFirst(2))
                if item.hasPrefix("[ ] ") { item = "☐ " + item.dropFirst(4) }
                else if item.hasPrefix("[x] ") { item = "☑ " + item.dropFirst(4) }
                body.append("<li>\(inline(item))</li>")
                continue
            }
            if let dot = row.firstIndex(of: "."), row[row.startIndex..<dot].allSatisfy({ $0.isNumber }), !row[row.startIndex..<dot].isEmpty,
               row.index(after: dot) < row.endIndex, row[row.index(after: dot)] == " " {
                if inList { body.append("</ul>"); inList = false }
                if !inOrdered { body.append("<ol>"); inOrdered = true }
                body.append("<li>\(inline(String(row[row.index(dot, offsetBy: 2)...])))</li>")
                continue
            }
            closeLists()
            body.append("<p>\(inline(row))</p>")
        }
        closeLists()

        let style = "body { font-family: -apple-system, Helvetica, Arial; font-size: 11pt; color: #1b1b1f; } "
            + "h1 { font-size: 22pt; } h2 { font-size: 15pt; margin-top: 16pt; } h3 { font-size: 12.5pt; } "
            + "p, li { line-height: 1.35; }"
        return "<html><head><meta charset=\"utf-8\"><title>\(escape(title))</title><style>\(style)</style></head><body>\(body.joined(separator: "\n"))</body></html>"
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// **bold** and *italic* inside one line.
    private static func inline(_ text: String) -> String {
        var result = escape(text)
        result = replacePairs(in: result, marker: "**", open: "<b>", close: "</b>")
        result = replacePairs(in: result, marker: "*", open: "<i>", close: "</i>")
        return result
    }

    private static func replacePairs(in text: String, marker: String, open: String, close: String) -> String {
        let parts = text.components(separatedBy: marker)
        guard parts.count >= 3 else { return text }
        let pairedMarkers = ((parts.count - 1) / 2) * 2   // markers that have a partner; a last odd one stays as it was
        var out = parts[0]
        for index in 1..<parts.count {
            let markerNumber = index - 1
            if markerNumber < pairedMarkers {
                out += markerNumber % 2 == 0 ? open : close
            } else {
                out += marker
            }
            out += parts[index]
        }
        return out
    }

    /// A safe file name for a call, like "Weekly updates 2026-10-19".
    static func fileName(for call: CallRecord) -> String {
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        let base = call.title ?? "\(call.app) call"
        let cleaned = base.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
        return "\(cleaned) \(day.string(from: call.date))"
    }
}
