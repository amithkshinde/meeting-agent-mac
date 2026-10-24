import AppKit
import SwiftUI

/// The look of the app: one brand colour pair, one set of shapes, and a few reusable pieces.
enum Theme {
    /// Indigo to violet, taken from the app icon.
    static let accent = Color(red: 0.30, green: 0.37, blue: 0.98)
    static let accentEnd = Color(red: 0.55, green: 0.36, blue: 0.97)
    /// Used only for recording and for stopping.
    static let record = Color(red: 1.0, green: 0.27, blue: 0.23)

    static func brandFill(_ opacity: Double) -> LinearGradient {
        LinearGradient(colors: [accent.opacity(opacity), accentEnd.opacity(opacity)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static var brand: LinearGradient { brandFill(1) }

    /// "Good evening, Amith", using the name macOS has for the person.
    static var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        let part = hour < 12 ? "Good morning" : (hour < 17 ? "Good afternoon" : "Good evening")
        let first = NSFullUserName().split(separator: " ").first.map(String.init) ?? ""
        return first.isEmpty ? part : "\(part), \(first)"
    }

    static func elapsed(from start: Date, to now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(start)))
        if seconds >= 3600 {
            return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60)
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    /// A light tap on a trackpad, for starting and stopping a recording.
    static func tap() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}

// MARK: - Cards

extension View {
    /// A raised, softly outlined card.
    func card(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.05), radius: 6, x: 0, y: 2)
    }

    /// A small lift when the pointer is over it.
    func hoverLift() -> some View {
        modifier(HoverLift())
    }
}

private struct HoverLift: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? 1.015 : 1)
            .shadow(color: Color.black.opacity(hovering ? 0.10 : 0), radius: 10, x: 0, y: 4)
            .animation(.easeOut(duration: 0.15), value: hovering)
            .onHover { hovering = $0 }
    }
}

// MARK: - Buttons

private struct StyledButtonBody: View {
    enum Kind { case primary, destructive, soft, hero }

    let configuration: ButtonStyleConfiguration
    let kind: Kind
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: kind == .hero ? 11 : 9, style: .continuous)
    }

    private var fill: AnyShapeStyle {
        let level = configuration.isPressed ? 0.78 : (hovering ? 0.92 : 1.0)
        switch kind {
        case .primary: return AnyShapeStyle(Theme.brandFill(level))
        case .destructive: return AnyShapeStyle(Theme.record.opacity(level))
        case .hero: return AnyShapeStyle(Color.white.opacity(configuration.isPressed ? 0.82 : (hovering ? 0.95 : 1.0)))
        case .soft: return AnyShapeStyle(Color.primary.opacity(configuration.isPressed ? 0.16 : (hovering ? 0.12 : 0.07)))
        }
    }

    private var textColor: Color {
        switch kind {
        case .primary, .destructive: return Color.white
        case .hero: return Theme.accent
        case .soft: return Color.primary
        }
    }

    var body: some View {
        configuration.label
            .font(kind == .soft ? Font.callout : Font.callout.weight(.semibold))
            .foregroundColor(textColor)
            .padding(.horizontal, kind == .soft ? 12 : (kind == .hero ? 18 : 14))
            .padding(.vertical, kind == .soft ? 6 : (kind == .hero ? 10 : 7))
            .background(fill, in: shape)
            .overlay(shape.strokeBorder(Color.white.opacity(kind == .primary || kind == .destructive ? 0.18 : 0), lineWidth: 0.5))
            .shadow(color: (kind == .primary ? Theme.accent : Color.black).opacity(kind == .soft ? 0 : 0.22), radius: 3, x: 0, y: 1)
            .opacity(enabled ? 1 : 0.45)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.12), value: hovering)
            .onHover { hovering = $0 }
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var destructive = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButtonBody(configuration: configuration, kind: destructive ? .destructive : .primary)
    }
}

struct SoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledButtonBody(configuration: configuration, kind: .soft)
    }
}

/// A white button for use on the brand-coloured hero card.
struct HeroButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledButtonBody(configuration: configuration, kind: .hero)
    }
}

// MARK: - Pieces

/// A red dot that gently pulses while recording.
struct PulsingDot: View {
    var color: Color = Theme.record
    var size: CGFloat = 12
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.4))
                .frame(width: size, height: size)
                .scaleEffect(pulse ? 2.3 : 1)
                .opacity(pulse ? 0 : 0.8)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .frame(width: size * 2, height: size * 2)
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
        .accessibilityLabel("Recording")
    }
}

/// A rounded square holding a symbol, in the brand colours.
struct BrandTile: View {
    let symbol: String
    var size: CGFloat = 34

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous).fill(Theme.brand)
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundColor(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.accent.opacity(0.28), radius: 5, x: 0, y: 2)
        .accessibilityHidden(true)
    }
}

/// What a list shows when it has nothing in it yet.
struct EmptyState: View {
    let icon: String
    let title: String
    let message: String
    var button: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Theme.accent.opacity(0.10)).frame(width: 58, height: 58)
                Image(systemName: icon).font(.title2).foregroundStyle(Theme.brand)
            }
            Text(title).font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400)
            if let button, let action {
                Button(button, action: action).buttonStyle(PrimaryButtonStyle()).padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .card()
    }
}
