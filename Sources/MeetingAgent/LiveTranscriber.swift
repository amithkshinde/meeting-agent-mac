import AVFoundation
import Speech

struct TranscriptLine: Identifiable, Equatable {
    let id = UUID()
    let speaker: String   // "You" or "Them"
    let text: String
    let time: Date
}

/// One streaming speech recogniser for one audio track. It uses Apple's on-device recogniser where
/// the language supports it, so audio stays on the Mac. A phrase is committed after about 2 seconds
/// of no new words, and the recogniser is restarted every 50 seconds (Apple limits request length).
final class TrackTranscriber {
    let speaker: String
    var onPartial: ((String) -> Void)?
    var onCommit: ((String) -> Void)?

    /// One recogniser run. A run covers one stretch of speech, from the first loud sound to about
    /// 1.5 seconds of silence, and is then allowed to finish before its text is committed.
    private final class Session {
        let request = SFSpeechAudioBufferRecognitionRequest()
        var task: SFSpeechRecognitionTask?
        var pending = ""
        var committed = false
        let started = Date()
    }

    private var recognizer: SFSpeechRecognizer?
    private let queue: DispatchQueue
    private var current: Session?
    private var active = false
    private var unavailable = false
    private var lastLoud = Date.distantPast
    private var preroll: [AVAudioPCMBuffer] = []
    private var bufferCount = 0
    private var retryAfter = Date.distantPast
    private var lastErrorLog = Date.distantPast
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?
    private let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    init(speaker: String) {
        self.speaker = speaker
        self.queue = DispatchQueue(label: "meetingagent.stt.\(speaker)")
        self.recognizer = nil
    }

    /// The language chosen in the menu, or the best English that can run on this Mac.
    static func makeRecognizer(speaker: String) -> SFSpeechRecognizer? {
        var chosen = UserDefaults.standard.string(forKey: "speechLocale") ?? "auto"
        if chosen == "hinglish" { chosen = "hi-IN" }   // the Hindi engine copes best with Hindi and English mixed
        var candidates: [SFSpeechRecognizer] = []
        if chosen != "auto", let picked = SFSpeechRecognizer(locale: Locale(identifier: chosen)) {
            candidates = [picked]
        } else {
            candidates = ["en-IN", "en-US", "en-GB"].compactMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }
        }
        let recognizer = candidates.first(where: { $0.supportsOnDeviceRecognition }) ?? candidates.first ?? SFSpeechRecognizer()
        Log.write("speech (\(speaker)): locale \(recognizer?.locale.identifier ?? "none"), available \(recognizer?.isAvailable ?? false), on-device \(recognizer?.supportsOnDeviceRecognition ?? false), auth \(SFSpeechRecognizer.authorizationStatus().rawValue)")
        return recognizer
    }

    /// Languages offered in the menu: the ones Apple's recogniser supports on this Mac.
    static func supportedLanguages() -> [(id: String, name: String)] {
        // These three are always listed. If Apple can't do one on this Mac, the log says so.
        let always = ["en-IN", "hi-IN", "kn-IN"]
        let others = ["en-US", "en-GB", "mr-IN", "ta-IN", "te-IN", "bn-IN", "gu-IN", "ml-IN",
                      "ur-IN", "es-ES", "fr-FR", "de-DE", "ja-JP", "zh-CN"]
        let supported = Set(SFSpeechRecognizer.supportedLocales().map { $0.identifier.replacingOccurrences(of: "_", with: "-") })
        let ids = always + others.filter { supported.contains($0) }
        return ids.map { ($0, Locale(identifier: "en").localizedString(forIdentifier: $0) ?? $0) }
    }

    func begin() {
        queue.async { [self] in
            recognizer = Self.makeRecognizer(speaker: speaker)
            active = true
            unavailable = false
            current = nil
            preroll = []
            bufferCount = 0
        }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard active, !unavailable, let pcm = convert(buffer) else { return }
            bufferCount += 1
            if bufferCount == 1 || bufferCount % 500 == 0 {
                Log.write("speech (\(speaker)): \(bufferCount) audio buffers received, format \(buffer.format.sampleRate) Hz x \(buffer.format.channelCount)")
            }
            let now = Date()
            let loud = Self.level(of: pcm) > 0.003
            if loud { lastLoud = now }

            if let session = current {
                session.request.append(pcm)
                if now.timeIntervalSince(lastLoud) > 1.5 || now.timeIntervalSince(session.started) > 50 {
                    finish(session)
                }
            } else {
                // Keep a little audio from just before speech starts so first words aren't clipped.
                preroll.append(pcm)
                if preroll.count > 6 { preroll.removeFirst() }
                if loud, now >= retryAfter {
                    startSession()
                    for old in preroll { current?.request.append(old) }
                    preroll = []
                }
            }
        }
    }

    func end() {
        queue.sync { [self] in
            active = false
            if let session = current { commit(session) }
            current = nil
        }
    }

    // MARK: - Sessions

    private func startSession() {
        guard let recognizer, recognizer.isAvailable else {
            Log.write("speech recogniser unavailable for \(speaker)")
            unavailable = true
            return
        }
        let session = Session()
        session.request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            session.request.requiresOnDeviceRecognition = true
        }
        current = session
        session.task = recognizer.recognitionTask(with: session.request) { [weak self] result, error in
            guard let self else { return }
            self.queue.async {
                if let result {
                    if session.pending.isEmpty { Log.write("speech (\(self.speaker)): first words heard") }
                    session.pending = result.bestTranscription.formattedString
                    if self.current === session {
                        let text = session.pending
                        DispatchQueue.main.async { self.onPartial?(text) }
                    }
                    if result.isFinal { self.commit(session) }
                }
                if let error {
                    if Date().timeIntervalSince(self.lastErrorLog) > 30 {
                        self.lastErrorLog = Date()
                        Log.write("speech (\(self.speaker)): \(error.localizedDescription)")
                    }
                    if session.pending.isEmpty { self.retryAfter = Date().addingTimeInterval(1.0) }
                    if self.current === session { self.current = nil }
                    self.commit(session)
                }
            }
        }
    }

    /// Tell the recogniser the speech is over so it can finish the last words, then commit.
    private func finish(_ session: Session) {
        if current === session { current = nil }
        session.request.endAudio()
        // Safety net in case the final result never arrives.
        queue.asyncAfter(deadline: .now() + 4) { [self] in commit(session) }
    }

    private func commit(_ session: Session) {
        guard !session.committed else { return }
        session.committed = true
        let text = session.pending.trimmingCharacters(in: .whitespacesAndNewlines)
        let stillSpeaking = current != nil
        guard !text.isEmpty else { return }
        DispatchQueue.main.async {
            self.onCommit?(text)
            if !stillSpeaking { self.onPartial?("") }
        }
    }

    // MARK: - Audio helpers

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[i] * data[i] }
        return (sum / Float(buffer.frameLength)).squareRoot()
    }

    /// Speech recognition works best with 16 kHz mono, so convert whatever the call audio is.
    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        if converter == nil || converterInputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: speechFormat)
            converterInputFormat = buffer.format
        }
        guard let converter else { return nil }
        let ratio = speechFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: speechFormat, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error || out.frameLength == 0 {
            Log.write("speech (\(speaker)): audio conversion failed \(error?.localizedDescription ?? "")")
            return nil
        }
        return out
    }
}

/// Transcribes you and the other people separately, and writes transcript.txt next to the recording.
final class LiveTranscriber {
    var onLine: ((TranscriptLine) -> Void)?
    var onPartial: ((String, String) -> Void)?

    private let mic: TrackEngine = LiveTranscriber.makeEngine(speaker: "You")
    private let system: TrackEngine = LiveTranscriber.makeEngine(speaker: "Them")

    /// Uses Apple's newer meeting-grade engine when this Mac and the build tools support it.
    private static func makeEngine(speaker: String) -> TrackEngine {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            return ModernTrackTranscriber(speaker: speaker)
        }
        #endif
        Log.write("speech (\(speaker)): using the older speech engine")
        return TrackTranscriber(speaker: speaker)
    }
    private var fileURL: URL?
    private var started = Date()
    private let fileQueue = DispatchQueue(label: "meetingagent.transcript.file")

    init() {
        for track in [mic, system] {
            track.onPartial = { [weak self] text in self?.onPartial?(track.speaker, text) }
            track.onCommit = { [weak self] text in self?.commit(speaker: track.speaker, text: text) }
        }
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func begin(folder: URL, start: Date = Date()) {
        started = start
        let url = folder.appendingPathComponent("transcript.txt")
        fileURL = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        mic.begin()
        system.begin()
    }

    func appendMic(_ buffer: AVAudioPCMBuffer) { mic.append(buffer) }
    func appendSystem(_ buffer: AVAudioPCMBuffer) { system.append(buffer) }

    func end() {
        mic.end()
        system.end()
    }

    private func commit(speaker: String, text: String) {
        let line = TranscriptLine(speaker: speaker, text: text, time: Date())
        onLine?(line)

        let elapsed = max(0, Int(line.time.timeIntervalSince(started)))
        let entry = String(format: "[%02d:%02d] ", elapsed / 60, elapsed % 60) + "\(speaker): \(text)\n"
        fileQueue.async { [fileURL] in
            guard let fileURL, let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            try? handle.close()
        }
    }
}
