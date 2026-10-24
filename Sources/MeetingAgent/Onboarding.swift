import AppKit
import SwiftUI

/// The first-run walkthrough: what the app does, the three permissions it needs, and connecting the AI.
struct OnboardingSheet: View {
    @ObservedObject var model: LibraryModel
    var onFinish: () -> Void
    /// Remembered, so if macOS asks to quit and reopen after a permission, setup picks up where it left off.
    @AppStorage("onboardingPage") private var page = 0

    private struct Page {
        let icon: String
        let title: String
        let text: String
    }

    private let pages = [
        Page(icon: "waveform.circle.fill",
             title: "Your calls, remembered",
             text: "Meeting Agent records your calls, writes the notes, and remembers every promise. Then you can ask it anything about any project."),
        Page(icon: "rectangle.stack.fill",
             title: "How it works",
             text: "1. Join a call. I'll offer to record it.\n2. Watch the small window for a live recap and good questions to ask.\n3. After the call, read the summary and tick off promises.\n4. Keep calls, files and emails together in a project, and ask questions across all of it."),
        Page(icon: "lock.shield.fill",
             title: "Private by design",
             text: "Recordings stay on your Mac. Only text is ever sent to the AI, and you can keep a whole project on this Mac only. Always tell people on the call that you're recording."),
    ]

    private var permissionsIndex: Int { pages.count }
    private var aiIndex: Int { pages.count + 1 }
    private var lastIndex: Int { pages.count + 1 }
    private var safeIndex: Int { min(max(page, 0), pages.count - 1) }

    var body: some View {
        VStack(spacing: 14) {
            Group {
                if page < permissionsIndex {
                    infoPage(pages[safeIndex], index: safeIndex)
                } else if page == permissionsIndex {
                    permissionsPage
                } else {
                    aiPage
                }
            }
            .id(page)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            HStack(spacing: 6) {
                ForEach(0...lastIndex, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Theme.accent : Color.primary.opacity(0.18))
                        .frame(width: index == page ? 20 : 7, height: 7)
                }
            }
            HStack {
                if page > 0 { Button("Back") { page -= 1 }.buttonStyle(SoftButtonStyle()) }
                Spacer()
                if page < lastIndex {
                    Button("Next") { page += 1 }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                } else {
                    Button(model.hasKey ? "Finish" : "Skip for now", action: onFinish)
                        .buttonStyle(PrimaryButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(28)
        .frame(width: 640, height: 620)
        .animation(.easeInOut(duration: 0.25), value: page)
        .onAppear {
            if page > lastIndex || page < 0 { page = 0 }
            model.refreshSetup()
        }
    }

    // MARK: Pages

    private func infoPage(_ item: Page, index: Int) -> some View {
        VStack(spacing: 18) {
            Spacer(minLength: 24)
            if index == 0 {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 104, height: 104)
                    .shadow(color: Theme.accent.opacity(0.35), radius: 18, x: 0, y: 8)
            } else {
                BrandTile(symbol: item.icon, size: 84)
            }
            Text(item.title).font(.system(size: 28, weight: .bold))
            Text(item.text)
                .font(.body)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 440, alignment: .leading)
        }
    }

    private var permissionsPage: some View {
        VStack(spacing: 14) {
            BrandTile(symbol: "hand.raised.fill", size: 64)
            Text("Allow three things").font(.system(size: 26, weight: .bold))
            Text("macOS will ask you to approve each one. Press Allow, then say yes in the window that appears.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 12) {
                permissionRow(done: model.setup.screen,
                              name: "Screen & system audio recording",
                              why: "Lets me record the call window and hear the other people.") { model.grant(.screen) }
                permissionRow(done: model.setup.mic,
                              name: "Microphone",
                              why: "So your side of the conversation is captured too.") { model.grant(.mic) }
                permissionRow(done: model.setup.speech,
                              name: "Speech recognition",
                              why: "Turns the audio into text. It happens on your Mac.") { model.grant(.speech) }
            }
            .card()
            Text("If Screen Recording still shows as not allowed after you switch it on, quit and reopen Meeting Agent. Setup will be waiting here.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var aiPage: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BrandTile(symbol: "sparkles", size: 40)
                Text("Connect the AI").font(.system(size: 26, weight: .bold))
                Spacer()
                if model.hasKey { Chip(text: "Connected", icon: "checkmark.circle.fill", tint: .green) }
            }
            ScrollView {
                AISetupGuide(model: model)
                    .padding(.trailing, 6)
            }
        }
    }

    private func permissionRow(done: Bool, name: String, why: String, action: @escaping () -> Void) -> some View {
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
                Button("Allow", action: action).buttonStyle(SoftButtonStyle())
            }
        }
    }
}
