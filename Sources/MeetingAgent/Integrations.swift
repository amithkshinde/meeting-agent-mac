import AppKit
import EventKit
import Foundation
import Security

// MARK: - PDF

enum PDFExport {
    /// Writes `markdown` to a PDF at `url`. Must be called on the main thread. Returns false if it couldn't.
    @MainActor
    static func write(markdown: String, title: String, to url: URL) -> Bool {
        let html = CallExport.html(fromMarkdown: markdown, title: title)
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
              ) else { return false }

        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 595, height: 842)   // A4
        info.leftMargin = 54
        info.rightMargin = 54
        info.topMargin = 54
        info.bottomMargin = 54
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        textView.isEditable = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(attributed)
        if let container = textView.textContainer, let layout = textView.layoutManager {
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container)
            textView.setFrameSize(NSSize(width: width, height: ceil(used.height) + 20))
        }

        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run()
    }
}

// MARK: - Reminders

enum RemindersExport {
    private static let sentKey = "remindersSent"

    static func alreadySent(_ id: String) -> Bool {
        (UserDefaults.standard.stringArray(forKey: sentKey) ?? []).contains(id)
    }

    /// Adds each promise to the Reminders app. Returns how many were added, or a plain-English problem.
    static func send(_ items: [Commitment], source: String) async -> (added: Int, problem: String?) {
        let store = EKEventStore()
        do {
            let granted = try await store.requestFullAccessToReminders()
            guard granted else {
                return (0, "Reminders access is off. Allow Meeting Agent in System Settings › Privacy & Security › Reminders.")
            }
        } catch {
            return (0, "Couldn't get access to Reminders: \(error.localizedDescription)")
        }
        guard let list = store.defaultCalendarForNewReminders() else {
            return (0, "Reminders has no list to add to. Open the Reminders app once and try again.")
        }

        var sent = UserDefaults.standard.stringArray(forKey: sentKey) ?? []
        var added = 0
        for item in items where !sent.contains(item.id) {
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = list
            reminder.title = item.isMine ? item.text : "\(item.owner): \(item.text)"
            reminder.notes = "From \(source), added by Meeting Agent."
            if let due = item.due {
                reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day], from: due)
            }
            do {
                try store.save(reminder, commit: false)
                sent.append(item.id)
                added += 1
            } catch {
                Log.write("reminder not saved: \(error.localizedDescription)")
            }
        }
        do {
            try store.commit()
        } catch {
            return (0, "Couldn't save to Reminders: \(error.localizedDescription)")
        }
        UserDefaults.standard.set(sent, forKey: sentKey)
        return (added, nil)
    }
}

// MARK: - Notion

/// Small keychain wrapper for extra secrets. The AI key has its own.
enum SecretStore {
    private static let service = "com.amithshinde.meetingagent"

    static func read(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String, account: String) {
        delete(account)
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: Data(value.utf8),
        ]
        SecItemAdd(attributes as CFDictionary, nil)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum NotionService {
    static let tokenAccount = "notion-token"
    private static let databaseKey = "notionDatabase"
    private static let version = "2022-06-28"

    static var token: String? { SecretStore.read(tokenAccount) }
    static var databaseID: String { UserDefaults.standard.string(forKey: databaseKey) ?? "" }
    static var isConfigured: Bool { !(token ?? "").isEmpty && !databaseID.isEmpty }

    static func save(token: String, databaseLink: String) -> String? {
        let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return "Paste the Notion integration token first." }
        guard let id = parseDatabaseID(databaseLink) else {
            return "That doesn't look like a Notion database link. Open the database in Notion, choose Copy link, and paste it here."
        }
        SecretStore.save(clean, account: tokenAccount)
        UserDefaults.standard.set(id, forKey: databaseKey)
        return nil
    }

    static func disconnect() {
        SecretStore.delete(tokenAccount)
        UserDefaults.standard.removeObject(forKey: databaseKey)
    }

    /// Finds the 32-character id in a Notion link, with or without dashes.
    static func parseDatabaseID(_ link: String) -> String? {
        let withoutQuery = link.components(separatedBy: "?").first ?? link
        let hex = withoutQuery.replacingOccurrences(of: "-", with: "")
        guard hex.count >= 32 else { return nil }
        let tail = String(hex.suffix(32))
        return tail.allSatisfy({ $0.isHexDigit }) ? tail.lowercased() : nil
    }

    private struct Schema {
        var title: String
        var date: String?
        var name: String
    }

    private static func request(_ path: String, method: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let token, let url = URL(string: "https://api.notion.com/v1/\(path)") else {
            throw ChatError.message("Notion isn't connected yet. Add it in Settings.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(version, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if status == 401 { throw ChatError.message("Notion rejected the token. Check that you copied the whole integration token.") }
        if status == 404 { throw ChatError.message("Notion can't see that database. Open the database, choose ••• › Connections, and add your integration.") }
        if status >= 400 {
            let detail = (object["message"] as? String) ?? "status \(status)"
            throw ChatError.message("Notion said: \(detail)")
        }
        return object
    }

    private static func schema() async throws -> Schema {
        let database = try await request("databases/\(databaseID)", method: "GET")
        let properties = database["properties"] as? [String: Any] ?? [:]
        var title = "Name"
        var date: String?
        for (name, value) in properties {
            let type = (value as? [String: Any])?["type"] as? String
            if type == "title" { title = name }
            if type == "date", date == nil { date = name }
        }
        let titleText = ((database["title"] as? [[String: Any]])?.first?["plain_text"] as? String) ?? "your database"
        return Schema(title: title, date: date, name: titleText)
    }

    /// Checks the token and the database link. Returns the database's name.
    static func test() async throws -> String {
        try await schema().name
    }

    /// Adds each promise as a row in the database. Returns how many were added.
    static func send(_ items: [Commitment], source: String) async throws -> Int {
        let schema = try await schema()
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        var added = 0
        for item in items {
            var properties: [String: Any] = [
                schema.title: ["title": [["text": ["content": item.isMine ? item.text : "\(item.owner): \(item.text)"]]]],
            ]
            if let dateName = schema.date, let due = item.due {
                properties[dateName] = ["date": ["start": day.string(from: due)]]
            }
            let note: [String: Any] = [
                "object": "block",
                "type": "paragraph",
                "paragraph": ["rich_text": [["type": "text", "text": ["content": "From \(source). Added by Meeting Agent."]]]],
            ]
            let body: [String: Any] = [
                "parent": ["database_id": databaseID],
                "properties": properties,
                "children": [note],
            ]
            _ = try await request("pages", method: "POST", body: body)
            added += 1
        }
        return added
    }
}
