import AppKit
import Foundation
import PDFKit

/// A note or file the user adds about the product, a client, or anything the agent should know.
struct KnowledgeItem: Codable, Identifiable {
    var id: String
    var title: String
    var client: String      // empty means it applies to every call
    var kind: String        // "note" or "file"
    var text: String
    var date: Date
    var path: String? = nil // where the file was added from, so it can be opened again
}

/// knowledge.json next to the recordings. Everything stays on this Mac.
final class KnowledgeStore {
    private let url = Log.root.appendingPathComponent("knowledge.json")
    private(set) var items: [KnowledgeItem] = []

    init() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([KnowledgeItem].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(items) { try? data.write(to: url, options: .atomic) }
    }

    func add(_ item: KnowledgeItem) {
        items.append(item)
        save()
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    func setClient(id: String, to name: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].client = name
        save()
    }

    func reassign(from old: String, to new: String) {
        let wanted = old.lowercased()
        var changed = false
        for index in items.indices where items[index].client.lowercased() == wanted {
            items[index].client = new
            changed = true
        }
        if changed { save() }
    }

    func removeAll(inProject name: String) {
        let wanted = name.lowercased()
        items.removeAll { $0.client.lowercased() == wanted }
        save()
    }

    /// Reads text out of a file: plain text, Markdown, CSV, JSON, PDF, Word, RTF or HTML.
    static func extractText(from url: URL) -> String? {
        var text: String?
        switch url.pathExtension.lowercased() {
        case "pdf":
            text = PDFDocument(url: url)?.string
        case "rtf", "doc", "docx", "html", "htm", "odt":
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        default:
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .isoLatin1))
        }
        guard var result = text?.trimmingCharacters(in: .whitespacesAndNewlines), !result.isEmpty else { return nil }
        if result.count > 400_000 { result = String(result.prefix(400_000)) }
        return result
    }
}

/// A project is the top level: calls, files, notes and emails are filed under one.
struct Project: Codable, Identifiable {
    var name: String
    var brief: String
    var briefDate: Date?
    var onDeviceOnly: Bool? = nil   // keep this project's text on this Mac (never sent to a cloud AI)
    var id: String { name }
}

/// projects.json: the list of projects, and the AI-written brief for each.
final class ProjectStore {
    private let url = Log.root.appendingPathComponent("projects.json")
    private(set) var projects: [Project] = []

    init() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        projects = (try? decoder.decode([Project].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(projects) { try? data.write(to: url, options: .atomic) }
    }

    func project(named name: String) -> Project? {
        let wanted = name.lowercased()
        return projects.first { $0.name.lowercased() == wanted }
    }

    func ensure(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean != MemoryStore.unassigned, project(named: clean) == nil else { return }
        projects.append(Project(name: clean, brief: "", briefDate: nil))
        save()
    }

    func isOnDeviceOnly(_ name: String) -> Bool {
        project(named: name)?.onDeviceOnly == true
    }

    func setOnDeviceOnly(_ name: String, _ value: Bool) {
        ensure(name)
        guard let index = projects.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else { return }
        projects[index].onDeviceOnly = value
        save()
    }

    func setBrief(name: String, text: String) {
        ensure(name)
        guard let index = projects.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) else { return }
        projects[index].brief = text
        projects[index].briefDate = Date()
        save()
    }

    func rename(from old: String, to new: String) {
        let wanted = old.lowercased()
        if project(named: new) != nil {
            // The new name already exists, so this is a merge: keep the existing project.
            projects.removeAll { $0.name.lowercased() == wanted }
        } else if let index = projects.firstIndex(where: { $0.name.lowercased() == wanted }) {
            projects[index].name = new
        } else {
            projects.append(Project(name: new, brief: "", briefDate: nil))
        }
        save()
    }

    func remove(_ name: String) {
        let wanted = name.lowercased()
        projects.removeAll { $0.name.lowercased() == wanted }
        save()
    }

    /// Every project name, from the list and from anything filed under a name.
    func names(memory: MemoryStore, knowledge: KnowledgeStore) -> [String] {
        var byLower: [String: String] = [:]
        func note(_ name: String) {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if clean.isEmpty || clean == MemoryStore.unassigned { return }
            if byLower[clean.lowercased()] == nil { byLower[clean.lowercased()] = clean }
        }
        projects.forEach { note($0.name) }
        memory.records.forEach { note($0.client) }
        knowledge.items.forEach { note($0.client) }
        return byLower.values.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Reuses an existing project's spelling when the typed name matches it ignoring case.
    func canonical(_ typed: String, memory: MemoryStore, knowledge: KnowledgeStore) -> String {
        let clean = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if let match = names(memory: memory, knowledge: knowledge).first(where: { $0.lowercased() == clean.lowercased() }) {
            return match
        }
        return clean
    }
}

struct SourceChunk {
    let label: String
    let kind: String          // "note", "file", "email", "summary" or "transcript"
    let text: String
    let client: String
    let isGeneral: Bool
    var callId: String? = nil
    var path: String? = nil
}

struct RetrievedContext {
    let text: String
    let sources: [SourceRef]
}

/// Finds the notes, files, call summaries and transcript passages that matter for a question or for
/// what was just said. This is simple word matching, so it runs instantly and offline.
final class Retriever {
    private let memory: MemoryStore
    private let knowledge: KnowledgeStore
    private let projects: ProjectStore
    private var transcripts: [String: String] = [:]

    init(memory: MemoryStore, knowledge: KnowledgeStore, projects: ProjectStore) {
        self.memory = memory
        self.knowledge = knowledge
        self.projects = projects
    }

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "file": return "File"
        case "email": return "Email"
        default: return "Note"
        }
    }

    private static let stopWords: Set<String> = [
        "the", "and", "for", "that", "this", "with", "have", "has", "are", "was", "were", "you", "your", "not",
        "but", "can", "will", "would", "could", "should", "from", "they", "them", "their", "what", "when",
        "where", "which", "who", "how", "about", "there", "then", "than", "been", "being", "just", "like",
        "also", "very", "yes", "okay", "know", "think", "going", "get", "got", "its", "our", "out", "all",
    ]

    static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stopWords.contains($0) }
    }

    static func split(_ text: String, size: Int = 1200) -> [String] {
        var pieces: [String] = []
        var current = ""
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if !current.isEmpty, current.count + line.count + 1 > size {
                pieces.append(current)
                current = ""
            }
            if line.count > size {
                var rest = Substring(line)
                while rest.count > size {
                    pieces.append(String(rest.prefix(size)))
                    rest = rest.dropFirst(size)
                }
                current = String(rest)
            } else {
                current += (current.isEmpty ? "" : "\n") + line
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    static func dateText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    private func transcript(for record: CallRecord, excluding: String?) -> String {
        if let cached = transcripts[record.id] { return cached }
        let url = Log.root.appendingPathComponent(record.id).appendingPathComponent("transcript.txt")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if record.id != excluding, !text.isEmpty { transcripts[record.id] = text }
        return text
    }

    private func allChunks(excluding: String?) -> [SourceChunk] {
        var chunks: [SourceChunk] = []
        for item in knowledge.items {
            let kind = Self.kindLabel(item.kind)
            for part in Self.split(item.text) {
                chunks.append(SourceChunk(
                    label: "\(kind): \(item.title)", kind: item.kind, text: part,
                    client: item.client, isGeneral: item.client.isEmpty, path: item.path
                ))
            }
        }
        for record in memory.records where record.id != excluding {
            let base = "Call \(Self.dateText(record.date)) (\(record.client == MemoryStore.unassigned ? "no project" : record.client))"
            if !record.summary.isEmpty {
                chunks.append(SourceChunk(
                    label: base, kind: "summary", text: String(record.summary.prefix(2500)),
                    client: record.client, isGeneral: false, callId: record.id
                ))
            }
            for part in Self.split(transcript(for: record, excluding: excluding)) {
                chunks.append(SourceChunk(
                    label: base, kind: "transcript", text: part,
                    client: record.client, isGeneral: false, callId: record.id
                ))
            }
        }
        return chunks
    }

    private func search(query: String, client: String, onlyClient: Bool, excluding: String?, limit: Int, cloud: Bool) -> [SourceChunk] {
        let wanted = client.lowercased()
        var chunks = allChunks(excluding: excluding)
        if cloud {
            // Projects marked "keep on this Mac" must never be sent to a cloud AI.
            let hidden = Set(projects.projects.filter { $0.onDeviceOnly == true }.map { $0.name.lowercased() })
            if !hidden.isEmpty { chunks = chunks.filter { $0.isGeneral || !hidden.contains($0.client.lowercased()) } }
        }
        if onlyClient, !wanted.isEmpty {
            chunks = chunks.filter { $0.isGeneral || $0.client.lowercased() == wanted }
        }
        let terms = Set(Self.tokens(query))
        guard !terms.isEmpty, !chunks.isEmpty else { return [] }

        let tokenized = chunks.map { Self.tokens($0.text) }
        var documentFrequency: [String: Int] = [:]
        for tokens in tokenized {
            for token in Set(tokens) where terms.contains(token) { documentFrequency[token, default: 0] += 1 }
        }
        let total = Double(chunks.count)
        var scored: [(score: Double, chunk: SourceChunk)] = []
        for (index, tokens) in tokenized.enumerated() {
            var counts: [String: Int] = [:]
            for token in tokens where terms.contains(token) { counts[token, default: 0] += 1 }
            if counts.isEmpty { continue }
            var score = 0.0
            for (token, count) in counts {
                score += log(1 + total / Double(documentFrequency[token] ?? 1)) * (1 + log(Double(count)))
            }
            if !wanted.isEmpty, chunks[index].client.lowercased() == wanted { score *= 1.5 }
            scored.append((score, chunks[index]))
        }
        return scored.sorted { $0.score > $1.score }.prefix(limit).map { $0.chunk }
    }

    /// The time of the first line in a transcript passage, such as 14:32.
    private static func firstTimestamp(in text: String) -> String? {
        guard let range = text.range(of: "\\[\\d{2}:\\d{2}\\]", options: .regularExpression) else { return nil }
        return String(text[range]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    private static func detail(for chunk: SourceChunk) -> String {
        switch chunk.kind {
        case "transcript":
            if let time = firstTimestamp(in: chunk.text) { return "Transcript, around \(time) into the call" }
            return "Transcript"
        case "summary": return "Call summary"
        case "file": return "File"
        case "email": return "Email"
        case "note": return "Note"
        default: return ""
        }
    }

    /// Background for the AI: general notes, the project brief, the latest calls with this project,
    /// then the passages that best match the query, up to maxChars. Every passage is numbered
    /// ([S1], [S2]…) so an answer can say exactly where each fact came from.
    func context(query: String, client: String, onlyClient: Bool = false, excluding: String?, maxChars: Int, cloud: Bool) -> RetrievedContext {
        var parts: [String] = []
        var sources: [SourceRef] = []
        var seen = Set<String>()
        var used = 0

        @discardableResult
        func add(_ chunk: SourceChunk) -> Bool {
            if seen.contains(chunk.text) { return true }
            let number = sources.count + 1
            let block = "[S\(number)] \(chunk.label) (\(Self.detail(for: chunk)))\n\(chunk.text)"
            if used + block.count > maxChars { return false }
            seen.insert(chunk.text)
            parts.append(block)
            let flat = chunk.text.replacingOccurrences(of: "\n", with: " ")
            sources.append(SourceRef(
                id: number, label: chunk.label, detail: Self.detail(for: chunk),
                snippet: String(flat.prefix(140)), callId: chunk.callId, path: chunk.path
            ))
            used += block.count + 2
            return true
        }

        // Always included: notes that apply to every call (the product, the user, how they work).
        var generalBudget = 4000
        for item in knowledge.items.sorted(by: { $0.date > $1.date }) where item.client.isEmpty {
            if generalBudget < 200 { break }
            let text = String(item.text.prefix(generalBudget))
            generalBudget -= text.count
            add(SourceChunk(label: "\(Self.kindLabel(item.kind)): \(item.title)", kind: item.kind, text: text,
                            client: "", isGeneral: true, path: item.path))
        }

        // Always included: the AI-written brief for this project, if there is one.
        let wanted = client.lowercased()
        if !wanted.isEmpty, let brief = projects.project(named: client)?.brief, !brief.isEmpty {
            add(SourceChunk(label: "Project brief: \(client)", kind: "note", text: String(brief.prefix(4000)),
                            client: client, isGeneral: false))
        }

        // Always included: the latest two calls with this project.
        if !wanted.isEmpty {
            let recent = memory.records
                .filter { $0.client.lowercased() == wanted && $0.id != excluding && !$0.summary.isEmpty }
                .sorted { $0.date > $1.date }
                .prefix(2)
            for record in recent {
                add(SourceChunk(
                    label: "Call \(Self.dateText(record.date)) (\(record.client))", kind: "summary",
                    text: String(record.summary.prefix(2500)), client: record.client, isGeneral: false, callId: record.id
                ))
            }
        }

        for chunk in search(query: query, client: client, onlyClient: onlyClient, excluding: excluding, limit: 24, cloud: cloud) {
            if !add(chunk) { break }
        }
        return RetrievedContext(text: parts.joined(separator: "\n\n"), sources: sources)
    }

    /// Everything filed under a project, oldest first, for writing the project brief.
    func overview(client: String, maxChars: Int) -> RetrievedContext {
        let wanted = client.lowercased()
        var parts: [String] = []
        var used = 0
        func add(_ label: String, _ text: String) {
            let block = "[\(label)]\n\(text)"
            if text.isEmpty || used + block.count > maxChars { return }
            parts.append(block)
            used += block.count + 2
        }
        for item in knowledge.items.filter({ $0.client.lowercased() == wanted }).sorted(by: { $0.date < $1.date }) {
            add("\(Self.kindLabel(item.kind)): \(item.title)", String(item.text.prefix(3500)))
        }
        for record in memory.records.filter({ $0.client.lowercased() == wanted }).sorted(by: { $0.date < $1.date }) {
            let base = "Call \(Self.dateText(record.date)) (\(record.app))"
            if !record.summary.isEmpty {
                add(base + " summary", String(record.summary.prefix(3000)))
            } else {
                add(base + " transcript", String(transcript(for: record, excluding: nil).prefix(2500)))
            }
        }
        return RetrievedContext(text: parts.joined(separator: "\n\n"), sources: [])
    }
}
