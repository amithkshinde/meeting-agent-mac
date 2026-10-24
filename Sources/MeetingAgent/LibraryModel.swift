import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// State behind the main window. The top level is a project. A project holds calls, files, notes
/// and emails, has an AI-written brief, and can be talked to.
final class LibraryModel: ObservableObject {
    enum ProjectTab { case overview, ask, content }

    static let homeKey = "§home"
    static let allKey = "§all"
    static let generalKey = "§general"
    static let unassignedKey = "§unassigned"
    static let settingsKey = "§settings"
    static let promisesKey = "§promises"
    static let feedbackKey = "§feedback"

    @Published var selection = LibraryModel.homeKey {
        didSet {
            projectTab = isProject ? .overview : .ask
            reload()
        }
    }
    @Published var projectTab = ProjectTab.overview
    @Published var projectNames: [String] = []
    @Published var items: [KnowledgeItem] = []
    @Published var calls: [CallRecord] = []
    @Published var otherCalls: [CallRecord] = []
    @Published var allCalls: [CallRecord] = []
    @Published var unassignedCount = 0
    @Published var chats: [String: [ChatMessage]] = [:]
    @Published var asking = false
    @Published var briefBusy = false
    @Published var briefText = ""
    @Published var briefDate: Date?
    @Published var hasKey = AIAccess.isReady
    @Published var promises: [Commitment] = []
    @Published var status = ""
    @Published var setup = SetupStatus.read()
    @Published var keyTest = ""
    @Published var keyTesting = false
    @Published var detailCall: CallRecord?
    /// When a call is opened from search, the moment (in seconds) to jump to.
    @Published var detailSeek: Double?
    @Published var showSearch = false

    let memory: MemoryStore
    let knowledge: KnowledgeStore
    let projects: ProjectStore
    let retriever: Retriever
    let agent: AgentModel
    let commitments: CommitmentStore
    var processor: CallProcessor?
    private var histories: [String: [(question: String, answer: String)]] = [:]
    private var setupTimer: Timer?

    private static let askSystem = """
    You help the user with everything they have gathered about their projects: notes, files, emails, call summaries and call transcripts. \
    You get numbered sources like [S1], [S2]. Transcripts are automatic speech recognition, so names and numbers may be wrong. \
    "You" is the user and "Them" is the other people. \
    Answer only from the sources, and say so plainly if they do not contain the answer. \
    After every fact, add the number of the source it came from in square brackets, like [S2] or [S1, S3]. \
    Never invent a source number. Be concise and easy to scan.
    """

    private static let briefSystem = """
    You write a project brief for the user from their notes, files, emails and calls. Use only what the sources say, and mark anything unclear. \
    Write in English, in Markdown, with exactly these sections: ## What this is, ## Where things stand, ## People and roles, \
    ## Promises and commitments (who promised what, and any dates), ## Open questions, ## Risks, ## Good questions to ask next. \
    Keep each section short. Write "None found." for an empty section.
    """

    init(memory: MemoryStore, knowledge: KnowledgeStore, projects: ProjectStore, retriever: Retriever, agent: AgentModel, commitments: CommitmentStore) {
        self.commitments = commitments
        self.memory = memory
        self.knowledge = knowledge
        self.projects = projects
        self.retriever = retriever
        self.agent = agent
        reload()
        refreshSetup()
        setupTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refreshSetup()
        }
    }

    // MARK: - Selection helpers

    var isProject: Bool { !selection.hasPrefix("§") }
    var messages: [ChatMessage] { chats[selection] ?? [] }

    /// The project name to file new things under. Empty means "every call".
    var fileUnder: String { isProject ? selection : "" }

    var title: String {
        switch selection {
        case Self.homeKey: return "Home"
        case Self.allKey: return "Everything"
        case Self.generalKey: return "General notes"
        case Self.unassignedKey: return "Unassigned calls"
        case Self.settingsKey: return "Settings"
        case Self.promisesKey: return "Promises"
        case Self.feedbackKey: return "Feedback"
        default: return selection
        }
    }

    func reload() {
        projectNames = projects.names(memory: memory, knowledge: knowledge)
        let wanted = selection.lowercased()
        let everyItem = knowledge.items.sorted { $0.date > $1.date }
        let everyCall = memory.records.sorted { $0.date > $1.date }
        allCalls = everyCall
        unassignedCount = everyCall.filter { $0.client == MemoryStore.unassigned }.count
        switch selection {
        case Self.allKey, Self.homeKey, Self.settingsKey, Self.promisesKey, Self.feedbackKey:
            items = everyItem
            calls = everyCall
        case Self.generalKey:
            items = everyItem.filter { $0.client.isEmpty }
            calls = []
        case Self.unassignedKey:
            items = []
            calls = everyCall.filter { $0.client == MemoryStore.unassigned }
        default:
            items = everyItem.filter { $0.client.lowercased() == wanted }
            calls = everyCall.filter { $0.client.lowercased() == wanted }
        }
        otherCalls = isProject ? everyCall.filter { $0.client.lowercased() != wanted } : []
        let project = isProject ? projects.project(named: selection) : nil
        briefText = project?.brief ?? ""
        briefDate = project?.briefDate
        hasKey = AIAccess.isReady
        promises = commitments.items
    }

    func callCount(in name: String) -> Int {
        memory.records.filter { $0.client.lowercased() == name.lowercased() }.count
    }

    func itemCount(in name: String) -> Int {
        knowledge.items.filter { $0.client.lowercased() == name.lowercased() }.count
    }

    // MARK: - Setup and permissions

    func refreshSetup() {
        let next = SetupStatus.read()
        if next != setup { setup = next }
        if hasKey != next.key { hasKey = next.key }
        if agent.hasKey != next.key { agent.hasKey = next.key }
        if agent.setupDone != next.complete { agent.setupDone = next.complete }
        if agent.screenAccess != next.screen { agent.screenAccess = next.screen }
    }

    enum Permission { case screen, mic, speech }

    func grant(_ permission: Permission) {
        switch permission {
        case .screen:
            if !CGRequestScreenCaptureAccess() { openSettingsPane("Privacy_ScreenCapture") }
        case .mic:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if !granted { self?.openSettingsPane("Privacy_Microphone") }
                    self?.refreshSetup()
                }
            }
        case .speech:
            Task { @MainActor in
                let ok = await LiveTranscriber.requestAuthorization()
                if !ok { openSettingsPane("Privacy_SpeechRecognition") }
                refreshSetup()
            }
        }
    }

    func openSettingsPane(_ name: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(name)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - AI key

    func saveKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.save(trimmed)
        keyTest = ""
        refreshSetup()
        testKey()
    }

    func removeKey() {
        Keychain.delete()
        keyTest = ""
        refreshSetup()
    }

    func testKey() {
        guard !keyTesting else { return }
        guard let key = AIAccess.key() else {
            keyTest = AIAccess.localEverywhere ? AIAccess.localProblem : "No key saved yet."
            return
        }
        keyTesting = true
        keyTest = "Checking…"
        Task { @MainActor in
            do {
                _ = try await ChatService.complete(key: key, system: "Reply with the single word OK.", prompt: "Hello", maxTokens: 20)
                keyTest = key == AIAccess.localKey ? "The on-device AI is ready." : "Connected. The AI is ready."
            } catch {
                keyTest = error.localizedDescription
            }
            keyTesting = false
        }
    }

    // MARK: - Projects

    func createProject(_ name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let canonical = projects.canonical(clean, memory: memory, knowledge: knowledge)
        projects.ensure(canonical)
        selection = canonical
        reload()
    }

    func rename(to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isProject, !clean.isEmpty, clean.lowercased() != selection.lowercased() else { return }
        let target = projects.canonical(clean, memory: memory, knowledge: knowledge)
        let old = selection
        memory.reassign(from: old, to: target)
        knowledge.reassign(from: old, to: target)
        projects.rename(from: old, to: target)
        commitments.reassign(from: old, to: target)
        chats[target] = chats[old]
        selection = target
    }

    func merge(into target: String) {
        guard isProject, target.lowercased() != selection.lowercased() else { return }
        let old = selection
        memory.reassign(from: old, to: target)
        knowledge.reassign(from: old, to: target)
        projects.rename(from: old, to: target)
        commitments.reassign(from: old, to: target)
        chats[old] = nil
        selection = target
        generateBrief(for: target, quiet: true)
    }

    func deleteProject() {
        guard isProject else { return }
        let old = selection
        memory.reassign(from: old, to: MemoryStore.unassigned)
        knowledge.removeAll(inProject: old)
        projects.remove(old)
        chats[old] = nil
        selection = Self.homeKey
    }

    // MARK: - Filing things

    func moveCall(_ call: CallRecord, to name: String) {
        memory.setClient(id: call.id, to: name)
        if name != MemoryStore.unassigned { projects.ensure(name) }
        reload()
    }

    func addCalls(ids: Set<String>) {
        guard isProject else { return }
        for id in ids { memory.setClient(id: id, to: selection) }
        reload()
        generateBrief(for: selection, quiet: true)
    }

    func moveItem(_ item: KnowledgeItem, to name: String) {
        knowledge.setClient(id: item.id, to: name)
        if !name.isEmpty { projects.ensure(name) }
        reload()
    }

    func remove(_ item: KnowledgeItem) {
        knowledge.remove(id: item.id)
        reload()
    }

    func addNote(kind: String, title: String, text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        knowledge.add(KnowledgeItem(
            id: UUID().uuidString,
            title: name.isEmpty ? String(body.prefix(40)) : name,
            client: fileUnder,
            kind: kind,
            text: body,
            date: Date()
        ))
        reload()
    }

    func importFiles(_ urls: [URL]) {
        var added = 0
        var failed: [String] = []
        for url in urls {
            let opened = url.startAccessingSecurityScopedResource()
            defer { if opened { url.stopAccessingSecurityScopedResource() } }
            if let text = KnowledgeStore.extractText(from: url) {
                let ext = url.pathExtension.lowercased()
                knowledge.add(KnowledgeItem(
                    id: UUID().uuidString,
                    title: url.lastPathComponent,
                    client: fileUnder,
                    kind: (ext == "eml" || ext == "emlx") ? "email" : "file",
                    text: text,
                    date: Date(),
                    path: url.path
                ))
                added += 1
            } else {
                failed.append(url.lastPathComponent)
            }
        }
        status = "Added \(added) file\(added == 1 ? "" : "s")."
            + (failed.isEmpty ? "" : " Couldn't read: \(failed.joined(separator: ", ")).")
        reload()
    }

    // MARK: - AI

    func ask(_ question: String) {
        let slot = selection
        let scope = isProject ? selection : ""
        guard let key = AIAccess.key(project: scope, projects: projects) else { hasKey = false; return }
        guard !asking else { return }
        chats[slot, default: []].append(ChatMessage(fromYou: true, text: question))
        asking = true

        let previous = histories[slot]?.last?.question ?? ""
        let found = retriever.context(query: previous + " " + question, client: scope, onlyClient: !scope.isEmpty, excluding: nil, maxChars: 24_000, cloud: key != AIAccess.localKey)
        let sourceText = found.text.isEmpty ? "(no sources found)" : found.text
        let prompt = "Sources:\n\n\(sourceText)\n\nQuestion: \(question)"
        let past = histories[slot] ?? []

        Task { @MainActor in
            do {
                let answer = try await ChatService.complete(key: key, system: LibraryModel.askSystem, history: past, prompt: prompt, maxTokens: 1500)
                histories[slot, default: []].append((question, answer))
                let used = citedSources(in: answer, from: found.sources)
                chats[slot, default: []].append(ChatMessage(fromYou: false, text: answer, sources: used))
            } catch {
                if case ChatError.badKey = error { Keychain.delete(); refreshSetup() }
                chats[slot, default: []].append(ChatMessage(fromYou: false, text: error.localizedDescription, isError: true))
            }
            asking = false
        }
    }

    func clearChat() {
        chats[selection] = nil
        histories[selection] = nil
    }

    func generateBrief(for name: String, quiet: Bool = false) {
        guard let key = AIAccess.key(project: name, projects: projects), !briefBusy else {
            if !quiet { status = "Connect the AI first (Settings)." }
            return
        }
        let found = retriever.overview(client: name, maxChars: 30_000)
        guard !found.text.isEmpty else {
            if !quiet { status = "Add some calls, files or notes to this project first." }
            return
        }
        briefBusy = true
        Task { @MainActor in
            do {
                let text = try await ChatService.complete(
                    key: key,
                    system: LibraryModel.briefSystem,
                    prompt: "Project: \(name)\n\nSources:\n\n\(found.text)\n\nWrite the brief now.",
                    maxTokens: 1800
                )
                projects.setBrief(name: name, text: text)
                status = ""
            } catch {
                if !quiet { status = error.localizedDescription }
                Log.write("brief failed: \(error.localizedDescription)")
            }
            briefBusy = false
            reload()
        }
    }


    // MARK: - Promises

    func setDone(_ item: Commitment, _ done: Bool) {
        commitments.setDone(id: item.id, done)
        reload()
    }

    func removePromise(_ item: Commitment) {
        commitments.remove(id: item.id)
        reload()
    }

    func addPromise(text: String, owner: String, due: Date?, project: String) {
        let clean = text.trimmed
        guard !clean.isEmpty else { return }
        commitments.add(Commitment(id: UUID().uuidString, callId: "", project: project, owner: owner.trimmed.isEmpty ? "You" : owner.trimmed, text: clean, due: due, done: false, created: Date()))
        reload()
    }

    func project(of item: Commitment) -> String {
        commitments.project(of: item, memory: memory)
    }

    func call(for item: Commitment) -> CallRecord? {
        item.callId.isEmpty ? nil : memory.records.first(where: { $0.id == item.callId })
    }

    /// Promises I still owe, for the badge in the sidebar.
    var openMineCount: Int { promises.filter { !$0.done && $0.isMine }.count }
    var overdueCount: Int { promises.filter { $0.isOverdue }.count }

    // MARK: - Privacy

    var isOnDeviceOnly: Bool { isProject && projects.isOnDeviceOnly(selection) }

    func setOnDeviceOnly(_ value: Bool) {
        guard isProject else { return }
        projects.setOnDeviceOnly(selection, value)
        status = (value && !AIAccess.localAvailable) ? AIAccess.localProblem : ""
        reload()
    }

    // MARK: - Follow-up email

    func draftFollowUp(for call: CallRecord) async throws -> (subject: String, body: String) {
        guard let processor, let key = AIAccess.key(project: call.client, projects: projects) else {
            throw ChatError.message("Connect the AI first (Settings).")
        }
        return try await processor.followUp(for: call, key: key)
    }

    // MARK: - Search

    /// Opens whatever a search result points at.
    func open(_ hit: SearchHit) {
        showSearch = false
        // Give the search sheet a moment to close before the next one opens.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [self] in
            switch hit.target {
            case .call(let id, let seek):
                guard let call = memory.records.first(where: { $0.id == id }) else { return }
                detailSeek = seek
                detailCall = call
            case .note(let id):
                guard let item = knowledge.items.first(where: { $0.id == id }) else { return }
                selection = item.client.isEmpty ? Self.generalKey : item.client
                projectTab = .content
            case .promises:
                selection = Self.promisesKey
            case .project(let name):
                selection = name
            }
        }
    }

    static func folder(for call: CallRecord) -> URL {
        Log.root.appendingPathComponent(call.id, isDirectory: true)
    }
}
