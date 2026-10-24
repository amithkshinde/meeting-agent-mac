import Foundation

/// Something somebody promised to do, found in a call or added by hand.
struct Commitment: Codable, Identifiable, Equatable {
    var id: String
    var callId: String      // empty when added by hand
    var project: String     // used for things added by hand; calls use the call's project
    var owner: String       // "You" or the other person's name
    var text: String
    var due: Date?
    var done: Bool
    var created: Date

    var isMine: Bool { owner == "You" }

    var isOverdue: Bool {
        guard let due, !done else { return false }
        return due < Calendar.current.startOfDay(for: Date())
    }
}

/// commitments.json next to the recordings. Everything stays on this Mac.
final class CommitmentStore {
    private let url = Log.root.appendingPathComponent("commitments.json")
    private(set) var items: [Commitment] = []

    init() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        items = (try? decoder.decode([Commitment].self, from: data)) ?? []
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(items) { try? data.write(to: url, options: .atomic) }
    }

    /// Replaces what was found for a call. Ticked items stay ticked if they come back with the same wording.
    func replace(callId: String, with fresh: [Commitment]) {
        let doneBefore = Set(items.filter { $0.callId == callId && $0.done }.map { $0.text.lowercased() })
        items.removeAll { $0.callId == callId }
        for var item in fresh {
            if doneBefore.contains(item.text.lowercased()) { item.done = true }
            items.append(item)
        }
        save()
    }

    func add(_ item: Commitment) {
        items.append(item)
        save()
    }

    func setDone(id: String, _ done: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].done = done
        save()
    }

    func remove(id: String) {
        items.removeAll { $0.id == id }
        save()
    }

    /// Keeps hand-added promises with their project when it is renamed or merged.
    func reassign(from old: String, to new: String) {
        var changed = false
        for index in items.indices where items[index].callId.isEmpty && items[index].project.lowercased() == old.lowercased() {
            items[index].project = new
            changed = true
        }
        if changed { save() }
    }

    /// The project a promise belongs to: its call's project, or the one it was added under.
    func project(of item: Commitment, memory: MemoryStore) -> String {
        if !item.callId.isEmpty, let record = memory.records.first(where: { $0.id == item.callId }) {
            return record.client == MemoryStore.unassigned ? "" : record.client
        }
        return item.project
    }

    /// Open promises for a project as plain lines, ready to put in front of the AI.
    func openLines(project: String, memory: MemoryStore) -> String {
        let wanted = project.lowercased()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let lines = items
            .filter { !$0.done && self.project(of: $0, memory: memory).lowercased() == wanted }
            .prefix(15)
            .map { item -> String in
                let who = item.isMine ? "You owe" : "\(item.owner) owes you"
                let when = item.due.map { " (due \(formatter.string(from: $0))\(item.isOverdue ? ", OVERDUE" : ""))" } ?? ""
                return "- \(who): \(item.text)\(when)"
            }
        return lines.joined(separator: "\n")
    }
}
