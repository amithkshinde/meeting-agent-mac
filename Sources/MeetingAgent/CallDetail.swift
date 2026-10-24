import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Video

/// Owns the video player and tells the screen where it is, so the transcript can follow along.
final class PlayerModel: ObservableObject {
    let player: AVPlayer?
    @Published var current: Double = 0
    @Published var playing = false
    private var timeObserver: Any?
    private var statusObserver: NSKeyValueObservation?

    init(url: URL?) {
        if let url, FileManager.default.fileExists(atPath: url.path) {
            player = AVPlayer(url: url)
        } else {
            player = nil
        }
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
            let seconds = time.seconds
            self?.current = seconds.isFinite ? seconds : 0
        }
        statusObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let isPlaying = player.timeControlStatus == .playing
            DispatchQueue.main.async { self?.playing = isPlaying }
        }
    }

    deinit {
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        player?.pause()
    }

    func seek(to seconds: Double, play: Bool = true) {
        guard let player else { return }
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        current = max(0, seconds)
        if play { player.play() }
    }
}

/// Holds the player model without making the whole page redraw twice a second.
final class PlayerHolder: ObservableObject {
    let model: PlayerModel
    init(url: URL?) { model = PlayerModel(url: url) }
}

/// Picture of a saved screen, loaded once.
struct ScreenThumb: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Rectangle().fill(Color.primary.opacity(0.06))
            }
        }
        .task { image = NSImage(contentsOf: url) }
    }
}

// MARK: - The transcript list

/// The transcript, with the line being played highlighted. Clicking a line jumps the video to it.
struct TranscriptList: View {
    @ObservedObject var player: PlayerModel
    let lines: [TLine]
    let speakers: [String]
    let follow: Bool
    var onRename: (String) -> Void

    private func color(for speaker: String) -> Color {
        if speaker == "You" { return Theme.accent }
        let palette: [Color] = [.orange, .green, .pink, .teal, .purple, .brown, .indigo, .mint]
        let index = speakers.filter { $0 != "You" }.firstIndex(of: speaker) ?? 0
        return palette[index % palette.count]
    }

    private var currentID: Int? {
        guard player.player != nil, player.playing || player.current > 0.5,
              let index = Transcript.currentIndex(in: lines, at: player.current) else { return nil }
        return lines[index].id
    }

    var body: some View {
        let playing = currentID
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(lines) { line in
                        row(line, isCurrent: line.id == playing)
                            .id(line.id)
                    }
                }
                .padding(.vertical, 2)
            }
            .onChange(of: playing) { _, new in
                if follow, player.playing, let new {
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(new, anchor: .center) }
                }
            }
        }
    }

    private func row(_ line: TLine, isCurrent: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(line.time.map { Transcript.clock($0) } ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
            if !line.speaker.isEmpty {
                Text(line.speaker)
                    .font(.callout.weight(.semibold))
                    .foregroundColor(color(for: line.speaker))
                    .lineLimit(1)
                    .frame(width: 96, alignment: .leading)
                    .help(line.speaker)
            }
            Text(line.text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(isCurrent ? Theme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onTapGesture {
            if let time = Transcript.seekTime(for: line) { player.seek(to: time) }
        }
        .contextMenu {
            if let time = Transcript.seekTime(for: line), player.player != nil {
                Button("Play from here") { player.seek(to: time) }
            }
            Button("Copy line") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(Transcript.format(line), forType: .string)
            }
            if !line.speaker.isEmpty, line.speaker != "You" {
                Button("Rename “\(line.speaker)”…") { onRename(line.speaker) }
            }
        }
    }
}

// MARK: - The call page

struct CallDetailSheet: View {
    @ObservedObject var model: LibraryModel
    let call: CallRecord
    @StateObject private var holder: PlayerHolder
    @Environment(\.dismiss) private var dismiss

    enum DetailTab: Hashable { case summary, transcript, screens, highlights }

    @State private var tab = DetailTab.summary
    @State private var lines: [TLine] = []
    @State private var english: [TLine]?
    @State private var showEnglish = false
    @State private var search = ""
    @State private var follow = true
    @State private var marks: [Bookmark] = []
    @State private var shots: [ScreenShot] = []
    @State private var feedback: [ScreenFeedback] = []
    @State private var project = ""
    @State private var showFollowUp = false
    @State private var busy = ""
    @State private var message = ""
    @State private var renaming: String?
    @State private var newName = ""
    @State private var hasSpeakerData = false

    init(model: LibraryModel, call: CallRecord) {
        self.model = model
        self.call = call
        _holder = StateObject(wrappedValue: PlayerHolder(url: LibraryModel.folder(for: call).appendingPathComponent("screen.mp4")))
    }

    private var folder: URL { LibraryModel.folder(for: call) }
    private var player: PlayerModel { holder.model }
    private var current: CallRecord { model.memory.records.first(where: { $0.id == call.id }) ?? call }
    private var callTitle: String { current.title ?? "\(current.app) call" }
    private var hasVideo: Bool { player.player != nil }
    private var callPromises: [Commitment] { model.promises.filter { $0.callId == call.id } }

    private var shownLines: [TLine] {
        let base = (showEnglish ? english : nil) ?? lines
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        return query.isEmpty ? base : base.filter { $0.text.lowercased().contains(query) || $0.speaker.lowercased().contains(query) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            HStack(alignment: .top, spacing: 18) {
                leftColumn.frame(width: 360)
                rightColumn
            }
        }
        .padding(22)
        .frame(width: 960, height: 660)
        .sheet(isPresented: $showFollowUp) { FollowUpSheet(model: model, call: call) }
        .alert("Rename \(renaming ?? "")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { applyRename() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes every line from this speaker in this call.")
        }
        .onAppear(perform: load)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(callTitle).font(.title2.bold()).lineLimit(1)
                Text(call.date.formatted(date: .complete, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                if let people = call.attendees, !people.isEmpty {
                    Text("With " + people.map { $0.name }.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            shareMenu
            Button("Done") { dismiss() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        }
    }

    private var shareMenu: some View {
        Menu {
            Button("Export as PDF…") { exportPDF() }
            Button("Export as Markdown…") { exportMarkdown() }
            Button("Copy as Markdown") { copyMarkdown() }
            Divider()
            Button("Add promises to Reminders") { sendToReminders() }.disabled(callPromises.isEmpty)
            Button(NotionService.isConfigured ? "Send promises to Notion" : "Send promises to Notion (set up in Settings)") { sendToNotion() }
                .disabled(callPromises.isEmpty)
        } label: {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Left column: the video and the call's details

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if let avPlayer = player.player {
                    VideoPlayer(player: avPlayer)
                        .aspectRatio(1470.0 / 956.0, contentMode: .fit)
                } else {
                    ZStack {
                        Rectangle().fill(Color.primary.opacity(0.06))
                        VStack(spacing: 6) {
                            Image(systemName: "video.slash").font(.title2).foregroundStyle(.secondary)
                            Text("No video was saved for this call").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .aspectRatio(1470.0 / 956.0, contentMode: .fit)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.10)))

            if hasVideo {
                Text("Click any line in the transcript to jump to that moment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text("Project").font(.callout)
                Picker("", selection: $project) {
                    Text("None").tag(MemoryStore.unassigned)
                    ForEach(model.projectNames, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .onChange(of: project) {
                    if project != call.client { model.moveCall(call, to: project) }
                }
            }

            HStack {
                Button("Draft follow-up") { showFollowUp = true }
                    .buttonStyle(SoftButtonStyle())
                    .disabled(current.summary.isEmpty)
                Button("Show files") { NSWorkspace.shared.activateFileViewerSelecting([folder]) }
                    .buttonStyle(SoftButtonStyle())
            }

            if hasVideo, !hasSpeakerData, shots.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Find speakers and screens").font(.callout.weight(.semibold))
                    Text("Looks through the video to name who spoke, and to save a picture each time the shared screen changed. Takes a few minutes for a long call.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Analyse the video") { analyseVideo() }
                        .buttonStyle(SoftButtonStyle())
                        .disabled(!busy.isEmpty)
                }
                .card(padding: 12)
            }

            if !busy.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.caption).foregroundStyle(.secondary)
                }
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Right column: tabs

    private var rightColumn: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("", selection: $tab) {
                Text("Summary").tag(DetailTab.summary)
                Text("Transcript").tag(DetailTab.transcript)
                Text(shots.isEmpty ? "Screens" : "Screens (\(shots.count))").tag(DetailTab.screens)
                Text(marks.isEmpty ? "Highlights" : "Highlights (\(marks.count))").tag(DetailTab.highlights)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            switch tab {
            case .summary: summaryTab
            case .transcript: transcriptTab
            case .screens: screensTab
            case .highlights: highlightsTab
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Summary

    private var summaryTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Summary").font(.headline)
                    if current.summary.isEmpty {
                        Text("No summary yet. It's written after a call ends, when the AI is connected and there was enough speech.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        MarkdownLite(text: current.summary).textSelection(.enabled)
                    }
                }
                .card()

                if !callPromises.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Promises").font(.headline)
                        ForEach(callPromises) { item in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.done ? Color.green : Color.secondary)
                                Text("\(item.isMine ? "You" : item.owner): \(item.text)")
                                    .font(.callout)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let due = item.due {
                                    Spacer()
                                    Text(due.formatted(date: .abbreviated, time: .omitted))
                                        .font(.caption)
                                        .foregroundStyle(item.isOverdue ? Color.red : Color.secondary)
                                }
                            }
                        }
                        HStack {
                            Button("Add to Reminders") { sendToReminders() }.buttonStyle(SoftButtonStyle())
                            Button("Send to Notion") { sendToNotion() }.buttonStyle(SoftButtonStyle())
                        }
                    }
                    .card()
                }
            }
            .padding(.bottom, 8)
        }
    }

    // MARK: Transcript

    private var transcriptTab: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField("Search the transcript", text: $search)
                    .textFieldStyle(.roundedBorder)
                if english != nil {
                    Picker("", selection: $showEnglish) {
                        Text("Original").tag(false)
                        Text("English").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 150)
                } else {
                    Button("Translate to English") { translate() }
                        .buttonStyle(SoftButtonStyle())
                        .disabled(!busy.isEmpty || lines.isEmpty)
                        .help("Useful for Hindi, Hinglish or Kannada calls. The original stays as it is.")
                }
            }
            if hasVideo {
                Toggle("Follow the video", isOn: $follow).font(.caption).toggleStyle(.checkbox)
            }
            if lines.isEmpty {
                Text("There's no transcript for this call.").font(.callout).foregroundStyle(.secondary)
            } else if shownLines.isEmpty {
                Text("No matches.").font(.callout).foregroundStyle(.secondary)
            } else {
                TranscriptList(
                    player: player,
                    lines: shownLines,
                    speakers: Transcript.speakers(in: lines),
                    follow: follow,
                    onRename: { name in renaming = name; newName = name }
                )
                .card(padding: 8)
            }
        }
    }

    // MARK: Screens

    private var screensTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if shots.isEmpty {
                    Text("No screens were captured for this call. When someone shares a screen (a Figma frame, a slide, a page) and moves on to the next one, a picture is saved here and the talk is grouped under it. Calls recorded before this feature can be looked at with “Analyse the video”.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    HStack {
                        Text("Feedback grouped by screen").font(.headline)
                        Spacer()
                        Button(feedback.isEmpty ? "Summarise with AI" : "Redo the summary") { summariseScreens() }
                            .buttonStyle(SoftButtonStyle())
                            .disabled(!busy.isEmpty)
                    }
                    let groups = ScreenIndex.group(lines, by: shots)
                    ForEach(Array(shots.enumerated()), id: \.element.id) { index, shot in
                        screenCard(index: index, shot: shot, lines: index < groups.count ? groups[index] : [])
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    private func screenCard(index: Int, shot: ScreenShot, lines group: [TLine]) -> some View {
        let notes = feedback.first(where: { $0.n == index + 1 })
        return HStack(alignment: .top, spacing: 12) {
            Button {
                player.seek(to: shot.t)
            } label: {
                ScreenThumb(url: folder.appendingPathComponent(shot.file))
                    .frame(width: 190, height: 124)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("Play the video from here")

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Screen \(index + 1)").font(.headline)
                    Text(Transcript.clock(shot.t)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(group.count) comment\(group.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                }
                if let notes {
                    if !notes.title.isEmpty { Text(notes.title).font(.callout.weight(.semibold)) }
                    ForEach(Array(notes.feedback.enumerated()), id: \.offset) { _, text in
                        Label(text, systemImage: "text.bubble").font(.callout).labelStyle(BulletLabelStyle())
                    }
                    ForEach(Array(notes.decisions.enumerated()), id: \.offset) { _, text in
                        Label(text, systemImage: "checkmark.circle").font(.callout).foregroundStyle(.green).labelStyle(BulletLabelStyle())
                    }
                    if notes.feedback.isEmpty, notes.decisions.isEmpty {
                        Text("Nothing was said about this screen.").font(.callout).foregroundStyle(.secondary)
                    }
                } else if group.isEmpty {
                    Text("Nothing was said while this screen was up.").font(.callout).foregroundStyle(.secondary)
                } else {
                    ForEach(group.prefix(4)) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(line.speaker.isEmpty ? "" : line.speaker + ":").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            Text(line.text).font(.caption).lineLimit(2)
                        }
                    }
                    if group.count > 4 {
                        Text("+ \(group.count - 4) more in the transcript").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .card(padding: 12)
    }

    // MARK: Highlights

    private var highlightsTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if marks.isEmpty {
                    Text("No highlights yet. During a call, press ⌃⌥ B, or the Mark button on the floating window, to bookmark a moment. They show up here, and each one jumps to that point in the video.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach($marks) { $mark in
                        HStack(alignment: .top, spacing: 10) {
                            Button {
                                player.seek(to: max(0, mark.t - 3))
                            } label: {
                                Label(Transcript.clock(mark.t), systemImage: "play.circle.fill")
                                    .font(.callout.monospacedDigit())
                            }
                            .buttonStyle(SoftButtonStyle())
                            .disabled(!hasVideo)

                            VStack(alignment: .leading, spacing: 3) {
                                TextField("Add a note", text: $mark.note)
                                    .textFieldStyle(.plain)
                                    .font(.callout.weight(.semibold))
                                    .onSubmit { BookmarkStore.save(marks, to: folder) }
                                let said = CallExport.line(after: mark.t, in: lines)
                                if !said.isEmpty {
                                    Text("“\(said)”").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Spacer()
                            Button {
                                BookmarkStore.remove(id: mark.id, in: folder)
                                marks = BookmarkStore.load(folder)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                            .help("Remove this highlight")
                        }
                        .card(padding: 12)
                    }
                }
            }
            .padding(.bottom, 8)
        }
        .onDisappear { BookmarkStore.save(marks, to: folder) }
    }

    // MARK: Loading

    private func load() {
        project = call.client
        reloadLines()
        marks = BookmarkStore.load(folder)
        shots = ScreenIndex.load(folder)
        feedback = ScreenFeedback.load(folder)
        hasSpeakerData = FileManager.default.fileExists(atPath: SpeakerLog.url(folder).path)
        if let text = try? String(contentsOf: Translation.url(folder), encoding: .utf8) {
            english = Transcript.parse(text)
        }
        if let seek = model.detailSeek {
            tab = .transcript
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { player.seek(to: seek) }
            model.detailSeek = nil
        }
    }

    private func reloadLines() {
        lines = CallExport.readTranscript(folder)
    }

    // MARK: Actions

    private func aiKey() -> String? {
        guard let key = AIAccess.key(project: call.client, projects: model.projects) else {
            message = "Connect an AI first: Settings › AI assistant."
            return nil
        }
        return key
    }

    private func translate() {
        guard busy.isEmpty, let key = aiKey() else { return }
        busy = "Translating… 0%"
        message = ""
        let source = lines
        let destination = Translation.url(folder)
        Task { @MainActor in
            do {
                let result = try await Translation.translate(source, key: key) { value in
                    Task { @MainActor in busy = "Translating… \(Int(value * 100))%" }
                }
                english = result
                showEnglish = true
                try? (result.map { Transcript.format($0) }.joined(separator: "\n") + "\n").write(to: destination, atomically: true, encoding: .utf8)
            } catch {
                message = "Couldn't translate: \(error.localizedDescription)"
            }
            busy = ""
        }
    }

    private func summariseScreens() {
        guard busy.isEmpty, let key = aiKey() else { return }
        busy = "Reading the feedback on each screen…"
        message = ""
        let source = lines
        let screens = shots
        let target = folder
        Task { @MainActor in
            do {
                let result = try await ScreenReview.generate(lines: source, screens: screens, key: key)
                ScreenFeedback.save(result, to: target)
                feedback = result
            } catch {
                message = "Couldn't summarise the screens: \(error.localizedDescription)"
            }
            busy = ""
        }
    }

    private func analyseVideo() {
        guard busy.isEmpty else { return }
        busy = "Looking at the video… 0%"
        message = ""
        let video = folder.appendingPathComponent("screen.mp4")
        let target = folder
        let watcher = CallWatcher()
        Task { @MainActor in
            let result = await watcher.analyseVideo(at: video, folder: target) { value in
                Task { @MainActor in busy = "Looking at the video… \(Int(value * 100))%" }
            }
            let named = CallProcessor.attributeSpeakers(folder: target)
            reloadLines()
            shots = ScreenIndex.load(target)
            hasSpeakerData = FileManager.default.fileExists(atPath: SpeakerLog.url(target).path)
            busy = ""
            var parts: [String] = []
            parts.append("\(result.screens) screen\(result.screens == 1 ? "" : "s") saved")
            if let named, named.named > 0 {
                parts.append("named \(named.named) of \(named.total) lines (\(named.names.joined(separator: ", ")))")
            } else if result.speakerSamples == 0 {
                parts.append("no active-speaker outline was found, so speakers stay as “Them”")
            }
            message = parts.joined(separator: "; ") + "."
            model.reload()
        }
    }

    private func applyRename() {
        guard let old = renaming else { return }
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        renaming = nil
        guard !name.isEmpty, name != old else { return }
        for file in ["transcript.txt", "transcript-clean.txt", "transcript-en.txt"] {
            let url = folder.appendingPathComponent(file)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            try? Transcript.rename(speaker: old, to: name, in: text).write(to: url, atomically: true, encoding: .utf8)
        }
        reloadLines()
        if let text = try? String(contentsOf: Translation.url(folder), encoding: .utf8) { english = Transcript.parse(text) }
        message = "Renamed “\(old)” to “\(name)”."
    }

    // MARK: Sharing

    private func markdown() -> String {
        CallExport.markdown(call: current, folder: folder, promises: model.promises)
    }

    private func exportMarkdown() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = CallExport.fileName(for: current) + ".md"
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        let text = markdown()
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                message = "Saved \(url.lastPathComponent)."
            } catch {
                message = "Couldn't save: \(error.localizedDescription)"
            }
        }
    }

    private func exportPDF() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = CallExport.fileName(for: current) + ".pdf"
        panel.allowedContentTypes = [.pdf]
        let text = markdown()
        let title = callTitle
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                message = PDFExport.write(markdown: text, title: title, to: url) ? "Saved \(url.lastPathComponent)." : "Couldn't make the PDF."
            }
        }
    }

    private func copyMarkdown() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(markdown(), forType: .string)
        message = "Copied. Paste it into Notion, Docs or an email."
    }

    private func sendToReminders() {
        let items = callPromises.filter { !$0.done }
        guard !items.isEmpty else { message = "There are no open promises to send."; return }
        let source = "the call “\(callTitle)”"
        Task { @MainActor in
            let result = await RemindersExport.send(items, source: source)
            if let problem = result.problem {
                message = problem
            } else if result.added == 0 {
                message = "Those promises are already in Reminders."
            } else {
                message = "Added \(result.added) promise\(result.added == 1 ? "" : "s") to Reminders."
            }
        }
    }

    private func sendToNotion() {
        guard NotionService.isConfigured else {
            message = "Notion isn't set up yet. Open Settings › Notion and follow the three steps."
            return
        }
        let items = callPromises.filter { !$0.done }
        guard !items.isEmpty else { message = "There are no open promises to send."; return }
        let source = "the call “\(callTitle)”"
        message = ""
        Task { @MainActor in
            do {
                let added = try await NotionService.send(items, source: source)
                message = "Sent \(added) promise\(added == 1 ? "" : "s") to Notion."
            } catch {
                message = error.localizedDescription
            }
        }
    }
}

/// An icon beside wrapped text, aligned to the first line.
struct BulletLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.caption)
            configuration.title.fixedSize(horizontal: false, vertical: true)
        }
    }
}
