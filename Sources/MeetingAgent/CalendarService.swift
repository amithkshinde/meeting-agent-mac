import AppKit
import EventKit
import UserNotifications

/// A meeting on the calendar.
struct UpcomingEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let people: [Attendee]      // everyone except the user
    let hasCallLink: Bool
}

/// A short "get ready" note for a meeting.
struct Briefing: Identifiable, Equatable {
    let id: String              // the event's id
    let title: String
    let project: String         // empty when nothing matched
    let text: String            // Markdown
}

/// Reads the Mac's Calendar (which includes Google Calendar once the Google account is added in
/// System Settings > Internet Accounts) and prepares a briefing a few minutes before each meeting.
final class CalendarService {
    private let store = EKEventStore()
    private let agent: AgentModel
    private let memory: MemoryStore
    private let projects: ProjectStore
    private let knowledge: KnowledgeStore
    private let commitments: CommitmentStore
    private let retriever: Retriever
    private var timer: Timer?
    private var briefed: Set<String>
    private var preparing = Set<String>()

    init(agent: AgentModel, memory: MemoryStore, projects: ProjectStore, knowledge: KnowledgeStore, commitments: CommitmentStore, retriever: Retriever) {
        self.agent = agent
        self.memory = memory
        self.projects = projects
        self.knowledge = knowledge
        self.commitments = commitments
        self.retriever = retriever
        self.briefed = Set(UserDefaults.standard.stringArray(forKey: "briefedEvents") ?? [])
    }

    var enabled: Bool { UserDefaults.standard.object(forKey: "calendarOn") as? Bool ?? true }

    var authorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }

    // MARK: - Setup

    func start() {
        agent.calendarConnected = authorized
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func connect() {
        store.requestFullAccessToEvents { [weak self] granted, error in
            DispatchQueue.main.async {
                if let error { Log.write("calendar access: \(error.localizedDescription)") }
                self?.agent.calendarConnected = granted
                if granted { self?.requestNotifications() }
                self?.refresh()
            }
        }
    }

    private func requestNotifications() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Reading the calendar

    func refresh() {
        let connected = authorized
        if agent.calendarConnected != connected { agent.calendarConnected = connected }
        guard connected, enabled else {
            if !agent.upcoming.isEmpty { agent.upcoming = [] }
            return
        }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-15 * 60),
            end: now.addingTimeInterval(36 * 3600),
            calendars: nil
        )
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .filter { event in
                let me = event.attendees?.first(where: { $0.isCurrentUser })
                return me?.participantStatus != .declined
            }
            .sorted { $0.startDate < $1.startDate }
            .prefix(8)
            .map { Self.convert($0) }
        let next = Array(events)
        if next != agent.upcoming { agent.upcoming = next }

        // Brief the user a few minutes before a meeting starts.
        for event in next where !briefed.contains(event.id) {
            let minutes = event.start.timeIntervalSince(now) / 60
            if minutes > 0, minutes <= 7, !event.people.isEmpty || event.hasCallLink {
                briefed.insert(event.id)
                UserDefaults.standard.set(Array(briefed.suffix(60)), forKey: "briefedEvents")
                prepare(event, notify: true)
            }
        }
    }

    /// The meeting happening now (or starting within ten minutes), if any.
    func currentEvent(at date: Date = Date()) -> UpcomingEvent? {
        guard authorized, enabled else { return nil }
        let candidates = agent.upcoming.filter { $0.start.addingTimeInterval(-600) <= date && $0.end >= date }
        return candidates.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
    }

    private static func convert(_ event: EKEvent) -> UpcomingEvent {
        var people: [Attendee] = []
        var seen = Set<String>()
        func add(_ participant: EKParticipant?) {
            guard let participant, !participant.isCurrentUser else { return }
            let email = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
            let name = (participant.name ?? "").trimmed.isEmpty
                ? String(email.split(separator: "@").first ?? "Guest")
                : (participant.name ?? "")
            let key = email.isEmpty ? name.lowercased() : email.lowercased()
            if seen.insert(key).inserted { people.append(Attendee(name: name, email: email)) }
        }
        add(event.organizer)
        for participant in event.attendees ?? [] { add(participant) }

        let haystack = [event.location, event.notes, event.url?.absoluteString].compactMap { $0 }.joined(separator: " ").lowercased()
        let link = ["meet.google.com", "zoom.us", "teams.microsoft.com", "teams.live.com", "webex.com"].contains { haystack.contains($0) }
        return UpcomingEvent(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: (event.title ?? "Meeting").trimmed.isEmpty ? "Meeting" : (event.title ?? "Meeting"),
            start: event.startDate,
            end: event.endDate,
            people: people,
            hasCallLink: link
        )
    }

    // MARK: - Briefings

    /// Works out which project a meeting belongs to, from its title and the people invited.
    func matchProject(for event: UpcomingEvent) -> String {
        let title = event.title.lowercased()
        let names = projects.names(memory: memory, knowledge: knowledge)
        if let hit = names.first(where: { !$0.isEmpty && title.contains($0.lowercased()) }) { return hit }

        // Otherwise, the project whose earlier calls had the most of the same people.
        let invited = Set(event.people.map { $0.email.isEmpty ? $0.name.lowercased() : $0.email.lowercased() })
        var scores: [String: Int] = [:]
        for record in memory.records where record.client != MemoryStore.unassigned {
            for person in record.attendees ?? [] {
                let key = person.email.isEmpty ? person.name.lowercased() : person.email.lowercased()
                if invited.contains(key) { scores[record.client, default: 0] += 1 }
            }
        }
        return scores.max { $0.value < $1.value }?.key ?? ""
    }

    /// Writes the briefing for a meeting. `notify` also shows a notification when it is ready.
    func prepare(_ event: UpcomingEvent, notify: Bool) {
        guard !preparing.contains(event.id) else { return }
        let project = matchProject(for: event)
        guard let key = AIAccess.key(project: project, projects: projects) else {
            agent.raise(AppAlert(id: "briefing-key", message: "Connect the AI to get briefings before meetings.", button: "Connect", section: LibraryModel.settingsKey))
            return
        }
        preparing.insert(event.id)
        agent.preparing.insert(event.id)

        let material = project.isEmpty ? "" : retriever.overview(client: project, maxChars: 14_000).text
        let promises = project.isEmpty ? "" : commitments.openLines(project: project, memory: memory)
        let people = event.people.map { $0.name }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMM, h:mm a"
        let prompt = "Meeting: \(event.title)\nWhen: \(formatter.string(from: event.start))\n"
            + (people.isEmpty ? "" : "Invited: \(people.joined(separator: ", "))\n")
            + (project.isEmpty ? "No matching project was found.\n" : "Project: \(project)\n")
            + (material.isEmpty ? "" : "\nSources:\n\(material)\n")
            + (promises.isEmpty ? "" : "\nOpen promises:\n\(promises)\n")
            + "\nWrite the briefing now."

        Task { @MainActor in
            defer {
                self.preparing.remove(event.id)
                self.agent.preparing.remove(event.id)
            }
            do {
                let text = try await ChatService.complete(key: key, system: CalendarService.briefingSystem, prompt: prompt, maxTokens: 700)
                self.agent.briefings[event.id] = Briefing(id: event.id, title: event.title, project: project, text: text)
                self.agent.clearAlert("briefing-key")
                if notify { self.notify(event: event, project: project) }
            } catch {
                Log.write("briefing failed: \(error.localizedDescription)")
                if case ChatError.badKey = error {
                    self.agent.raise(AppAlert(id: "key", message: "Your AI key was rejected. Paste a new one in Settings.", button: "Fix it", section: LibraryModel.settingsKey))
                }
            }
        }
    }

    private func notify(event: UpcomingEvent, project: String) {
        let content = UNMutableNotificationContent()
        let minutes = max(1, Int(event.start.timeIntervalSinceNow / 60))
        content.title = minutes <= 1 ? "\(event.title) is starting" : "\(event.title) in \(minutes) min"
        content.body = project.isEmpty ? "Your briefing is ready." : "Your briefing for \(project) is ready."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "briefing-\(event.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    static let briefingSystem = """
    You prepare the user for a meeting that is about to start. Use only the sources you are given and never invent facts. \
    Reply in Markdown with exactly these sections: ## Last time (two or three short bullets), ## Open promises (who owes what, and say if it is overdue), \
    ## Ask these (three sharp questions), ## Watch out for (zero to two risks). \
    If there are no sources, say so in one line, then give three good general questions based on the meeting title and the people invited. \
    Under 170 words. Write in English.
    """
}
