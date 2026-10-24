import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The main window: a sidebar of places, and a page for whatever is selected.
struct MainView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var agent: AgentModel
    @State private var showNewProject = false
    @State private var newProjectName = ""
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
        }
        .frame(minWidth: 940, minHeight: 600)
        .tint(Theme.accent)
        .onAppear { model.reload() }
        .sheet(isPresented: $showNewProject) {
            NameSheet(
                title: "New project",
                prompt: "A project is one place for everything about a client or topic: calls, files, emails and notes.",
                action: "Create",
                text: $newProjectName
            ) {
                model.createProject(newProjectName)
                newProjectName = ""
            }
        }
        .sheet(item: $model.detailCall) { call in
            CallDetailSheet(model: model, call: call)
        }
        .sheet(isPresented: $model.showSearch) {
            SearchPalette(model: model)
        }
        .sheet(isPresented: Binding(get: { !onboarded }, set: { _ in })) {
            OnboardingSheet(model: model) { onboarded = true }
                .interactiveDismissDisabled()
        }
    }

    private func badge(_ count: Int, tint: Color) -> some View {
        Text("\(count)")
            .font(.caption2.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(tint, in: Capsule())
    }

    // MARK: Sidebar

    private var sidebar: some View {
        let selection = Binding<String?>(
            get: { model.selection },
            set: { if let value = $0 { model.selection = value } }
        )
        return List(selection: selection) {
            Button {
                model.showSearch = true
            } label: {
                HStack {
                    Label("Search", systemImage: "magnifyingglass")
                    Spacer()
                    Text("⌘K").font(.caption).foregroundStyle(.tertiary)
                }
            }
            .buttonStyle(.plain)
            .help("Search every call, note and promise (Command-K)")

            Label("Home", systemImage: "house").tag(LibraryModel.homeKey)
            HStack {
                Label("Promises", systemImage: "checklist")
                Spacer()
                if model.openMineCount > 0 { badge(model.openMineCount, tint: model.overdueCount > 0 ? .red : .gray) }
            }
            .tag(LibraryModel.promisesKey)

            Section("Projects") {
                ForEach(model.projectNames, id: \.self) { name in
                    Label(name, systemImage: "folder").tag(name)
                }
                Button {
                    showNewProject = true
                } label: {
                    Label("New project", systemImage: "plus.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }

            Section("Everything else") {
                Label("All material", systemImage: "tray.full").tag(LibraryModel.allKey)
                Label("General notes", systemImage: "note.text").tag(LibraryModel.generalKey)
                HStack {
                    Label("Unassigned calls", systemImage: "questionmark.folder")
                    Spacer()
                    if model.unassignedCount > 0 { badge(model.unassignedCount, tint: .orange) }
                }
                .tag(LibraryModel.unassignedKey)
            }

            Section {
                Label("Feedback", systemImage: "bubble.left.and.text.bubble.right").tag(LibraryModel.feedbackKey)
                Label("Settings", systemImage: "gearshape").tag(LibraryModel.settingsKey)
            }
        }
        .listStyle(.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 300)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        switch model.selection {
        case LibraryModel.homeKey:
            HomeView(model: model, agent: agent) { showNewProject = true }
        case LibraryModel.settingsKey:
            SettingsView(model: model, agent: agent)
        case LibraryModel.promisesKey:
            PromisesView(model: model)
        case LibraryModel.feedbackKey:
            FeedbackView()
        default:
            ProjectPage(model: model)
        }
    }
}

// MARK: - Small shared pieces

struct NameSheet: View {
    let title: String
    let prompt: String
    let action: String
    @Binding var text: String
    var onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.title3.bold())
            Text(prompt).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit(done)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(action, action: done)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func done() {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onDone()
        dismiss()
    }
}

/// First useful line of a call summary, for list rows.
func summaryPreview(_ summary: String) -> String {
    for raw in summary.components(separatedBy: "\n") {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        return line.replacingOccurrences(of: "**", with: "")
    }
    return ""
}

struct CallRow: View {
    let call: CallRecord
    var showProject = true
    var onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "video.fill")
                    .foregroundStyle(Theme.accent)
                    .frame(width: 28, height: 28)
                    .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(call.title ?? "\(call.app) call") · \(call.date.formatted(date: .abbreviated, time: .shortened))")
                        .font(.callout.weight(.semibold))
                    let preview = summaryPreview(call.summary)
                    Text(preview.isEmpty ? "No summary yet. Open to see the transcript." : preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                if showProject {
                    if call.client == MemoryStore.unassigned {
                        Chip(text: "Needs a project", icon: "questionmark.circle", tint: .orange)
                    } else {
                        Chip(text: call.client, icon: "folder", tint: Theme.accent)
                    }
                }
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Home

struct HomeView: View {
    @ObservedObject var model: LibraryModel
    @ObservedObject var agent: AgentModel
    var onNewProject: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Theme.greeting).font(.system(size: 30, weight: .bold))
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }

                if let alert = agent.alert {
                    AlertBanner(alert: alert, onOpen: { agent.onOpenApp($0) }, onDismiss: { agent.alert = nil })
                }

                if !model.setup.complete {
                    SetupChecklist(model: model, title: "Finish setting up")
                }

                recordCard
                UpcomingSection(agent: agent)
                promisesCard

                if model.unassignedCount > 0 {
                    HStack(spacing: 10) {
                        Image(systemName: "questionmark.folder.fill").foregroundColor(.orange)
                        Text("\(model.unassignedCount) call\(model.unassignedCount == 1 ? "" : "s") not in a project yet.")
                            .font(.callout)
                        Spacer()
                        Button("Sort them") { model.selection = LibraryModel.unassignedKey }.buttonStyle(SoftButtonStyle())
                    }
                    .card(padding: 12)
                }

                projectsSection
                recentSection
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var subtitle: String {
        if case .recording = agent.state { return "A call is being recorded." }
        if model.overdueCount > 0 {
            return "You have \(model.overdueCount) overdue promise\(model.overdueCount == 1 ? "" : "s")."
        }
        if model.openMineCount > 0 {
            return "\(model.openMineCount) promise\(model.openMineCount == 1 ? "" : "s") waiting on you."
        }
        return "Ready when your next call starts."
    }

    @ViewBuilder
    private var recordCard: some View {
        switch agent.state {
        case .recording(_, let since):
            HStack(spacing: 14) {
                PulsingDot(size: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Recording").font(.title3.bold())
                    TimelineView(.periodic(from: since, by: 1)) { context in
                        Text(Theme.elapsed(from: since, to: context.date))
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Text("Live notes and suggestions are in the small floating window.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Stop recording") { agent.onStop() }.buttonStyle(PrimaryButtonStyle(destructive: true))
            }
            .padding(20)
            .background(Theme.record.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.record.opacity(0.25), lineWidth: 1))
        case .callFound(let call):
            HStack(spacing: 14) {
                BrandTile(symbol: "video.fill", size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(call.app) call detected").font(.title3.bold())
                    Text("Want me to record it and take notes?").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Not now") { agent.onIgnore() }.buttonStyle(SoftButtonStyle())
                Button("Start recording") { agent.onRecord() }.buttonStyle(PrimaryButtonStyle())
            }
            .padding(20)
            .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1))
        default:
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.2))
                    Image(systemName: "waveform").font(.title2.weight(.semibold)).foregroundColor(.white)
                }
                .frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Ready when you are").font(.title3.bold()).foregroundColor(.white)
                    Text(model.setup.screen
                         ? "I'll also offer to record when I see a Meet, Teams or Zoom call."
                         : "Allow Screen Recording above first, then you can record.")
                        .font(.callout)
                        .foregroundColor(Color.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button { agent.onRecordNow() } label: {
                    Label("Start recording", systemImage: "record.circle")
                }
                .buttonStyle(HeroButtonStyle())
                .disabled(!model.setup.screen)
            }
            .padding(20)
            .background(Theme.brand, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: Theme.accent.opacity(0.28), radius: 16, x: 0, y: 8)
        }
    }

    @ViewBuilder
    private var promisesCard: some View {
        let mine = model.promises.filter { !$0.done && $0.isMine }.byDue
        if !mine.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Promises you owe").font(.title3.bold())
                    if model.overdueCount > 0 { Chip(text: "\(model.overdueCount) overdue", icon: "exclamationmark.circle", tint: .red) }
                    Spacer()
                    Button("See all") { model.selection = LibraryModel.promisesKey }.buttonStyle(.link)
                }
                PromiseList(model: model, items: Array(mine.prefix(4)), showProject: true)
            }
        }
    }

    private var projectsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Your projects").font(.title3.bold())
                Spacer()
                Button {
                    onNewProject()
                } label: {
                    Label("New project", systemImage: "plus")
                }
                .buttonStyle(SoftButtonStyle())
            }
            if model.projectNames.isEmpty {
                EmptyState(icon: "folder.badge.plus",
                           title: "No projects yet",
                           message: "Make one for each client or topic. Then drop in calls, files, emails and notes, and ask questions across all of it. The more you add, the better the live suggestions get.",
                           button: "Create your first project",
                           action: onNewProject)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)], spacing: 14) {
                    ForEach(model.projectNames, id: \.self) { name in
                        Button {
                            model.selection = name
                        } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                BrandTile(symbol: "folder.fill", size: 34)
                                Text(name).font(.headline).lineLimit(1)
                                Text(summaryLine(for: name)).font(.caption).foregroundStyle(.secondary)
                            }
                            .card()
                            .hoverLift()
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func summaryLine(for name: String) -> String {
        let calls = model.callCount(in: name)
        let items = model.itemCount(in: name)
        return "\(calls) call\(calls == 1 ? "" : "s") · \(items) file\(items == 1 ? "" : "s") & note\(items == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent calls").font(.title3.bold())
                Spacer()
                if model.allCalls.count > 5 {
                    Button("See all") { model.selection = LibraryModel.allKey }.buttonStyle(.link)
                }
            }
            if model.allCalls.isEmpty {
                EmptyState(icon: "waveform",
                           title: "No calls yet",
                           message: "Calls you record will show up here with an automatic summary.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(model.allCalls.prefix(5))) { call in
                        CallRow(call: call) { model.detailCall = call }
                            .padding(.vertical, 10)
                        if call.id != model.allCalls.prefix(5).last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .card(padding: 0)
            }
        }
    }
}

// MARK: - Setup checklist

struct SetupChecklist: View {
    @ObservedObject var model: LibraryModel
    var title: String
    @State private var showAI = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Text("\(model.setup.doneCount) of 4 done").font(.caption).foregroundStyle(.secondary)
            }
            ProgressView(value: Double(model.setup.doneCount), total: 4)

            row(done: model.setup.screen,
                name: "Screen Recording",
                why: "Lets me record the call window and hear the other people.",
                button: "Allow") { model.grant(.screen) }
            if !model.setup.screen {
                Text("After switching it on in System Settings, quit and reopen Meeting Agent if it still shows as not allowed.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 34)
            }
            row(done: model.setup.mic,
                name: "Microphone",
                why: "So your side of the conversation is captured too.",
                button: "Allow") { model.grant(.mic) }
            row(done: model.setup.speech,
                name: "Speech Recognition",
                why: "Turns the audio into text. It happens on your Mac.",
                button: "Allow") { model.grant(.speech) }
            row(done: model.setup.key,
                name: "AI assistant",
                why: "Unlocks summaries, live suggestions and chat. Free with Google, or use Claude or this Mac.",
                button: "Connect") { showAI = true }
        }
        .card()
        .sheet(isPresented: $showAI) {
            AISetupSheet(model: model) { showAI = false }
        }
    }

    private func row(done: Bool, name: String, why: String, button: String, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundColor(done ? .green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.callout.weight(.semibold))
                Text(why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !done {
                Button(button, action: action).buttonStyle(SoftButtonStyle())
            }
        }
    }
}

// MARK: - Coming up

struct UpcomingSection: View {
    @ObservedObject var agent: AgentModel
    @State private var expandedEvent: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Coming up").font(.title3.bold())
            if !agent.calendarConnected {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Get a briefing before every meeting").font(.headline)
                    Text("Connect your calendar and I'll prepare you a few minutes before each meeting: what happened last time, what's still open, and what to ask. Google Calendar works too, once your Google account is added in System Settings › Internet Accounts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Connect Calendar") { agent.onConnectCalendar() }.buttonStyle(PrimaryButtonStyle())
                }
                .card()
            } else if agent.upcoming.isEmpty {
                Text("No meetings in the next day.").font(.callout).foregroundStyle(.secondary).card()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(agent.upcoming.prefix(4))) { event in
                        eventRow(event).padding(.vertical, 10)
                        if event.id != agent.upcoming.prefix(4).last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func eventRow(_ event: UpcomingEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text("\(event.start.formatted(date: .abbreviated, time: .shortened))" + (event.people.isEmpty ? "" : " · " + event.people.prefix(3).map { $0.name }.joined(separator: ", ")))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                if agent.briefings[event.id] != nil {
                    Button(expandedEvent == event.id ? "Hide briefing" : "Show briefing") { expandedEvent = expandedEvent == event.id ? nil : event.id }
                        .buttonStyle(SoftButtonStyle())
                } else if agent.preparing.contains(event.id) {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Preparing…").font(.caption) }
                } else {
                    Button("Prepare me") { agent.onPrepare(event) }.buttonStyle(SoftButtonStyle())
                }
            }
            if expandedEvent == event.id, let briefing = agent.briefings[event.id] {
                MarkdownLite(text: briefing.text).textSelection(.enabled).padding(.top, 4)
            }
        }
    }
}
