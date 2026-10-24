import AppKit
import SwiftUI

/// The Feedback page: pick a type, say what you think, choose whether to put your name on it, send.
struct FeedbackView: View {
    @AppStorage("feedbackName") private var savedName = ""
    @AppStorage("feedbackReplyEmail") private var savedEmail = ""

    @State private var kind = FeedbackKind.idea
    @State private var rating = 0
    @State private var message = ""
    @State private var anonymous = false
    @State private var includeDetails = true
    @State private var includeLog = false
    @State private var showWhatIsSent = false
    @State private var sending = false
    @State private var status: Status?
    @State private var entries: [FeedbackEntry] = []

    private struct Status {
        var text: String
        var good: Bool
    }

    private static let file = Log.root.appendingPathComponent("feedback.json")

    private var trimmedMessage: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var emailLooksWrong: Bool { !anonymous && !savedEmail.isEmpty && !FeedbackCompose.isValidEmail(savedEmail) }
    private var canSend: Bool { !trimmedMessage.isEmpty && !sending && !emailLooksWrong }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                writeCard
                whoCard
                detailsCard
                actions
                if let status {
                    Label(status.text, systemImage: status.good ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(status.good ? Color.green : Color.orange)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !entries.isEmpty { history }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            entries = FeedbackStore.load(from: Self.file)
            if savedName.isEmpty {
                let preset = UserDefaults.standard.string(forKey: "userDisplayName") ?? NSFullUserName()
                savedName = preset
            }
        }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Feedback").font(.largeTitle.weight(.bold))
            Text("Tell me what works, what doesn't, and what you wish it did. I read every note, and it shapes what gets built next.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var writeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("What kind of feedback?").font(.headline)
            HStack(spacing: 8) {
                ForEach(FeedbackKind.allCases) { option in
                    Button {
                        kind = option
                    } label: {
                        Label(option.label, systemImage: option.icon)
                            .font(.callout)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(kind == option ? Theme.accent.opacity(0.16) : Color.primary.opacity(0.05), in: Capsule())
                            .overlay(Capsule().strokeBorder(kind == option ? Theme.accent : Color.clear, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 4) {
                Text("How does the app feel overall?").foregroundStyle(.secondary).font(.callout)
                Spacer(minLength: 12)
                ForEach(1...5, id: \.self) { value in
                    Button {
                        rating = rating == value ? 0 : value
                    } label: {
                        Image(systemName: rating >= value ? "star.fill" : "star")
                            .foregroundStyle(rating >= value ? Color.yellow : Color.secondary)
                            .font(.title3)
                    }
                    .buttonStyle(.plain)
                    .help("\(value) of 5")
                }
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $message)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 150)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                if message.isEmpty {
                    Text(kind.prompt)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 16)
                        .allowsHitTesting(false)
                }
            }
        }
        .card()
    }

    private var whoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who is this from?").font(.headline)
            Picker("", selection: $anonymous) {
                Text("Put my name on it").tag(false)
                Text("Stay anonymous").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if anonymous {
                Text("Nothing about you is added to the message. That's completely fine. The only catch is that I can't write back to ask what you meant.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if FeedbackConfig.endpoint == nil {
                    Label("Without an online form behind this button, your mail app or GitHub account still shows who you are. To be fully anonymous, use Copy and send it your own way.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("I'd love to know who you are, so I can email you if I don't follow something or want to talk it through. Both boxes are optional.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    TextField("Your name", text: $savedName).textFieldStyle(.roundedBorder)
                    TextField("Your email, for replies", text: $savedEmail).textFieldStyle(.roundedBorder)
                }
                if emailLooksWrong {
                    Text("That email doesn't look right. Fix it, or clear the box to send without one.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .card()
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(isOn: $includeDetails) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Include technical details")
                    Text("App version, macOS version and chip. Helps me reproduce a problem.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if includeDetails {
                Toggle(isOn: $includeLog) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Also include the last lines of the activity log")
                        Text("Useful for bugs. It can mention app names and file names. Never your transcripts, summaries or keys.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            DisclosureGroup("Exactly what will be sent", isExpanded: $showWhatIsSent) {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
            .font(.callout)
        }
        .card()
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                send()
            } label: {
                if sending {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Send feedback", systemImage: "paperplane.fill")
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(!canSend)
            .keyboardShortcut(.return, modifiers: .command)

            Menu {
                if FeedbackCompose.isValidEmail(FeedbackConfig.email) {
                    Button("Open as an email") { deliver(via: "email") }
                }
                Button("Open as a GitHub issue") { deliver(via: "github") }
                Button("Copy to clipboard") { deliver(via: "copied") }
            } label: {
                Text("Other ways to send")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(trimmedMessage.isEmpty)

            Spacer()
            Text("⌘↩ to send").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your earlier feedback").font(.headline)
            ForEach(entries.prefix(8)) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: entry.kind.icon).foregroundStyle(Theme.accent).frame(width: 20)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message).lineLimit(2).font(.callout)
                        Text("\(entry.date.formatted(date: .abbreviated, time: .shortened)) · \(Self.statusWord(entry))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 4)
            }
        }
        .card()
    }

    // MARK: Sending

    private func makeEntry() -> FeedbackEntry {
        FeedbackEntry(kind: kind, rating: rating == 0 ? nil : rating, message: message, anonymous: anonymous,
                      name: savedName, email: savedEmail, details: Self.details(include: includeDetails, log: includeLog))
    }

    private var preview: String {
        let entry = makeEntry()
        return FeedbackCompose.body(for: FeedbackEntry(kind: entry.kind, rating: entry.rating,
                                                       message: trimmedMessage.isEmpty ? "(your message)" : trimmedMessage,
                                                       anonymous: anonymous, name: savedName, email: savedEmail, details: entry.details))
    }

    /// The main button: post online if a form is set up, otherwise email if an address is set, otherwise GitHub.
    private func send() {
        if FeedbackConfig.endpoint != nil {
            deliver(via: "online")
        } else if FeedbackCompose.isValidEmail(FeedbackConfig.email) {
            deliver(via: "email")
        } else {
            deliver(via: "github")
        }
    }

    private func deliver(via route: String) {
        guard !trimmedMessage.isEmpty else { return }
        var entry = makeEntry()
        status = nil

        switch route {
        case "online":
            guard let endpoint = FeedbackConfig.endpoint else { return }
            sending = true
            save(entry)
            let info = Bundle.main.infoDictionary
            let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
            guard let body = FeedbackCompose.json(for: entry, app: "Meeting Agent", version: version) else {
                sending = false
                return
            }
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = body
            let saved = entry
            Task {
                var delivered = false
                if let (_, response) = try? await URLSession.shared.data(for: request),
                   let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    delivered = true
                }
                await MainActor.run {
                    sending = false
                    if delivered {
                        mark(saved, via: "online")
                        message = ""
                        rating = 0
                        status = Status(text: "Sent. Thank you, this really helps." + (saved.canReply ? " I'll write back if I have questions." : ""), good: true)
                    } else {
                        status = Status(text: "Couldn't reach the server, so it is saved on this Mac only. Try “Other ways to send”.", good: false)
                    }
                }
            }
            return

        case "email":
            guard let url = FeedbackCompose.mailtoURL(to: FeedbackConfig.email, entry: entry) else { return }
            save(entry)
            NSWorkspace.shared.open(url)
            entry.sentVia = "email"

        case "github":
            guard let url = FeedbackCompose.githubURL(repo: FeedbackConfig.repo, entry: entry) else { return }
            save(entry)
            NSWorkspace.shared.open(url)
            entry.sentVia = "github"

        default:
            save(entry)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(FeedbackCompose.body(for: entry), forType: .string)
            entry.sentVia = "copied"
        }

        mark(entry, via: entry.sentVia ?? "copied")
        switch route {
        case "email": status = Status(text: "Your mail app has the message ready. Press Send there to finish.", good: true)
        case "github": status = Status(text: "Your browser has a draft issue ready. Press “Submit new issue” there to finish.", good: true)
        default: status = Status(text: "Copied. Paste it wherever you like.", good: true)
        }
    }

    private func save(_ entry: FeedbackEntry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        FeedbackStore.save(entries, to: Self.file)
    }

    private func mark(_ entry: FeedbackEntry, via route: String) {
        guard let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[index].sentVia = route
        FeedbackStore.save(entries, to: Self.file)
    }

    private static func statusWord(_ entry: FeedbackEntry) -> String {
        switch entry.sentVia {
        case "online": return "sent"
        case "email": return "opened in your mail app"
        case "github": return "opened on GitHub"
        case "copied": return "copied"
        default: return "saved on this Mac"
        }
    }

    // MARK: Technical details

    private static func details(include: Bool, log: Bool) -> String {
        guard include else { return "" }
        let info = Bundle.main.infoDictionary
        let version = (info?["CFBundleShortVersionString"] as? String) ?? "?"
        let build = (info?["CFBundleVersion"] as? String) ?? "?"
        var lines = [
            "App: Meeting Agent \(version) (\(build))",
            "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Chip: \(chip)"
        ]
        if log, let text = try? String(contentsOf: Log.root.appendingPathComponent("spike-log.txt"), encoding: .utf8) {
            let tail = text.split(separator: "\n").suffix(15).map { String($0.prefix(200)) }
            if !tail.isEmpty {
                lines.append("")
                lines.append("Recent activity:")
                lines.append(contentsOf: tail)
            }
        }
        return lines.joined(separator: "\n")
    }

    private static var chip: String {
        var size = 0
        sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var buffer = [CChar](repeating: 0, count: size)
        sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }
}
