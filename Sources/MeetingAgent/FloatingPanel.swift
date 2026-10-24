import AppKit

/// A small always-on-top window that never takes focus, so it won't interrupt typing in the call.
/// `sharingType = .none` keeps it out of screen shares and out of our own recording.
final class FloatingPanel: NSPanel {
    init(content: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 90),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        sharingType = .none
        contentView = content
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// A floating panel isn't part of the main menu's responder flow, so copy, paste and friends
    /// would do nothing in its text fields. Route the usual shortcuts to whatever is being edited.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           let key = event.charactersIgnoringModifiers?.lowercased() {
            var action: Selector?
            switch key {
            case "v": action = #selector(NSText.paste(_:))
            case "c": action = #selector(NSText.copy(_:))
            case "x": action = #selector(NSText.cut(_:))
            case "a": action = #selector(NSText.selectAll(_:))
            case "z": action = Selector(("undo:"))
            default: break
            }
            if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Places the panel at the top right of the main screen.
    func moveToTopRight() {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let size = frame.size
        setFrameOrigin(NSPoint(x: area.maxX - size.width - 16, y: area.maxY - size.height - 16))
    }

    /// Resizes to the content while keeping the top edge where it is.
    func fitToContent() {
        guard let view = contentView else { return }
        let target = view.fittingSize
        guard target.width > 0, target.height > 0 else { return }
        var next = frame
        next.origin.y += next.height - target.height
        next.size = target
        setFrame(next, display: true)
    }
}
