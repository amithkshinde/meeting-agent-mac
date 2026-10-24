import AppKit
import SwiftUI

enum UIState: Equatable {
    case idle
    case callFound(DetectedCall)
    case recording(call: DetectedCall, since: Date)
    case error(String)
}

enum PanelTab { case now, transcript, ask }

struct Suggestion: Identifiable, Equatable {
    let id = UUID()
    let kind: String   // "ask", "pushback" or "flag"
    let text: String
    let why: String
}

final class AgentModel: ObservableObject {
    @Published var state: UIState = .idle
    @Published var lastSaved: String?
    @Published var screenAccess = true
    @Published var setupDone = false
    @Published var panelTab = PanelTab.now
    @Published var collapsed = false

    @Published var lines: [TranscriptLine] = []
    @Published var partial: [String: String] = [:]
    @Published var recap: [String] = []
    @Published var suggestions: [Suggestion] = []
    @Published var client = ""
    @Published var pastClients: [String] = []
    @Published var copilotOn = UserDefaults.standard.object(forKey: "copilotOn") as? Bool ?? true
    @Published var summarizing = false
    @Published var lastSummaryURL: URL?

    @Published var chat: [ChatMessage] = []
    @Published var asking = false
    @Published var hasKey = AIAccess.isReady

    @Published var alert: AppAlert?
    @Published var quiet = UserDefaults.standard.bool(forKey: "quietMode")
    @Published var peeking = false
    @Published var focusAsk = 0
    @Published var calendarConnected = false
    @Published var upcoming: [UpcomingEvent] = []
    @Published var briefings: [String: Briefing] = [:]
    @Published var preparing: Set<String> = []
    /// The person the video shows speaking right now, when it can tell.
    @Published var speakingNow: String?
    /// How many moments have been bookmarked in this call.
    @Published var bookmarkCount = 0

    var onRecord: () -> Void = {}
    var onRecordNow: () -> Void = {}
    var onStop: () -> Void = {}
    var onBookmark: () -> Void = {}
    var onIgnore: () -> Void = {}
    var onRevealLast: () -> Void = {}
    var onAsk: (String) -> Void = { _ in }
    /// Opens the main window. nil means Home; otherwise a section such as "§settings".
    var onOpenApp: (String?) -> Void = { _ in }
    var onTogglePanel: () -> Void = {}
    var onPrepare: (UpcomingEvent) -> Void = { _ in }
    var onConnectCalendar: () -> Void = {}

    func raise(_ next: AppAlert) {
        if alert != next { alert = next }
    }

    func clearAlert(_ id: String) {
        if alert?.id == id { alert = nil }
    }

    /// Shows the suggestions for a moment while quiet mode is on.
    func peek() {
        panelTab = .now
        collapsed = false
        peeking = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.peeking = false }
    }
}

struct PanelView: View {
    @ObservedObject var model: AgentModel
    @State private var draft = ""
    @State private var typingProject = false
    @FocusState private var askFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let alert = model.alert {
                AlertBanner(alert: alert, onOpen: { model.onOpenApp($0) }, onDismiss: { model.alert = nil })
            }
            content
        }
        .onChange(of: model.focusAsk) {
            DispatchQueue.main.async { askFocused = true }
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.primary.opacity(0.08)))
        .tint(Theme.accent)
        .animation(.easeInOut(duration: 0.2), value: model.collapsed)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .idle: idleView
        case .callFound(let call): callFoundView(call)
        case .recording(let call, let since): recordingView(call: call, since: since)
        case .error(let message): errorView(message)
        }
    }

    // MARK: - Ready

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: model.setupDone ? "waveform.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(model.setupDone ? Theme.accent : Color.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.setupDone ? "Ready to listen" : "Almost ready").font(.headline)
                    Text(model.setupDone ? "Join a call and I'll offer to record it." : "A few quick steps are left.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            HStack {
                if model.setupDone {
                    Button("Start recording") { model.onRecordNow() }.buttonStyle(PrimaryButtonStyle())
                } else {
                    Button("Finish setup") { model.onOpenApp(nil) }.buttonStyle(PrimaryButtonStyle())
                }
                Button("Open app") { model.onOpenApp(nil) }.buttonStyle(SoftButtonStyle())
            }
            afterCall
            meetingCard
        }
    }

    /// The next meeting from the calendar, with its briefing when one is ready.
    @ViewBuilder
    private var meetingCard: some View {
        if let event = model.upcoming.first(where: { $0.start.timeIntervalSinceNow < 20 * 60 && $0.start.timeIntervalSinceNow > -600 }) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: "calendar").foregroundStyle(Theme.accent)
                    Text(event.title).font(.caption.bold()).lineLimit(1)
                    Spacer()
                    Text(event.start, style: .time).font(.caption).foregroundStyle(.secondary)
                }
                if let briefing = model.briefings[event.id] {
                    MarkdownLite(text: briefing.text, compact: true)
                } else if model.preparing.contains(event.id) {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Preparing your briefing…").font(.caption) }
                } else {
                    Button("Prepare me for this") { model.onPrepare(event) }
                        .buttonStyle(SoftButtonStyle())
                        .font(.caption)
                }
            }
            .card(padding: 10)
        }
    }

    @ViewBuilder
    private var afterCall: some View {
        if model.summarizing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Writing your call summary…").font(.caption)
            }
            .card(padding: 10)
        } else if model.lastSummaryURL != nil || model.lastSaved != nil {
            VStack(alignment: .leading, spacing: 8) {
                Text("Last call saved").font(.caption.bold())
                HStack {
                    if let url = model.lastSummaryURL {
                        Button("Read summary") { NSWorkspace.shared.open(url) }
                    }
                    Button("Show files") { model.onRevealLast() }
                }
                .buttonStyle(SoftButtonStyle())
                .font(.caption)
            }
            .card(padding: 10)
        }
    }

    // MARK: - Call found

    private func callFoundView(_ call: DetectedCall) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "video.circle.fill").font(.system(size: 30)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(call.app) call detected").font(.headline)
                    Text("Want me to record and take notes?").font(.caption).foregroundStyle(.secondary)
                }
            }
            projectRow
            HStack {
                Button("Start recording") { model.onRecord() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
                Button("Not now") { model.onIgnore() }.buttonStyle(SoftButtonStyle())
            }
            Text("Tell the other people you're recording before you start.")
                .font(.caption)
                .foregroundStyle(.secondary)
            meetingCard
        }
    }

    // MARK: - Recording

    private func recordingView(call: DetectedCall, since: Date) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                PulsingDot(size: 8)
                Text("Recording").font(.headline)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.elapsed(from: since, to: context.date))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.onBookmark()
                } label: {
                    Label(model.bookmarkCount > 0 ? "\(model.bookmarkCount)" : "Mark", systemImage: model.bookmarkCount > 0 ? "bookmark.fill" : "bookmark")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(SoftButtonStyle())
                .help("Bookmark this moment (Control-Option-B)")
                Button("Stop") { model.onStop() }.buttonStyle(PrimaryButtonStyle(destructive: true))
                Button {
                    model.collapsed.toggle()
                } label: {
                    Image(systemName: model.collapsed ? "chevron.down" : "chevron.up")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(model.collapsed ? "Show more" : "Show less")
                .accessibilityLabel(model.collapsed ? "Show more" : "Show less")
            }

            if let speaker = model.speakingNow {
                Label(speaker, systemImage: "waveform")
                    .font(.caption)
                    .foregroundStyle(Theme.accent)
                    .lineLimit(1)
                    .accessibilityLabel("Speaking now: \(speaker)")
            }

            if model.collapsed {
                if let latest = model.recap.last {
                    Text(latest).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            } else {
                projectRow
                Picker("", selection: $model.panelTab) {
                    Text("Now").tag(PanelTab.now)
                    Text("Transcript").tag(PanelTab.transcript)
                    Text("Ask").tag(PanelTab.ask)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch model.panelTab {
                case .now: nowTab
                case .transcript: transcriptTab
                case .ask: askTab
                }
            }
        }
    }

    private var projectRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder").foregroundStyle(.secondary)
            if typingProject {
                TextField("New project name", text: $model.client)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .onSubmit { typingProject = false }
                Button("Done") { typingProject = false }.font(.caption)
            } else {
                Menu {
                    ForEach(model.pastClients, id: \.self) { name in
                        Button(name) { model.client = name }
                    }
                    if !model.pastClients.isEmpty { Divider() }
                    Button("New project…") { model.client = ""; typingProject = true }
                    if !model.client.isEmpty { Button("No project") { model.client = "" } }
                } label: {
                    Text(model.client.isEmpty ? "Choose a project" : model.client).font(.callout)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                if model.client.isEmpty, case .recording = model.state, model.copilotOn, model.hasKey {
                    Text("I'll guess from the conversation.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: Now

    private var nowTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if model.quiet && !model.peeking {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Quiet mode", systemImage: "eye.slash").font(.callout.weight(.medium))
                            Text("Suggestions are hidden so you can focus. I'm still listening.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Button("Peek for 20 seconds") { model.peek() }.buttonStyle(SoftButtonStyle()).font(.caption)
                        }
                        .card(padding: 10)
                    } else if !model.copilotOn {
                        notice("Live suggestions are paused.", button: "Turn on in Settings") { model.onOpenApp("§settings") }
                    } else if !model.hasKey {
                        notice("Connect the AI to get a live recap and smart questions.", button: "Connect") { model.onOpenApp("§settings") }
                    } else if model.recap.isEmpty && model.suggestions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Listening…", systemImage: "ear").font(.callout.weight(.medium))
                            Text("The last few points and good questions to ask will show up here as the call goes on.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .card(padding: 10)
                    } else {
                        recapBox
                        ForEach(model.suggestions) { card in suggestionCard(card) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 190)

            HStack {
                Button("Catch me up") { quick("Catch me up on the whole call so far in a few short bullets, then tell me what the most recent point was.") }
                    .disabled(!model.hasKey)
                Button("Last minute") { quick("What was said in the last minute? Give me the key points, and tell me if anyone asked me something.") }
                    .disabled(!model.hasKey)
                Spacer(minLength: 0)
                Button {
                    model.quiet.toggle()
                    UserDefaults.standard.set(model.quiet, forKey: "quietMode")
                } label: {
                    Image(systemName: model.quiet ? "eye.slash.fill" : "eye")
                }
                .help(model.quiet ? "Quiet mode is on. Click to show suggestions again." : "Quiet mode: hide suggestions until you peek")
            }
            .buttonStyle(SoftButtonStyle())
        }
    }

    @ViewBuilder
    private var recapBox: some View {
        if !model.recap.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Last few points").font(.caption.bold()).foregroundStyle(.secondary)
                ForEach(Array(model.recap.enumerated()), id: \.offset) { _, point in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(point).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
            .card(padding: 10)
        }
    }

    private func suggestionCard(_ card: Suggestion) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.label(for: card.kind))
                .font(.caption2.bold())
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Self.color(for: card.kind), in: Capsule())
            VStack(alignment: .leading, spacing: 3) {
                Text(card.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                if !card.why.isEmpty {
                    Text(card.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            Button {
                model.suggestions.removeAll { $0.id == card.id }
            } label: {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Self.color(for: card.kind).opacity(0.10), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private static func label(for kind: String) -> String {
        switch kind {
        case "pushback": return "Push back"
        case "flag": return "Flag"
        default: return "Ask"
        }
    }

    private static func color(for kind: String) -> Color {
        switch kind {
        case "pushback": return .orange
        case "flag": return .red
        default: return .blue
        }
    }

    // MARK: Transcript

    private var transcriptTab: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if model.lines.isEmpty, (model.partial["You"] ?? "").isEmpty, (model.partial["Them"] ?? "").isEmpty {
                        Text("Listening… words appear here as people speak.").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(model.lines) { line in
                        row(speaker: line.speaker, text: line.text, live: false).id(line.id)
                    }
                    ForEach(["Them", "You"], id: \.self) { speaker in
                        if let text = model.partial[speaker], !text.isEmpty {
                            row(speaker: speaker, text: text, live: true)
                        }
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 190 + 40)
            .onChange(of: model.lines.count) { proxy.scrollTo("bottom") }
            .onChange(of: model.partial) { proxy.scrollTo("bottom") }
        }
    }

    private func row(speaker: String, text: String, live: Bool) -> some View {
        (Text("\(speaker == "You" ? "You" : "Them"): ").bold().foregroundColor(speaker == "You" ? .blue : .primary)
            + Text(text).foregroundColor(live ? .secondary : .primary))
            .font(.caption)
    }

    // MARK: Ask

    private var askTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !model.hasKey {
                notice("Connect the AI to ask questions about the call.", button: "Connect") { model.onOpenApp("§settings") }
                    .frame(height: 190 + 40, alignment: .top)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            if model.chat.isEmpty {
                                Text("Ask about what was just said, or about earlier calls, files and emails in this project. I'll show where each answer came from.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(model.chat) { message in bubble(message).id(message.id) }
                            if model.asking {
                                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Thinking…").font(.caption).foregroundStyle(.secondary) }
                            }
                            Color.clear.frame(height: 1).id("chat-bottom")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 190)
                    .onChange(of: model.chat.count) { proxy.scrollTo("chat-bottom") }
                    .onChange(of: model.asking) { proxy.scrollTo("chat-bottom") }
                }
                HStack(spacing: 6) {
                    Button("Last minute") { quick("What was said in the last minute? Give me the key points, and tell me if anyone asked me something.") }
                    Button("Last time") { quick("What did we discuss in earlier calls and notes in this project, and what was left open? If there is nothing earlier, say so.") }
                }
                .buttonStyle(SoftButtonStyle())
                .font(.caption)
                .disabled(model.asking)
                HStack {
                    TextField("Ask anything…", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .focused($askFocused)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.asking)
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        if message.fromYou {
            Text(message.text).font(.callout).foregroundColor(.blue).frame(maxWidth: .infinity, alignment: .leading)
        } else if message.isError {
            Text(message.text).font(.caption).foregroundColor(.orange).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                MarkdownLite(text: message.text, compact: true).textSelection(.enabled)
                SourceListView(sources: message.sources, compact: true)
            }
        }
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.asking else { return }
        draft = ""
        model.onAsk(text)
    }

    private func quick(_ question: String) {
        model.panelTab = .ask
        model.onAsk(question)
    }

    // MARK: - Error

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text(message).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Dismiss") { model.onIgnore() }.buttonStyle(PrimaryButtonStyle())
                Button("Open app") { model.onOpenApp(nil) }.buttonStyle(SoftButtonStyle())
            }
        }
    }

    private func notice(_ text: String, button: String, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text).font(.callout)
            Button(button, action: action).buttonStyle(SoftButtonStyle())
        }
        .card(padding: 10)
    }

    private static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
