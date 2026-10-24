import Foundation

/// Where feedback goes. Set these in Resources/Info.plist (keys FeedbackEmail and FeedbackEndpoint),
/// so nobody's address has to be written into the source code.
enum FeedbackConfig {
    static let repo = "amithkshinde/meeting-agent-mac"

    /// An address the "Send by email" button writes to. Empty means the button is hidden.
    static var email: String { plist("FeedbackEmail") }

    /// A web address that accepts the feedback as JSON (a Google Apps Script, Formspree, Zapier or
    /// similar). When set, Send posts to it in the background, which is the only fully anonymous route.
    static var endpoint: URL? {
        let text = plist("FeedbackEndpoint")
        guard text.lowercased().hasPrefix("https://") else { return nil }
        return URL(string: text)
    }

    private static func plist(_ key: String) -> String {
        let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FeedbackKind: String, Codable, CaseIterable, Identifiable {
    case idea, bug, praise, question

    var id: String { rawValue }

    var label: String {
        switch self {
        case .idea: return "Idea"
        case .bug: return "Something broke"
        case .praise: return "What I liked"
        case .question: return "Question"
        }
    }

    var icon: String {
        switch self {
        case .idea: return "lightbulb"
        case .bug: return "ladybug"
        case .praise: return "heart"
        case .question: return "questionmark.bubble"
        }
    }

    var prompt: String {
        switch self {
        case .idea: return "What do you wish it did, or did differently?"
        case .bug: return "What happened, and what did you expect? If you can, say what you clicked just before."
        case .praise: return "What worked well for you?"
        case .question: return "What are you trying to do?"
        }
    }
}

/// One piece of feedback, as saved on this Mac.
struct FeedbackEntry: Codable, Identifiable, Equatable {
    var id: String
    var date: Date
    var kind: FeedbackKind
    var rating: Int?          // 1 to 5, or nil if not given
    var message: String
    var anonymous: Bool
    var name: String
    var email: String
    var details: String       // app version, macOS and chip, and optionally the end of the activity log
    var sentVia: String?      // "online", "email", "github", "copied", or nil if it was only saved

    init(kind: FeedbackKind, rating: Int?, message: String, anonymous: Bool, name: String, email: String, details: String, date: Date = Date()) {
        self.id = UUID().uuidString
        self.date = date
        self.kind = kind
        self.rating = rating
        self.message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        self.anonymous = anonymous
        // An anonymous entry never carries a name or address, even if the boxes were filled in earlier.
        self.name = anonymous ? "" : name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.email = anonymous ? "" : email.trimmingCharacters(in: .whitespacesAndNewlines)
        self.details = details
    }

    var canReply: Bool { !anonymous && FeedbackCompose.isValidEmail(email) }
}

enum FeedbackCompose {
    /// Light check only: something@something.something with no spaces.
    static func isValidEmail(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.contains(" "), let at = value.firstIndex(of: "@"), at != value.startIndex else { return false }
        let domain = value[value.index(after: at)...]
        guard !domain.contains("@"), let dot = domain.lastIndex(of: "."), dot != domain.startIndex else { return false }
        return domain.index(after: dot) != domain.endIndex
    }

    static func stars(_ rating: Int?) -> String {
        guard let rating, (1...5).contains(rating) else { return "" }
        return String(repeating: "★", count: rating) + String(repeating: "☆", count: 5 - rating)
    }

    static func subject(for entry: FeedbackEntry) -> String {
        let first = entry.message.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? ""
        let short = first.count > 60 ? String(first.prefix(60)) + "…" : first
        return "Meeting Agent feedback · \(entry.kind.label)" + (short.isEmpty ? "" : " · \(short)")
    }

    /// Plain text, used for the email, the GitHub issue and the clipboard.
    static func body(for entry: FeedbackEntry) -> String {
        var lines: [String] = []
        lines.append("Type: \(entry.kind.label)")
        if !stars(entry.rating).isEmpty { lines.append("Overall: \(stars(entry.rating)) (\(entry.rating ?? 0) of 5)") }
        lines.append("")
        lines.append(entry.message)
        lines.append("")
        lines.append("—")
        if entry.anonymous {
            lines.append("From: sent anonymously")
        } else {
            let who = entry.name.isEmpty ? "(no name given)" : entry.name
            lines.append("From: \(who)")
            lines.append("Reply to: " + (entry.email.isEmpty ? "(no email given)" : entry.email))
        }
        if !entry.details.isEmpty {
            lines.append("")
            lines.append(entry.details)
        }
        return lines.joined(separator: "\n")
    }

    static func mailtoURL(to address: String, entry: FeedbackEntry) -> URL? {
        guard isValidEmail(address) else { return nil }
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = address
        parts.queryItems = [
            URLQueryItem(name: "subject", value: subject(for: entry)),
            URLQueryItem(name: "body", value: body(for: entry))
        ]
        // URLComponents leaves "+" and "&" alone inside values in some cases; make them safe.
        guard let raw = parts.percentEncodedQuery else { return parts.url }
        let safe = raw.replacingOccurrences(of: "+", with: "%2B")
        parts.percentEncodedQuery = safe
        return parts.url
    }

    static func githubURL(repo: String, entry: FeedbackEntry) -> URL? {
        var parts = URLComponents(string: "https://github.com/\(repo)/issues/new")
        var items = [
            URLQueryItem(name: "title", value: subject(for: entry)),
            URLQueryItem(name: "body", value: body(for: entry))
        ]
        switch entry.kind {
        case .bug: items.append(URLQueryItem(name: "labels", value: "bug"))
        case .idea: items.append(URLQueryItem(name: "labels", value: "enhancement"))
        case .question: items.append(URLQueryItem(name: "labels", value: "question"))
        case .praise: break
        }
        parts?.queryItems = items
        return parts?.url
    }

    /// What is posted to an endpoint. Anonymous entries have no name or email in them at all.
    static func json(for entry: FeedbackEntry, app: String, version: String) -> Data? {
        var payload: [String: Any] = [
            "kind": entry.kind.rawValue,
            "message": entry.message,
            "anonymous": entry.anonymous,
            "date": ISO8601DateFormatter().string(from: entry.date),
            "app": app,
            "version": version,
            "details": entry.details,
            "text": body(for: entry),
            "subject": subject(for: entry)
        ]
        if let rating = entry.rating { payload["rating"] = rating }
        if !entry.anonymous {
            payload["name"] = entry.name
            payload["email"] = entry.email
        }
        return try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}

/// Every piece of feedback is kept in feedback.json beside the call recordings.
enum FeedbackStore {
    static func load(from url: URL) -> [FeedbackEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([FeedbackEntry].self, from: data)) ?? []).sorted { $0.date > $1.date }
    }

    static func save(_ entries: [FeedbackEntry], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) { try? data.write(to: url, options: .atomic) }
    }
}
