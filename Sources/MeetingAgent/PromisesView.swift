import SwiftUI

/// One list of everything promised: what you owe, and what others owe you.
struct PromisesView: View {
    @ObservedObject var model: LibraryModel
    @State private var tab = Tab.mine
    @State private var showAdd = false

    enum Tab { case mine, theirs, done }

    private var shown: [Commitment] {
        let all = model.promises
        switch tab {
        case .mine: return all.filter { !$0.done && $0.isMine }
        case .theirs: return all.filter { !$0.done && !$0.isMine }
        case .done: return all.filter { $0.done }
        }
    }

    private func sorted(_ list: [Commitment]) -> [Commitment] {
        list.sorted { left, right in
            switch (left.due, right.due) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.created > right.created
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Promises").font(.largeTitle.bold())
                        Text("Found automatically in your calls. Tick them off as they get done.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        showAdd = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(SoftButtonStyle())
                }
                Picker("", selection: $tab) {
                    Text("I owe").tag(Tab.mine)
                    Text("Owed to me").tag(Tab.theirs)
                    Text("Done").tag(Tab.done)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
            }
            .padding(.horizontal, 28)
            .padding(.top, 22)
            .padding(.bottom, 14)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if shown.isEmpty {
                        Text(emptyText).font(.callout).foregroundStyle(.secondary).card()
                    } else {
                        PromiseList(model: model, items: sorted(shown), showProject: true)
                    }
                }
                .padding(28)
                .frame(maxWidth: 820, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(isPresented: $showAdd) { AddPromiseSheet(model: model) }
    }

    private var emptyText: String {
        switch tab {
        case .mine: return "Nothing you owe right now. Promises you make on calls will show up here."
        case .theirs: return "Nothing is owed to you right now."
        case .done: return "Nothing ticked off yet."
        }
    }
}

/// A list of promises with a tick box on each.
struct PromiseList: View {
    @ObservedObject var model: LibraryModel
    let items: [Commitment]
    var showProject: Bool

    var body: some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                row(item).padding(.vertical, 10)
                if item.id != items.last?.id { Divider() }
            }
        }
        .padding(.horizontal, 14)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func row(_ item: Commitment) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                model.setDone(item, !item.done)
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(item.done ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .help(item.done ? "Mark as not done" : "Mark as done")

            VStack(alignment: .leading, spacing: 4) {
                Text(item.text)
                    .font(.callout)
                    .strikethrough(item.done)
                    .foregroundColor(item.done ? .secondary : .primary)
                HStack(spacing: 6) {
                    if !item.isMine { Chip(text: item.owner, icon: "person") }
                    if let due = item.due {
                        Chip(
                            text: item.isOverdue ? "Overdue · \(due.formatted(date: .abbreviated, time: .omitted))" : "Due \(due.formatted(date: .abbreviated, time: .omitted))",
                            icon: "calendar",
                            tint: item.isOverdue ? .red : .secondary
                        )
                    }
                    let project = model.project(of: item)
                    if showProject, !project.isEmpty { Chip(text: project, icon: "folder", tint: Theme.accent) }
                    if let call = model.call(for: item) {
                        Button("From call, \(call.date.formatted(date: .abbreviated, time: .omitted))") { model.detailCall = call }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            Spacer(minLength: 0)
            Menu {
                Button("Delete", role: .destructive) { model.removePromise(item) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }
}

struct AddPromiseSheet: View {
    @ObservedObject var model: LibraryModel
    @State private var text = ""
    @State private var mine = true
    @State private var person = ""
    @State private var hasDue = false
    @State private var due = Date()
    @State private var project = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add a promise").font(.title3.bold())
            TextField("What was promised?", text: $text).textFieldStyle(.roundedBorder)
            Picker("Who owes it?", selection: $mine) {
                Text("I do").tag(true)
                Text("Someone else").tag(false)
            }
            .pickerStyle(.segmented)
            if !mine {
                TextField("Their name", text: $person).textFieldStyle(.roundedBorder)
            }
            Toggle("Has a due date", isOn: $hasDue)
            if hasDue { DatePicker("Due", selection: $due, displayedComponents: .date) }
            Picker("Project", selection: $project) {
                Text("None").tag("")
                ForEach(model.projectNames, id: \.self) { Text($0).tag($0) }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    model.addPromise(text: text, owner: mine ? "You" : (person.trimmed.isEmpty ? "Them" : person), due: hasDue ? due : nil, project: project)
                    dismiss()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(text.trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}

extension Array where Element == Commitment {
    /// Soonest due date first, then the ones without a date, newest first.
    var byDue: [Commitment] {
        sorted { left, right in
            switch (left.due, right.due) {
            case let (a?, b?): return a < b
            case (_?, nil): return true
            case (nil, _?): return false
            default: return left.created > right.created
            }
        }
    }
}
