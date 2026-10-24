import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A page for one project, or for one of the library views (all material, general notes, unassigned calls).
struct ProjectPage: View {
    @ObservedObject var model: LibraryModel
    @State private var noteKind: String?
    @State private var showFiles = false
    @State private var showAddCalls = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var showDelete = false
    @State private var showMerge = false
    @State private var mergeTarget = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            pageBody
        }
        .sheet(isPresented: Binding(get: { noteKind != nil }, set: { if !$0 { noteKind = nil } })) {
            AddNoteSheet(model: model, kind: noteKind ?? "note")
        }
        .sheet(isPresented: $showAddCalls) { AddCallsSheet(model: model) }
        .sheet(isPresented: $showRename) {
            NameSheet(title: "Rename project", prompt: "Calls, files and notes keep their place.", action: "Rename", text: $renameText) {
                model.rename(to: renameText)
            }
        }
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { model.importFiles(urls) }
        }
        .confirmationDialog("Delete \(model.title)?", isPresented: $showDelete) {
            Button("Delete project", role: .destructive) { model.deleteProject() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its calls go back to Unassigned. Its notes, files and emails are deleted. Recordings stay on disk.")
        }
        .confirmationDialog("Merge \(model.title) into \(mergeTarget)?", isPresented: $showMerge) {
            Button("Merge") { model.merge(into: mergeTarget) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All calls, files, notes and emails move into \(mergeTarget). This can't be undone.")
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard model.selection != LibraryModel.unassignedKey else { return false }
            var urls: [URL] = []
            let lock = NSLock()
            let group = DispatchGroup()
            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url { lock.lock(); urls.append(url); lock.unlock() }
                    group.leave()
                }
            }
            group.notify(queue: .main) { model.importFiles(urls) }
            return true
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.title).font(.largeTitle.bold()).lineLimit(1)
                    HStack(spacing: 6) {
                        Chip(text: "\(model.calls.count) call\(model.calls.count == 1 ? "" : "s")", icon: "video")
                        Chip(text: "\(model.items.count) file\(model.items.count == 1 ? "" : "s") & note\(model.items.count == 1 ? "" : "s")", icon: "doc.text")
                        if model.isOnDeviceOnly { Chip(text: "On this Mac only", icon: "lock.fill", tint: .green) }
                    }
                }
                Spacer()
                if model.selection != LibraryModel.unassignedKey { addMenu }
                if model.isProject { moreMenu }
            }
            Picker("", selection: $model.projectTab) {
                if model.isProject { Text("Overview").tag(LibraryModel.ProjectTab.overview) }
                Text("Ask").tag(LibraryModel.ProjectTab.ask)
                Text("Content").tag(LibraryModel.ProjectTab.content)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)
        }
        .padding(.horizontal, 28)
        .padding(.top, 22)
        .padding(.bottom, 14)
    }

    private var addMenu: some View {
        Menu {
            Button("Write a note…") { noteKind = "note" }
            Button("Paste an email…") { noteKind = "email" }
            Button("Add files…") { showFiles = true }
            if model.isProject {
                Divider()
                Button("Add earlier calls…") { showAddCalls = true }
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var moreMenu: some View {
        Menu {
            Button("Rename…") { renameText = model.selection; showRename = true }
            Menu("Merge into…") {
                ForEach(model.projectNames.filter { $0.lowercased() != model.selection.lowercased() }, id: \.self) { name in
                    Button(name) { mergeTarget = name; showMerge = true }
                }
            }
            Divider()
            Button(model.isOnDeviceOnly ? "Allow the cloud AI for this project" : "Keep this project on this Mac only") {
                model.setOnDeviceOnly(!model.isOnDeviceOnly)
            }
            Divider()
            Button("Delete project…", role: .destructive) { showDelete = true }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Body

    @ViewBuilder
    private var pageBody: some View {
        switch model.projectTab {
        case .overview where model.isProject:
            OverviewTab(model: model, addNote: { noteKind = "note" }, addFiles: { showFiles = true })
        case .content:
            ContentTab(model: model)
        default:
            AskPanel(model: model)
        }
    }
}

// MARK: - Overview

private struct OverviewTab: View {
    @ObservedObject var model: LibraryModel
    var addNote: () -> Void
    var addFiles: () -> Void

    private var hasMaterial: Bool { !model.calls.isEmpty || !model.items.isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !model.briefText.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Project brief").font(.headline)
                            Spacer()
                            if let date = model.briefDate {
                                Text("Updated \(date.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Button(model.briefBusy ? "Updating…" : "Refresh") { model.generateBrief(for: model.selection) }
                                .buttonStyle(SoftButtonStyle())
                                .disabled(model.briefBusy)
                        }
                        MarkdownLite(text: model.briefText).textSelection(.enabled)
                    }
                    .card()
                } else if hasMaterial {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No brief yet").font(.headline)
                        Text("A brief is a one-page summary of this project: where things stand, who is involved, what was promised, and what to ask next. It also helps the live suggestions during calls.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        if model.hasKey {
                            Button(model.briefBusy ? "Writing…" : "Write the brief") { model.generateBrief(for: model.selection) }
                                .buttonStyle(PrimaryButtonStyle())
                                .disabled(model.briefBusy)
                        } else {
                            Button("Connect the AI first") { model.selection = LibraryModel.settingsKey }
                                .buttonStyle(PrimaryButtonStyle())
                        }
                    }
                    .card()
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("This project is empty").font(.headline)
                        Text("Add things so the app can help you: write a note, drop in a file or an email, or record a call and file it here.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Write a note", action: addNote).buttonStyle(PrimaryButtonStyle())
                            Button("Add files", action: addFiles).buttonStyle(SoftButtonStyle())
                        }
                        Text("Tip: you can also drag files straight onto this page.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .card()
                }

                let openPromises = model.promises.filter { !$0.done && model.project(of: $0).lowercased() == model.selection.lowercased() }.byDue
                if !openPromises.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Open promises").font(.headline)
                        PromiseList(model: model, items: openPromises, showProject: false)
                    }
                }

                if !model.status.isEmpty {
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }

                if hasMaterial {
                    HStack {
                        Image(systemName: "bubble.left.and.text.bubble.right").foregroundStyle(Theme.accent)
                        Text("Ask anything about this project").font(.callout)
                        Spacer()
                        Button("Open chat") { model.projectTab = .ask }.buttonStyle(SoftButtonStyle())
                    }
                    .card(padding: 12)
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Ask

struct AskPanel: View {
    @ObservedObject var model: LibraryModel
    @State private var draft = ""

    private var suggestions: [String] {
        if model.isProject {
            return ["Where does this project stand?", "What did we promise each other?", "What is still unresolved?"]
        }
        return ["What were my last calls about?", "Which action items are still open?"]
    }

    var body: some View {
        VStack(spacing: 0) {
            if !model.hasKey {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Connect the AI to ask questions").font(.headline)
                    Text("It's free with a Google key and takes a minute.").font(.callout).foregroundStyle(.secondary)
                    Button("Connect") { model.selection = LibraryModel.settingsKey }.buttonStyle(PrimaryButtonStyle())
                }
                .card()
                .padding(28)
                .frame(maxWidth: 560)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if model.messages.isEmpty { intro }
                            ForEach(model.messages) { message in
                                bubble(message).id(message.id)
                            }
                            if model.asking {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Looking through your calls, files and notes…").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .padding(28)
                        .frame(maxWidth: 820, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .onChange(of: model.messages.count) { proxy.scrollTo("end") }
                    .onChange(of: model.asking) { proxy.scrollTo("end") }
                }
                Divider()
                inputBar
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.calls.isEmpty && model.items.isEmpty {
                Text("There's nothing here to ask about yet. Add a note or a file, or record a call, then come back.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text("Ask me anything about this \(model.isProject ? "project" : "material").")
                    .font(.title3.weight(.semibold))
                Text("Every answer shows exactly which call, file or email it came from.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                ForEach(suggestions, id: \.self) { text in
                    Button(text) { model.ask(text) }.buttonStyle(SoftButtonStyle())
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: ChatMessage) -> some View {
        if message.fromYou {
            HStack {
                Spacer(minLength: 80)
                Text(message.text)
                    .padding(10)
                    .foregroundColor(.white)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .textSelection(.enabled)
            }
        } else if message.isError {
            Text(message.text).font(.callout).foregroundColor(.orange)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                MarkdownLite(text: message.text).textSelection(.enabled)
                SourceListView(sources: message.sources)
            }
            .card()
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask a question…", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.title)
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.accent)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.asking)
            if !model.messages.isEmpty {
                Button("Clear") { model.clearChat() }.buttonStyle(.link)
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 12)
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !model.asking else { return }
        draft = ""
        model.ask(text)
    }
}

// MARK: - Content

private struct ContentTab: View {
    @ObservedObject var model: LibraryModel
    @State private var expanded = Set<String>()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if model.selection != LibraryModel.generalKey { callsSection }
                if model.selection != LibraryModel.unassignedKey { itemsSection }
                if !model.status.isEmpty {
                    Text(model.status).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var callsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calls").font(.title3.bold())
            if model.calls.isEmpty {
                Text(model.selection == LibraryModel.unassignedKey
                     ? "Every call is filed in a project. Nothing to sort."
                     : "No calls here yet. Record one, or use Add › Add earlier calls.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.calls) { call in
                        HStack {
                            CallRow(call: call, showProject: !model.isProject) { model.detailCall = call }
                            moveMenu(for: call)
                        }
                        .padding(.vertical, 10)
                        if call.id != model.calls.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func moveMenu(for call: CallRecord) -> some View {
        Menu {
            ForEach(model.projectNames, id: \.self) { name in
                Button(name) { model.moveCall(call, to: name) }
            }
            if call.client != MemoryStore.unassigned {
                Divider()
                Button("Take out of project") { model.moveCall(call, to: MemoryStore.unassigned) }
            }
        } label: {
            Image(systemName: "folder.badge.plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Move to a project")
    }

    private var itemsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Files, emails and notes").font(.title3.bold())
            if model.items.isEmpty {
                Text("Nothing here yet. Use Add at the top, or drag files onto this page.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.items) { item in
                        itemRow(item).padding(.vertical, 10)
                        if item.id != model.items.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func itemRow(_ item: KnowledgeItem) -> some View {
        let isOpen = expanded.contains(item.id)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(for: item.kind))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.callout.weight(.semibold)).lineLimit(1)
                    Text("\(Retriever.kindLabel(item.kind)) · \(item.date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !model.isProject {
                    Chip(text: item.client.isEmpty ? "General" : item.client, icon: "folder", tint: item.client.isEmpty ? Color.secondary : Theme.accent)
                }
                if let path = item.path, FileManager.default.fileExists(atPath: path) {
                    Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }.buttonStyle(.link).font(.caption)
                }
                Button(isOpen ? "Hide" : "Preview") {
                    if isOpen { expanded.remove(item.id) } else { expanded.insert(item.id) }
                }
                .buttonStyle(.link)
                .font(.caption)
                Menu {
                    Menu("Move to…") {
                        Button("General (all calls)") { model.moveItem(item, to: "") }
                        ForEach(model.projectNames, id: \.self) { name in
                            Button(name) { model.moveItem(item, to: name) }
                        }
                    }
                    Button("Delete", role: .destructive) { model.remove(item) }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if isOpen {
                Text(String(item.text.prefix(1800)) + (item.text.count > 1800 ? "…" : ""))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.leading, 34)
            }
        }
    }

    private func icon(for kind: String) -> String {
        switch kind {
        case "email": return "envelope"
        case "file": return "doc"
        default: return "note.text"
        }
    }
}

// MARK: - Sheets

struct AddNoteSheet: View {
    @ObservedObject var model: LibraryModel
    let kind: String
    @State private var title = ""
    @State private var text = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(kind == "email" ? "Paste an email" : "Write a note").font(.title3.bold())
            Text(kind == "email"
                 ? "Paste the whole email, including who it's from and the date."
                 : "Anything worth remembering: background, goals, promises, who is who.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(model.isProject ? "It will be filed under \(model.selection)." : "It will be saved as a general note for every call.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if kind == "email" {
                Text("From Gmail: open the email, click ⋮ › Download message, then drag the .eml file onto a project page. That keeps the sender and date too.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            TextField("Title (optional)", text: $title).textFieldStyle(.roundedBorder)
            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 220)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    model.addNote(kind: kind, title: title, text: text)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}

struct AddCallsSheet: View {
    @ObservedObject var model: LibraryModel
    @State private var picked = Set<String>()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add earlier calls to \(model.selection)").font(.title3.bold())
            if model.otherCalls.isEmpty {
                Text("All your calls are already in this project.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Tick the calls that belong here. They move out of wherever they are now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                List(model.otherCalls) { call in
                    Toggle(isOn: Binding(
                        get: { picked.contains(call.id) },
                        set: { on in if on { picked.insert(call.id) } else { picked.remove(call.id) } }
                    )) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(call.app) call · \(call.date.formatted(date: .abbreviated, time: .shortened))")
                            Text(call.client == MemoryStore.unassigned ? "Not in a project" : "In \(call.client)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(height: 260)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add \(picked.count) call\(picked.count == 1 ? "" : "s")") {
                    model.addCalls(ids: picked)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(picked.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
    }
}
