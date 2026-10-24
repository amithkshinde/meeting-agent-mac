import Foundation

/// Everything that happens after a call ends: clean the transcript, write the summary,
/// pull out promises, and refresh the project brief.
final class CallProcessor {
    private let memory: MemoryStore
    private let knowledge: KnowledgeStore
    private let projects: ProjectStore
    private let commitments: CommitmentStore
    private let agent: AgentModel
    weak var library: LibraryModel?

    init(memory: MemoryStore, knowledge: KnowledgeStore, projects: ProjectStore, commitments: CommitmentStore, agent: AgentModel) {
        self.memory = memory
        self.knowledge = knowledge
        self.projects = projects
        self.commitments = commitments
        self.agent = agent
    }

    // MARK: - Prompts

    static let summarySystem = """
    You write short, useful notes for the user after a call. "You" is the user and "Them" is everyone else. \
    The transcript is automatic speech recognition, so names and numbers may be wrong. Mark anything unclear instead of guessing. \
    If you are given a list of the people on the call, use their names where the transcript makes clear who said what. \
    A line may begin with a real person's name instead of "Them", when the video showed who was speaking. Use those names. \
    Write in English, in Markdown, with exactly these sections and nothing else: \
    ## Summary (three sentences at most), ## Key points, ## Decisions, \
    ## Action items (say who owns each one, and any date mentioned), ## Open questions, ## Raise next time. \
    Write "None." for an empty section. Only use what the transcript says.
    """

    /// Added to the summary prompt when the call shared several screens (a design review).
    static let byScreenNote = """
     The call shared several screens. Lines like "--- Screen 2 shown at 12:30 ---" mark when each one appeared. \
    After the other sections, add "## By screen" with a "### Screen N" heading for each screen that was discussed, \
    listing the feedback, questions and decisions about that screen as short bullets. Skip screens nobody discussed.
    """

    static var cleanSystem: String {
        """
    You fix the output of automatic speech recognition for a call transcript. Each line looks like "[mm:ss] You: text" or "[mm:ss] Them: text". \
    The speech is English, Hindi, or a mix of both (Hinglish), and sometimes Kannada. \
    Fix obvious recognition mistakes, the spelling of names and numbers, punctuation and capital letters, using the other lines and the names of the people on the call for context. \
    \(CallProcessor.scriptInstruction) \
    Keep every line, in the same order, with the same timestamp. Do not summarise, translate, add or remove sentences, and do not guess: if you are unsure, leave the words as they are. \
    Each line starts with a speaker label: "You", "Them", or a person's name. Keep every label exactly as written. \
    If exactly one other person was on the call, you may write their name instead of "Them". \
    Reply with the corrected lines only, nothing before or after.
    """
    }

    static let commitmentsSystem = """
    You find promises in a call transcript. "You" is the user and "Them" is everyone else. \
    Reply with JSON only, in exactly this shape: {"items": [{"owner": "You", "text": "...", "due": "2026-10-24"}]}. \
    Include only things someone clearly promised or agreed to do. "owner" is "You" for the user, otherwise the person's name if it is known, otherwise "Them". \
    "text" is under 20 words and says what will be done. "due" is a date as YYYY-MM-DD worked out from the call date (for example "by Friday"), or an empty string if no date was given. \
    At most 12 items. Never invent anything. If there are no promises, return {"items": []}.
    """

    /// How Hindi should be written in the cleaned transcript. Set in Settings.
    static var scriptInstruction: String {
        switch UserDefaults.standard.string(forKey: "scriptPref") ?? "keep" {
        case "roman":
            return "Write every Hindi word in Roman letters (Hinglish), the way people type on a phone, for example \"kal meeting hai\". Turn any Devanagari into Roman letters. Leave English words as they are."
        case "devanagari":
            return "Write Hindi words in Devanagari. Leave English words in English."
        default:
            return "Keep the same script the line already uses: Hindi in Roman letters stays in Roman letters, Devanagari stays Devanagari."
        }
    }

    /// The user's own name as the call app would show it, so their tile is never mistaken for someone else.
    static var userName: String {
        let saved = (UserDefaults.standard.string(forKey: "userDisplayName") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return saved.isEmpty ? NSFullUserName() : saved
    }

    /// Puts real names on "Them" lines using who the video showed speaking. The first time it keeps the
    /// original as transcript-raw.txt, and it always works from that original, so it is safe to run again.
    @discardableResult
    static func attributeSpeakers(folder: URL) -> SpeakerAttribution.Result? {
        let samples = SpeakerLog.load(folder)
        guard !samples.isEmpty else { return nil }
        let rawURL = folder.appendingPathComponent("transcript-raw.txt")
        let liveURL = folder.appendingPathComponent("transcript.txt")
        if !FileManager.default.fileExists(atPath: rawURL.path) {
            try? FileManager.default.copyItem(at: liveURL, to: rawURL)
        }
        guard let source = try? String(contentsOf: rawURL, encoding: .utf8) else { return nil }
        let result = SpeakerAttribution.apply(to: source, samples: samples, exclude: [userName])
        guard result.named > 0 else { return result }
        try? result.text.write(to: liveURL, atomically: true, encoding: .utf8)
        // Anything cleaned from the old text is out of date now.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("transcript-clean.txt"))
        Log.write("speakers: named \(result.named) of \(result.total) lines (\(result.names.joined(separator: ", ")))")
        return result
    }

    // MARK: - The pipeline

    /// Runs after a call. `wait` gives the speech engine a moment to finish the last sentence.
    func process(folder: URL, wait: Bool) {
        let id = folder.lastPathComponent
        guard let first = memory.records.first(where: { $0.id == id }) else { return }
        agent.summarizing = true

        Task { @MainActor in
            defer { self.agent.summarizing = false }
            if wait { try? await Task.sleep(nanoseconds: 4_000_000_000) }

            CallProcessor.attributeSpeakers(folder: folder)
            let raw = (try? String(contentsOf: folder.appendingPathComponent("transcript.txt"), encoding: .utf8)) ?? ""
            guard raw.count > 60 else {
                Log.write("summary skipped: the transcript is too short")
                return
            }
            guard let key = AIAccess.key(project: first.client, projects: self.projects) else {
                Log.write("summary skipped: no AI available")
                return
            }

            // 1. Clean up the transcript (helps most with Hindi and mixed Hindi-English).
            var transcript = raw
            do {
                if let cleaned = try await self.clean(raw, key: key, people: (first.attendees ?? []).map { $0.name }) {
                    transcript = cleaned
                    try? cleaned.write(to: folder.appendingPathComponent("transcript-clean.txt"), atomically: true, encoding: .utf8)
                    Log.write("transcript cleaned")
                }
            } catch ChatError.badKey {
                self.keyRejected()
                return
            } catch {
                Log.write("transcript clean-up skipped: \(error.localizedDescription)")
            }

            // 2. Summary.
            let current = self.memory.records.first(where: { $0.id == id }) ?? first
            let client = current.client
            let earlier = self.memory.context(client: client, excluding: id)
            let people = (current.attendees ?? []).map { $0.name }
            let peopleLine = people.isEmpty ? "" : "People on the call besides the user: \(people.joined(separator: ", ")).\n\n"
            let screens = ScreenIndex.load(folder)
            let marked = screens.count >= 2 ? ScreenIndex.annotate(transcript, screens: screens) : transcript
            let prompt = (earlier.isEmpty ? "" : "Earlier calls with this client:\n\(earlier)\n\n")
                + peopleLine
                + "Transcript of this call:\n\(String(marked.suffix(60_000)))\n\nWrite the notes now."
            do {
                let system = CallProcessor.summarySystem + (screens.count >= 2 ? CallProcessor.byScreenNote : "")
                let summary = try await ChatService.complete(key: key, system: system, prompt: prompt, maxTokens: screens.count >= 2 ? 2000 : 1500)
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                let header = "# Call summary\n\n- Project: \(client)\n- App: \(current.app)\n- Date: \(formatter.string(from: current.date))\n\n"
                let url = folder.appendingPathComponent("summary.md")
                try (header + summary).write(to: url, atomically: true, encoding: .utf8)
                var updated = self.memory.records.first(where: { $0.id == id }) ?? current
                updated.summary = summary
                self.memory.upsert(updated)
                self.agent.lastSummaryURL = url
                self.agent.clearAlert("summary")
                Log.write("summary saved: \(url.path)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
                    if self?.agent.lastSummaryURL == url { self?.agent.lastSummaryURL = nil }
                }
            } catch ChatError.badKey {
                self.keyRejected()
                return
            } catch {
                Log.write("summary failed: \(error.localizedDescription)")
                self.agent.raise(AppAlert(id: "summary", message: "I couldn't write the call summary: \(error.localizedDescription)", button: "Open app"))
                return
            }

            // 3. Promises.
            let latest = self.memory.records.first(where: { $0.id == id }) ?? current
            if let found = await self.promises(in: transcript, record: latest, key: key) {
                self.commitments.replace(callId: id, with: found)
            }

            // 4. Refresh the project brief and the lists.
            if latest.client != MemoryStore.unassigned { self.library?.generateBrief(for: latest.client, quiet: true) }
            self.library?.reload()
        }
    }

    private func keyRejected() {
        if AIAccess.localEverywhere == false { Keychain.delete() }
        agent.hasKey = false
        agent.raise(AppAlert(id: "key", message: "Your AI key was rejected, so I can't write summaries or suggestions. Paste a new one in Settings.", button: "Fix it", section: LibraryModel.settingsKey))
    }

    // MARK: - Steps (these only compute; the caller applies the results)

    /// Fixes recognition mistakes a few lines at a time. Returns nil if the transcript is too short or too long to bother.
    private func clean(_ raw: String, key: String, people: [String]) async throws -> String? {
        let lines = raw.components(separatedBy: "\n").filter { !$0.trimmed.isEmpty }
        guard lines.count >= 3, raw.count <= 120_000 else { return nil }

        let limit = key == AIAccess.localKey ? 2200 : 5000
        var chunks: [[String]] = []
        var current: [String] = []
        var size = 0
        for line in lines {
            if size + line.count > limit, !current.isEmpty {
                chunks.append(current)
                current = []
                size = 0
            }
            current.append(line)
            size += line.count + 1
        }
        if !current.isEmpty { chunks.append(current) }

        let peopleLine = people.isEmpty ? "" : "People on the call besides the user: \(people.joined(separator: ", ")).\n\n"
        var output: [String] = []
        for chunk in chunks {
            let prompt = peopleLine + "Transcript lines:\n" + chunk.joined(separator: "\n")
            var reply: String?
            for attempt in 0..<2 {
                do {
                    reply = try await ChatService.complete(key: key, system: CallProcessor.cleanSystem, prompt: prompt, maxTokens: 2600)
                    break
                } catch ChatError.badKey {
                    throw ChatError.badKey
                } catch {
                    // Free keys have a requests-per-minute limit. Wait a little and try once more.
                    if attempt == 0 { try? await Task.sleep(nanoseconds: 20_000_000_000) }
                }
            }
            let fixed = (reply ?? "")
                .components(separatedBy: "\n")
                .map { $0.trimmed }
                .filter { $0.hasPrefix("[") }
            output += CallProcessor.looksRight(original: chunk, fixed: fixed) ? fixed : chunk
        }
        return output.joined(separator: "\n")
    }

    /// A safety net: if the "fixed" text lost or gained lots of lines, keep the original.
    private static func looksRight(original: [String], fixed: [String]) -> Bool {
        guard !fixed.isEmpty, !original.isEmpty else { return false }
        let lineRatio = Double(fixed.count) / Double(original.count)
        let charRatio = Double(fixed.joined().count) / Double(max(1, original.joined().count))
        return lineRatio > 0.85 && lineRatio < 1.15 && charRatio > 0.6 && charRatio < 1.6
    }

    private func promises(in transcript: String, record: CallRecord, key: String) async -> [Commitment]? {
        let dayFormat = DateFormatter()
        dayFormat.dateFormat = "EEEE, d MMMM yyyy"
        let people = (record.attendees ?? []).map { $0.name }
        let peopleLine = people.isEmpty ? "" : "People on the call besides the user: \(people.joined(separator: ", ")).\n"
        let prompt = "Call date: \(dayFormat.string(from: record.date))\n\(peopleLine)Transcript:\n\(String(transcript.suffix(40_000)))\n\nReturn the JSON now."
        do {
            let reply = try await ChatService.complete(key: key, system: CallProcessor.commitmentsSystem, prompt: prompt, json: true, maxTokens: 900)
            guard let object = CallProcessor.jsonObject(from: reply), let list = object["items"] as? [[String: Any]] else { return nil }
            let parse = DateFormatter()
            parse.dateFormat = "yyyy-MM-dd"
            return list.prefix(12).compactMap { entry -> Commitment? in
                guard let text = (entry["text"] as? String)?.trimmed, !text.isEmpty else { return nil }
                var owner = ((entry["owner"] as? String) ?? "Them").trimmed
                if owner.isEmpty { owner = "Them" }
                if ["you", "me", "i", "user"].contains(owner.lowercased()) { owner = "You" }
                let due = (entry["due"] as? String).flatMap { parse.date(from: $0.trimmed) }
                return Commitment(id: UUID().uuidString, callId: record.id, project: record.client, owner: owner, text: text, due: due, done: false, created: Date())
            }
        } catch {
            Log.write("promises not extracted: \(error.localizedDescription)")
            return nil
        }
    }

    static func jsonObject(from reply: String) -> [String: Any]? {
        var text = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"), first < last {
            text = String(text[first...last])
        }
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: - Follow-up email

    static let followUpSystem = """
    You write a short follow-up email from the user to the people on a call. Write like a real person: plain, warm, direct, short sentences. \
    No stock phrases such as "I hope this email finds you well" or "Please do not hesitate". Recap what was decided, list the action items with who owns each and any dates, \
    and ask about anything still open. Under 170 words. Use only what the notes say. \
    Reply with JSON only: {"subject": "...", "body": "..."}. The body is plain text with line breaks written as \\n.
    """

    func followUp(for call: CallRecord, key: String) async throws -> (subject: String, body: String) {
        let people = (call.attendees ?? []).map { $0.name }
        let mine = commitments.items.filter { $0.callId == call.id }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        let promises = mine.map { item -> String in
            let who = item.isMine ? "You" : item.owner
            let when = item.due.map { " by \(formatter.string(from: $0))" } ?? ""
            return "- \(who): \(item.text)\(when)"
        }.joined(separator: "\n")
        let prompt = "Call: \(call.title ?? call.app + " call") on \(formatter.string(from: call.date))\n"
            + (people.isEmpty ? "" : "To: \(people.joined(separator: ", "))\n")
            + "\nNotes:\n\(call.summary)\n"
            + (promises.isEmpty ? "" : "\nPromises:\n\(promises)\n")
            + "\nWrite the email now."
        let reply = try await ChatService.complete(key: key, system: CallProcessor.followUpSystem, prompt: prompt, json: true, maxTokens: 700)
        guard let object = CallProcessor.jsonObject(from: reply),
              let subject = (object["subject"] as? String)?.trimmed,
              let body = (object["body"] as? String)?.trimmed, !body.isEmpty else {
            throw ChatError.message("I couldn't write that email. Try again.")
        }
        return (subject, body.replacingOccurrences(of: "\\n", with: "\n"))
    }
}
