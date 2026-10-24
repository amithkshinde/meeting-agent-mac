import Foundation

/// A person on a call, taken from the calendar invite.
struct Attendee: Codable, Equatable, Hashable {
    var name: String
    var email: String
}

/// One finished call, kept so later calls with the same client can refer back to it.
struct CallRecord: Codable, Identifiable {
    var id: String          // the recording folder name
    var client: String
    var date: Date
    var app: String
    var summary: String
    var title: String? = nil            // the calendar event title, when there was one
    var attendees: [Attendee]? = nil    // the other people, when the calendar knew them
}

/// A small file, memory.json, next to the recordings. Everything stays on this Mac.
final class MemoryStore {
    static let unassigned = "Unassigned"

    private let url = Log.root.appendingPathComponent("memory.json")
    private(set) var records: [CallRecord] = []

    init() { load() }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        records = (try? decoder.decode([CallRecord].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(records) {
            try? data.write(to: url, options: .atomic)
        }
    }

    func upsert(_ record: CallRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.append(record)
        }
        save()
    }

    func setClient(id: String, to name: String) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].client = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? Self.unassigned : name
        save()
    }

    /// Moves every call from one project to another (used for merging and deleting projects).
    func reassign(from old: String, to new: String) {
        let wanted = old.lowercased()
        var changed = false
        for index in records.indices where records[index].client.lowercased() == wanted {
            records[index].client = new
            changed = true
        }
        if changed { save() }
    }

    /// Client names, most recently used first.
    func clients() -> [String] {
        var seen = Set<String>()
        var names: [String] = []
        for record in records.sorted(by: { $0.date > $1.date }) {
            let name = record.client
            if name.isEmpty || name == Self.unassigned || seen.contains(name) { continue }
            seen.insert(name)
            names.append(name)
        }
        return names
    }

    /// Summaries of the last few calls with this client, ready to put in front of the AI.
    func context(client: String, excluding id: String?, limit: Int = 3) -> String {
        let wanted = client.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !wanted.isEmpty else { return "" }
        let past = records
            .filter { $0.client.lowercased() == wanted && $0.id != id && !$0.summary.isEmpty }
            .sorted { $0.date > $1.date }
            .prefix(limit)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        var text = past.map { "Call on \(formatter.string(from: $0.date)) (\($0.app)):\n\($0.summary)" }.joined(separator: "\n\n")
        if text.count > 6000 { text = String(text.prefix(6000)) }
        return text
    }
}
