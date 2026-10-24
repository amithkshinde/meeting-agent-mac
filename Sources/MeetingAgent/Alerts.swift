import SwiftUI

/// Something the person should know about, such as a stopped transcript or a rejected key.
struct AppAlert: Identifiable, Equatable {
    var id: String                 // a key such as "key-rejected", so the same problem never shows twice
    var message: String
    var button: String? = nil
    var section: String? = nil     // where the button goes in the main window (nil means Home)
    var isInfo = false
}

struct AlertBanner: View {
    let alert: AppAlert
    var onOpen: (String?) -> Void
    var onDismiss: () -> Void

    private var tint: Color { alert.isInfo ? .blue : .orange }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: alert.isInfo ? "info.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: 4) {
                Text(alert.message)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                if let button = alert.button {
                    Button(button) { onOpen(alert.section) }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark").font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
