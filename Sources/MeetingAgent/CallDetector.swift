import AppKit
import CoreAudio
import CoreGraphics

struct DetectedCall: Equatable {
    let app: String
    let windowTitle: String
}

enum CallState: Equatable {
    case idle
    case active(DetectedCall)
}

/// Spots a call in progress, and notices when it is over.
///
/// A call counts as live only when both are true: a window looks like a call, and some other app is
/// using the microphone. The second part matters for ending: after you leave a Meet call the tab
/// title can stay the same, but the browser lets go of the microphone.
///
/// Known limits: a browser only exposes its active tab's title, and a call window that is minimised
/// or on another Space is not seen. If you stay muted for a long time and the app lets go of the
/// microphone, the recording can stop early; use "Record now" to start again.
final class CallDetector {
    var onChange: ((CallState) -> Void)?

    /// Set while recording. Used only when the per-app microphone check is unavailable.
    var isRecording = false

    private(set) var state: CallState = .idle
    private var timer: Timer?
    private var hits = 0
    private var misses = 0

    private let startAfterHits = 2    // about 3 s of agreement before announcing a call
    private let endAfterMisses = 14   // about 20 s without a live call before calling it over

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let micOn = Self.microphoneActive(isRecording: isRecording)
        let call = Self.findCallWindow(micOn: micOn)
        if let call, micOn {
            hits += 1
            misses = 0
            if hits >= startAfterHits, state == .idle {
                state = .active(call)
                Log.write("call detected: \(call.app) | window: \"\(call.windowTitle)\" | mic: \(micOn)")
                onChange?(state)
            }
        } else {
            misses += 1
            hits = 0
            if misses >= endAfterMisses, state != .idle {
                state = .idle
                Log.write("call ended (no live call for \(endAfterMisses) checks; mic: \(micOn), window: \(call != nil))")
                onChange?(state)
            }
        }
    }

    // MARK: - Signals

    /// Is anything other than this app using the microphone right now?
    static func microphoneActive(isRecording: Bool) -> Bool {
        if let other = otherProcessUsingInput() { return other }
        // The per-app check is unavailable. While recording we hold the microphone ourselves, so
        // the device-level check would never say "off"; assume on and rely on the window instead.
        return isRecording ? true : microphoneInUse()
    }

    /// True when any process other than this one is capturing audio input. Nil if macOS won't tell us.
    static func otherProcessUsingInput() -> Bool? {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &listAddress, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &listAddress, 0, nil, &size, &ids) == noErr else { return nil }

        let me = getpid()
        for id in ids {
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            guard AudioObjectGetPropertyData(id, &pidAddress, 0, nil, &pidSize, &pid) == noErr, pid != me else {
                continue
            }
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &inputAddress, 0, nil, &runningSize, &running) == noErr, running != 0 {
                return true
            }
        }
        return false
    }

    /// True when the default input device is being used by any process (including this one).
    static func microphoneInUse() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != 0 else { return false }

        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        address.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        let result = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &running)
        return result == noErr && running != 0
    }

    static func findCallWindow(micOn: Bool) -> DetectedCall? {
        for window in onScreenWindows() where window.layer == 0 {
            if let app = classify(owner: window.owner, title: window.title, micOn: micOn) {
                return DetectedCall(app: app, windowTitle: window.title)
            }
        }
        // Without Screen Recording permission macOS hides other apps' window titles. Fall back to
        // "the microphone is on and a call app or browser is in front".
        if micOn, !CGPreflightScreenCaptureAccess(),
           let front = NSWorkspace.shared.frontmostApplication?.localizedName {
            let o = front.lowercased()
            let known = browsers + ["zoom", "microsoft teams", "slack", "facetime", "webex"]
            if known.contains(where: { o.contains($0) }) {
                return DetectedCall(app: "\(front) call", windowTitle: "(window titles hidden: Screen Recording is off)")
            }
        }
        return nil
    }

    /// Every normal on-screen window as (owner, title). Used by detection and by the "Log visible
    /// windows" menu item, which helps tune the rules against real calls.
    static func onScreenWindows() -> [(owner: String, title: String, layer: Int)] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infos = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return infos.map { info in
            (
                owner: info[kCGWindowOwnerName as String] as? String ?? "",
                title: info[kCGWindowName as String] as? String ?? "",
                layer: info[kCGWindowLayer as String] as? Int ?? 0
            )
        }
    }

    // MARK: - Rules

    private static let browsers = [
        "google chrome", "safari", "arc", "microsoft edge", "brave browser",
        "firefox", "chromium", "vivaldi", "opera",
    ]

    /// Maps a window to a call app name, or nil when it does not look like a call.
    static func classify(owner: String, title: String, micOn: Bool) -> String? {
        let o = owner.lowercased()
        let t = title.lowercased()

        if o.contains("zoom"), t.contains("zoom meeting") || t.contains("zoom webinar") {
            return "Zoom"
        }

        if browsers.contains(where: { o.contains($0) }) {
            if t.hasPrefix("meet - ") || t.hasPrefix("meet – ") || t.contains("meet.google.com") {
                return "Google Meet"
            }
            if micOn, t.contains("| microsoft teams") {
                return "Microsoft Teams (web)"
            }
        }

        if micOn {
            if o.contains("microsoft teams") { return "Microsoft Teams" }
            if o == "slack", t.contains("huddle") { return "Slack huddle" }
            if o == "facetime" { return "FaceTime" }
            if o.contains("webex") { return "Webex" }
        }
        return nil
    }
}
