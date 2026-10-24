import AppKit
import AVFoundation
import Speech
import SwiftUI

// MARK: - Sources and chat

/// Where a fact in an answer came from: a call, a file, an email or a note.
struct SourceRef: Identifiable, Equatable {
    let id: Int              // the number shown as [S1], [S2]…
    let label: String        // "Call 12 Oct 2026 (Acme)"
    let detail: String       // "transcript, around 14:32"
    let snippet: String      // the passage itself
    let callId: String?      // set for calls
    let path: String?        // set for files that were added from disk
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let fromYou: Bool
    let text: String
    var isError = false
    var sources: [SourceRef] = []
}

/// Picks out the sources an answer actually cited, such as [S2] or [S1, S3].
func citedSources(in answer: String, from sources: [SourceRef]) -> [SourceRef] {
    guard let groups = try? NSRegularExpression(pattern: "\\[[^\\]]*\\]"),
          let numbers = try? NSRegularExpression(pattern: "S(\\d+)") else { return [] }
    var used = Set<Int>()
    let whole = NSRange(answer.startIndex..., in: answer)
    for group in groups.matches(in: answer, range: whole) {
        guard let range = Range(group.range, in: answer) else { continue }
        let inside = String(answer[range])
        let insideRange = NSRange(inside.startIndex..., in: inside)
        for match in numbers.matches(in: inside, range: insideRange) {
            if let numberRange = Range(match.range(at: 1), in: inside), let value = Int(inside[numberRange]) {
                used.insert(value)
            }
        }
    }
    return sources.filter { used.contains($0.id) }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Setup status

/// What still has to be switched on before the app can do its job.
struct SetupStatus: Equatable {
    var screen: Bool
    var mic: Bool
    var speech: Bool
    var key: Bool

    var complete: Bool { screen && mic && speech && key }
    var doneCount: Int { [screen, mic, speech, key].filter { $0 }.count }

    static func read() -> SetupStatus {
        SetupStatus(
            screen: CGPreflightScreenCaptureAccess(),
            mic: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            speech: SFSpeechRecognizer.authorizationStatus() == .authorized,
            key: AIAccess.isReady
        )
    }
}

// MARK: - Look and feel
// Cards, buttons and the brand colours live in Theme.swift.

/// A small label with an icon, used for project names and counts.
struct Chip: View {
    let text: String
    var icon: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).font(.caption2) }
            Text(text).font(.caption).lineLimit(1)
        }
        .foregroundColor(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Renders the simple Markdown the AI writes: ## headings, - bullets and **bold**.
struct MarkdownLite: View {
    let text: String
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 6) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, rawLine in
                line(rawLine)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func line(_ raw: String) -> some View {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            Color.clear.frame(height: 2)
        } else if trimmed.hasPrefix("#") {
            Text(trimmed.drop(while: { $0 == "#" || $0 == " " }).description)
                .font(compact ? .caption.bold() : .headline)
                .padding(.top, compact ? 2 : 6)
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                Text(inline(String(trimmed.dropFirst(2)))).fixedSize(horizontal: false, vertical: true)
            }
            .font(compact ? .caption : .body)
        } else {
            Text(inline(trimmed))
                .font(compact ? .caption : .body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func inline(_ source: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: source, options: options)) ?? AttributedString(source)
    }
}

/// "Where this came from": the numbered sources an answer used, with a way to open each one.
struct SourceListView: View {
    let sources: [SourceRef]
    var compact = false

    var body: some View {
        if sources.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Where this came from")
                    .font(compact ? .caption2.bold() : .caption.bold())
                    .foregroundStyle(.secondary)
                ForEach(sources) { source in
                    HStack(alignment: .top, spacing: 8) {
                        Text("S\(source.id)")
                            .font(.caption2.bold())
                            .foregroundColor(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 4))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.label).font(compact ? .caption : .callout).bold()
                            if !source.detail.isEmpty {
                                Text(source.detail).font(.caption2).foregroundStyle(.secondary)
                            }
                            if !compact, !source.snippet.isEmpty {
                                Text("“\(source.snippet)”")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                            }
                        }
                        Spacer(minLength: 0)
                        if let target = openTarget(for: source) {
                            Button("Open") { NSWorkspace.shared.open(target) }
                                .buttonStyle(.link)
                                .font(.caption)
                        }
                    }
                }
            }
            .padding(compact ? 8 : 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func openTarget(for source: SourceRef) -> URL? {
        if let callId = source.callId {
            let url = Log.root.appendingPathComponent(callId).appendingPathComponent("transcript.txt")
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if let path = source.path, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}

// MARK: - App icon

enum AppIcon {
    static func make() -> NSImage {
        NSImage(size: NSSize(width: 512, height: 512), flipped: false) { rect in
            let tile = NSBezierPath(roundedRect: rect.insetBy(dx: 40, dy: 40), xRadius: 112, yRadius: 112)
            NSGradient(
                starting: NSColor(calibratedRed: 0.30, green: 0.42, blue: 0.99, alpha: 1),
                ending: NSColor(calibratedRed: 0.55, green: 0.28, blue: 0.95, alpha: 1)
            )?.draw(in: tile, angle: -60)
            let config = NSImage.SymbolConfiguration(pointSize: 230, weight: .semibold)
                .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
            if let symbol = NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let size = symbol.size
                symbol.draw(in: NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2, width: size.width, height: size.height))
            }
            return true
        }
    }
}
