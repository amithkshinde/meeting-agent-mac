import AppKit
import Carbon.HIToolbox

/// System-wide keyboard shortcuts that work even while another app (like the call) is in front.
/// These need no extra permission.
enum HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var refs: [EventHotKeyRef?] = []
    private static var installed = false

    /// Control + Option, the modifier pair used by every shortcut here.
    static let controlOption = UInt32(controlKey | optionKey)

    static func register(id: UInt32, keyCode: UInt32, modifiers: UInt32 = HotKey.controlOption, action: @escaping () -> Void) {
        installHandlerOnce()
        handlers[id] = action
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4D414754), id: id)   // "MAGT"
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr {
            refs.append(ref)
        } else {
            Log.write("shortcut \(id) could not be registered (status \(status)); another app may be using it")
        }
    }

    private static func installHandlerOnce() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )
            if status == noErr { HotKey.handlers[hotKeyID.id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
