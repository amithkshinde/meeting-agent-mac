import Foundation

/// Searches every call (summary and transcript), note, file, email, promise and project.
/// Transcripts are read from disk the first time and remembered, so typing stays quick.
final class SearchEngine {
    private struct CachedTranscript {
        var modified: Date
        var lines: [TLine]
    }

    private var cache: [String: CachedTranscript] = [:]
    private let lock = NSLock()

    /// Everything the search needs, copied out of the app's stores so it can run off the main thread.
    struct Inputs {
        var calls: [CallRecord]
        var items: [KnowledgeItem]
        var promises: [Commitment]
        var projects: [String]
        var folderFor: (CallRecord) -> URL
    }

    func search(_ query: String, in inputs: Inputs) -> [SearchHit] {
        let tokens = SearchCore.tokens(query)
        guard !tokens.isEmpty, query.trimmingCharacters(in: .whitespaces).count >= 2 else { return [] }
        var hits: [SearchHit] = []
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short

        // Projects
        for name in inputs.projects where SearchCore.matches(name, tokens: tokens) {
            hits.append(SearchHit(id: "p:\(name)", kind: .project, title: name, detail: "Project", target: .project(name: name)))
        }

        // Calls, by title, people and summary
        var callHits: [(Int, SearchHit)] = []
        for call in inputs.calls {
            let title = call.title ?? "\(call.app) call"
            let people = (call.attendees ?? []).map { $0.name }.joined(separator: ", ")
            let haystack = [title, call.client, people, call.summary].joined(separator: "\n")
            guard SearchCore.matches(haystack, tokens: tokens) else { continue }
            let inSummary = SearchCore.matches(call.summary, tokens: tokens)
            let detail = inSummary
                ? SearchCore.snippet(call.summary, tokens: tokens)
                : "\(call.client == MemoryStore.unassigned ? "No project" : call.client) · \(formatter.string(from: call.date))"
            let score = SearchCore.score(haystack, tokens: tokens) + (SearchCore.matches(title, tokens: tokens) ? 5 : 0)
            callHits.append((score, SearchHit(id: "c:\(call.id)", kind: .call, title: "\(title) · \(formatter.string(from: call.date))", detail: detail, target: .call(id: call.id, seek: nil))))
        }
        hits += callHits.sorted { $0.0 > $1.0 }.prefix(6).map { $0.1 }

        // Moments: single transcript lines, newest calls first
        var moments: [SearchHit] = []
        for call in inputs.calls.sorted(by: { $0.date > $1.date }) {
            guard moments.count < 14 else { break }
            let lines = transcript(for: call, folder: inputs.folderFor(call))
            var perCall = 0
            for line in lines where SearchCore.matches(line.text, tokens: tokens) {
                guard perCall < 3, moments.count < 14 else { break }
                perCall += 1
                let who = line.speaker.isEmpty ? "" : "\(line.speaker): "
                let when = line.time.map { Transcript.clock($0) } ?? ""
                moments.append(SearchHit(
                    id: "m:\(call.id):\(line.id)",
                    kind: .moment,
                    title: who + SearchCore.snippet(line.text, tokens: tokens, radius: 80),
                    detail: "\(call.title ?? call.app + " call") · \(formatter.string(from: call.date))" + (when.isEmpty ? "" : " · at \(when)"),
                    target: .call(id: call.id, seek: line.time.map { max(0, $0 - 5) })
                ))
            }
        }
        hits += moments

        // Notes, files and emails
        var noteHits: [(Int, SearchHit)] = []
        for item in inputs.items {
            let haystack = item.title + "\n" + item.text
            guard SearchCore.matches(haystack, tokens: tokens) else { continue }
            let score = SearchCore.score(haystack, tokens: tokens) + (SearchCore.matches(item.title, tokens: tokens) ? 5 : 0)
            let place = item.client.isEmpty ? "General" : item.client
            noteHits.append((score, SearchHit(id: "n:\(item.id)", kind: .note, title: item.title, detail: "\(place) · " + SearchCore.snippet(item.text, tokens: tokens), target: .note(id: item.id))))
        }
        hits += noteHits.sorted { $0.0 > $1.0 }.prefix(8).map { $0.1 }

        // Promises
        for promise in inputs.promises where SearchCore.matches(promise.text + " " + promise.owner, tokens: tokens) {
            guard hits.filter({ $0.kind == .promise }).count < 6 else { break }
            let who = promise.isMine ? "You" : promise.owner
            let status = promise.done ? "Done" : (promise.isOverdue ? "Overdue" : "Open")
            hits.append(SearchHit(id: "k:\(promise.id)", kind: .promise, title: "\(who): \(promise.text)", detail: status, target: .promises))
        }

        return hits.sorted { $0.kind.rawValue < $1.kind.rawValue }
    }

    private func transcript(for call: CallRecord, folder: URL) -> [TLine] {
        let clean = folder.appendingPathComponent("transcript-clean.txt")
        let raw = folder.appendingPathComponent("transcript.txt")
        let url = FileManager.default.fileExists(atPath: clean.path) ? clean : raw
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast

        lock.lock()
        if let hit = cache[call.id], hit.modified == modified {
            lock.unlock()
            return hit.lines
        }
        lock.unlock()

        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = Transcript.parse(text)
        lock.lock()
        cache[call.id] = CachedTranscript(modified: modified, lines: lines)
        lock.unlock()
        return lines
    }
}
