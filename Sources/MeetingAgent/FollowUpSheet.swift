import AppKit
import SwiftUI

/// Drafts a follow-up email after a call. Nothing is sent: it opens in your mail app, or you copy it.
struct FollowUpSheet: View {
    @ObservedObject var model: LibraryModel
    let call: CallRecord
    @State private var subject = ""
    @State private var email = ""
    @State private var busy = true
    @State private var problem = ""
    @Environment(\.dismiss) private var dismiss

    private var recipients: [String] {
        (call.attendees ?? []).map { $0.email }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Follow-up email").font(.title3.bold())
            if busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Writing a draft…").font(.callout) }
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else if !problem.isEmpty {
                Text(problem).font(.callout).foregroundColor(.orange)
                Button("Try again", action: write).buttonStyle(SoftButtonStyle())
            } else {
                if !recipients.isEmpty {
                    Text("To: \(recipients.joined(separator: ", "))").font(.caption).foregroundStyle(.secondary)
                }
                TextField("Subject", text: $subject).textFieldStyle(.roundedBorder)
                TextEditor(text: $email)
                    .font(.body)
                    .frame(minHeight: 240)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.15)))
                Text("This is a draft. Read it and change anything before you send.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("Subject: \(subject)\n\n\(email)", forType: .string)
                }
                .buttonStyle(SoftButtonStyle())
                .disabled(busy || email.isEmpty)
                Button("Open in Mail") { openMail() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(busy || email.isEmpty)
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear(perform: write)
    }

    private func write() {
        busy = true
        problem = ""
        Task { @MainActor in
            do {
                let draft = try await model.draftFollowUp(for: call)
                subject = draft.subject
                email = draft.body
            } catch {
                problem = error.localizedDescription
            }
            busy = false
        }
    }

    private func openMail() {
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = recipients.joined(separator: ",")
        parts.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: email)]
        if let url = parts.url { NSWorkspace.shared.open(url) }
    }
}
