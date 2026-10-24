import SwiftUI

/// The search box that opens with Command-K: one place to look across every call, note, file,
/// email, promise and project.
struct SearchPalette: View {
    @ObservedObject var model: LibraryModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var hits: [SearchHit] = []
    @State private var searching = false
    @State private var task: Task<Void, Never>?
    @FocusState private var focused: Bool

    private static let engine = SearchEngine()

    private struct Group: Identifiable {
        let kind: SearchHit.Kind
        let hits: [SearchHit]
        var id: Int { kind.rawValue }
    }

    private var grouped: [Group] {
        var order: [SearchHit.Kind] = []
        for hit in hits where !order.contains(hit.kind) { order.append(hit.kind) }
        return order.map { kind in Group(kind: kind, hits: hits.filter { $0.kind == kind }) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search calls, transcripts, notes, promises…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($focused)
                    .onSubmit { if let first = hits.first { model.open(first) } }
                if searching { ProgressView().controlSize(.small) }
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(14)
            Divider()

            if query.trimmingCharacters(in: .whitespaces).count < 2 {
                hint
            } else if hits.isEmpty, !searching {
                VStack(spacing: 6) {
                    Text("Nothing found for “\(query)”").font(.headline)
                    Text("Try fewer words, or part of a name.").font(.callout).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(grouped) { group in
                            Text(SearchHit.heading(for: group.kind))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                                .padding(.horizontal, 6)
                            ForEach(group.hits) { hit in
                                row(hit)
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(width: 660, height: 500)
        .onAppear { focused = true }
        .onChange(of: query) { run() }
    }

    private var hint: some View {
        VStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass").font(.largeTitle).foregroundStyle(Theme.brand)
            Text("Search everything").font(.headline)
            Text("Finds the exact moment something was said in any call, and opens the video right there. Also searches summaries, notes, files, emails, promises and projects. Press Return to open the first result.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ hit: SearchHit) -> some View {
        Button {
            model.open(hit)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: icon(for: hit.kind))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.title).font(.callout.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(hit.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func icon(for kind: SearchHit.Kind) -> String {
        switch kind {
        case .call: return "video"
        case .moment: return "quote.bubble"
        case .note: return "doc.text"
        case .promise: return "checklist"
        case .project: return "folder"
        }
    }

    /// Searches shortly after the last key press, away from the main thread.
    private func run() {
        task?.cancel()
        let text = query
        guard text.trimmingCharacters(in: .whitespaces).count >= 2 else {
            hits = []
            searching = false
            return
        }
        let inputs = SearchEngine.Inputs(
            calls: model.memory.records,
            items: model.knowledge.items,
            promises: model.commitments.items,
            projects: model.projectNames,
            folderFor: { LibraryModel.folder(for: $0) }
        )
        searching = true
        task = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            if Task.isCancelled { return }
            let found = await Task.detached(priority: .userInitiated) { Self.engine.search(text, in: inputs) }.value
            if Task.isCancelled { return }
            await MainActor.run {
                hits = found
                searching = false
            }
        }
    }
}
