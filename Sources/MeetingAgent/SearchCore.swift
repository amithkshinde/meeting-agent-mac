import Foundation

/// The matching rules behind the search box. No screen code here, so it is easy to test.
enum SearchCore {
    /// "budget  Q3" -> ["budget", "q3"]
    static func tokens(_ query: String) -> [String] {
        query.lowercased()
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;")))
            .filter { !$0.isEmpty }
    }

    /// True when the text contains every word of the query (in any order).
    static func matches(_ text: String, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return false }
        let lower = text.lowercased()
        return tokens.allSatisfy { lower.contains($0) }
    }

    /// How many times the words of the query appear, used to put better matches first.
    static func score(_ text: String, tokens: [String]) -> Int {
        let lower = text.lowercased()
        return tokens.reduce(0) { total, token in total + lower.components(separatedBy: token).count - 1 }
    }

    /// A short piece of `text` around the first match, with "…" where it was cut.
    static func snippet(_ text: String, tokens: [String], radius: Int = 70) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let first = tokens.first(where: { flat.lowercased().contains($0) }),
              let range = flat.lowercased().range(of: first) else {
            return String(flat.prefix(radius * 2))
        }
        let characters = Array(flat)
        let center = flat.distance(from: flat.startIndex, to: range.lowerBound)
        let from = max(0, center - radius)
        let to = min(characters.count, center + first.count + radius)
        var out = String(characters[from..<to]).trimmingCharacters(in: .whitespaces)
        if from > 0 { out = "…" + out }
        if to < characters.count { out += "…" }
        return out
    }
}

/// One result in the search box.
struct SearchHit: Identifiable {
    enum Kind: Int { case call = 0, moment, note, promise, project }

    enum Target {
        case call(id: String, seek: Double?)
        case note(id: String)
        case promises
        case project(name: String)
    }

    let id: String
    let kind: Kind
    let title: String
    let detail: String
    let target: Target

    static func heading(for kind: Kind) -> String {
        switch kind {
        case .call: return "Calls"
        case .moment: return "Moments in calls"
        case .note: return "Notes, files and emails"
        case .promise: return "Promises"
        case .project: return "Projects"
        }
    }
}
