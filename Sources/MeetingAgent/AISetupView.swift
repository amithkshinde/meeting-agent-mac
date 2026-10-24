import AppKit
import SwiftUI

/// What a pasted key looks like, so we can help before it is saved.
enum KeyShape {
    case empty, tooShort, claude, gemini, openAI, unknown

    static func detect(_ raw: String) -> KeyShape {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty { return .empty }
        if key.hasPrefix("sk-ant-") { return key.count < 30 ? .tooShort : .claude }
        if key.hasPrefix("sk-") { return .openAI }
        if key.hasPrefix("AIza") { return key.count < 30 ? .tooShort : .gemini }
        return key.count < 20 ? .tooShort : .unknown
    }
}

extension AIAccess {
    /// A plain-words name for whichever AI is in use now.
    static var providerLabel: String {
        if localEverywhere { return "This Mac's built-in AI" }
        guard let key = Keychain.read() else { return "Not set up" }
        return key.hasPrefix("sk-ant-") ? "Claude" : "Google Gemini"
    }
}

enum AIChoice: String, CaseIterable, Identifiable {
    case gemini, claude, mac

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemini: return "Google Gemini"
        case .claude: return "Claude"
        case .mac: return "This Mac"
        }
    }

    var price: String {
        switch self {
        case .gemini: return "Free"
        case .claude: return "Pay as you go"
        case .mac: return "Free, no sign-up"
        }
    }

    var summary: String {
        switch self {
        case .gemini: return "Easiest way to try it. Free keys have a small daily limit."
        case .claude: return "Best answers and no tight daily limit. Needs a card."
        case .mac: return "Private. Needs Apple Intelligence. Simpler answers."
        }
    }
}

/// A guided "connect the AI" screen: pick Gemini, Claude or this Mac, follow the steps to get a key, paste it, test it.
struct AISetupGuide: View {
    @ObservedObject var model: LibraryModel
    @State private var choice: AIChoice = .gemini
    @State private var draft = ""
    @AppStorage("aiLocalOnly") private var aiLocal = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick one. You can change it later in Settings.")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 10) {
                ForEach(AIChoice.allCases) { option in
                    optionCard(option)
                }
            }

            switch choice {
            case .gemini: geminiSteps
            case .claude: claudeSteps
            case .mac: macPanel
            }

            if choice != .mac { pasteSection }
            helpSection
        }
        .onAppear {
            if aiLocal { choice = .mac }
            else if Keychain.read()?.hasPrefix("sk-ant-") == true { choice = .claude }
        }
    }

    // MARK: Choice cards

    private func optionCard(_ option: AIChoice) -> some View {
        let selected = choice == option
        return Button {
            choice = option
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(option.title).font(.callout.weight(.semibold))
                Text(option.price).font(.caption.weight(.medium)).foregroundColor(Theme.accent)
                Text(option.summary).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.12) : Color.primary.opacity(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(selected ? Theme.accent : Color.clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
    }

    // MARK: Steps

    private func stepRow(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 20, height: 20)
                .background(Theme.accent, in: Circle())
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func openPage(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    private var geminiSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Get a free Gemini key").font(.headline)
            Button("Open Google AI Studio") { openPage("https://aistudio.google.com/apikey") }
                .buttonStyle(PrimaryButtonStyle())
            stepRow(1, "Click the button above. Sign in with your Google account (any Gmail works) and accept the terms if asked.")
            stepRow(2, "Click “Create API key”. If it asks for a project, choose “Create API key in new project”.")
            stepRow(3, "Click the copy icon next to your new key.")
            stepRow(4, "Come back here, paste it below and press Save.")
            Text("Good to know: free keys allow only a small number of AI requests a day, so on busy days a call summary can be delayed until tomorrow. Google may also use what you send on the free tier to improve its products. For regular or confidential use, choose Claude or This Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private var claudeSteps: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Get a Claude key").font(.headline)
            HStack {
                Button("Open Claude Console") { openPage("https://console.anthropic.com/settings/keys") }
                    .buttonStyle(PrimaryButtonStyle())
                Button("Billing page") { openPage("https://console.anthropic.com/settings/billing") }
                    .buttonStyle(SoftButtonStyle())
            }
            stepRow(1, "Click “Open Claude Console”. Sign up or sign in (email or Google both work).")
            stepRow(2, "Add a payment method and a small amount of credit under Settings › Billing. Keys only work once billing is set up.")
            stepRow(3, "Go to Settings › API keys and click “Create Key”. Name it “Meeting Agent”.")
            stepRow(4, "Copy the key straight away. It starts with sk-ant- and is shown only once.")
            stepRow(5, "Come back here, paste it below and press Save.")
            Text("Good to know: you pay only for what you use. Meeting Agent uses a low-cost Claude model, and an hour-long call is roughly under a dollar. You can watch usage in the console.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .card()
    }

    private var macPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Use this Mac's built-in AI").font(.headline)
            if AIAccess.localAvailable {
                Text("Your Mac's built-in AI is ready. Nothing you write or say leaves this Mac, and there is no key and no sign-up. Answers are shorter and less detailed than Claude or Gemini, and very long calls are trimmed.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Button(aiLocal ? "Using this Mac's AI" : "Use this Mac's AI") {
                    aiLocal = true
                    model.refreshSetup()
                    model.testKey()
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(aiLocal)
                status
            } else {
                Text(AIAccess.localProblem)
                    .font(.callout)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can pick Gemini or Claude instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .card()
    }

    // MARK: Paste and save

    private var shape: KeyShape { KeyShape.detect(draft) }

    private var canSave: Bool {
        switch shape {
        case .claude, .gemini, .unknown: return true
        default: return false
        }
    }

    private var shapeNote: (text: String, color: Color)? {
        switch shape {
        case .empty: return nil
        case .tooShort: return ("That looks too short. Make sure you copied the whole key.", .orange)
        case .openAI: return ("That looks like an OpenAI key. Meeting Agent works with Claude or Google Gemini keys.", .orange)
        case .claude: return ("Looks like a Claude key.", .green)
        case .gemini: return ("Looks like a Google Gemini key.", .green)
        case .unknown: return ("This doesn't look like the usual format. Press Save and I'll test it.", Color.secondary)
        }
    }

    private var pasteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(model.hasKey ? "Replace your key" : "Paste your key").font(.headline)
            HStack {
                SecureField("Paste your key here", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Paste from clipboard") {
                    if let text = NSPasteboard.general.string(forType: .string) {
                        draft = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .buttonStyle(SoftButtonStyle())
                Button("Save", action: save)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canSave)
            }
            if let note = shapeNote {
                Text(note.text).font(.caption).foregroundColor(note.color)
            }
            status
        }
    }

    private func save() {
        guard canSave else { return }
        aiLocal = false
        model.saveKey(draft)
        draft = ""
    }

    private var testPassed: Bool {
        model.keyTest.hasPrefix("Connected") || model.keyTest.hasPrefix("The on-device AI is ready")
    }

    @ViewBuilder private var status: some View {
        if model.keyTesting {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Checking…").font(.caption)
            }
        } else if !model.keyTest.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label(model.keyTest, systemImage: testPassed ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundColor(testPassed ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                if !testPassed, model.keyTest.lowercased().contains("quota") {
                    Text("Your key is real, but its free limit for today is used up. Try again tomorrow, or choose Claude.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: Help

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Which one should I pick?") {
                Text("Just trying it out: Gemini, it's free. Using it for real meetings: Claude, because there's no tight daily limit and the answers are best. Private or confidential work, or you don't want to sign up for anything: This Mac, if your Mac supports it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            DisclosureGroup("Is my key safe?") {
                Text("It is stored in your Mac's Keychain, not in a file, and it is only sent to Google or Anthropic to get answers. Don't share it. If it ever leaks, delete it on the provider's website and make a new one.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            DisclosureGroup("What gets sent to the AI?") {
                Text("Only text: transcripts, notes and the text of files you add. Audio and video never leave your Mac. Projects marked “On this Mac only” are never sent anywhere.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            DisclosureGroup("The website looks different from the steps") {
                Text("Websites change their layout. Sign in, then look for “API keys”: in Google AI Studio it's in the left menu or top right, and in the Claude Console it's under Settings. You're looking for a button that says “Create API key” or “Create Key”.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
            DisclosureGroup("It says my key doesn't work") {
                Text("Check that you copied the whole key with nothing extra before or after it. For Claude, billing must be set up first. For Gemini, make sure you copied the key itself and not the project name.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.top, 4)
            }
        }
        .font(.callout)
    }
}

/// The guide in its own window, opened from Settings and the Home checklist.
struct AISetupSheet: View {
    @ObservedObject var model: LibraryModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Connect the AI").font(.title2.bold())
                Spacer()
                Button(model.hasKey ? "Done" : "Close", action: onClose)
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            ScrollView {
                AISetupGuide(model: model)
                    .padding(.trailing, 6)
            }
        }
        .padding(24)
        .frame(width: 640, height: 640)
    }
}
