import AVFoundation
import Speech

/// What the live transcriber needs from a speech engine for one audio track.
protocol TrackEngine: AnyObject {
    var speaker: String { get }
    var onPartial: ((String) -> Void)? { get set }
    var onCommit: ((String) -> Void)? { get set }
    func begin()
    func append(_ buffer: AVAudioPCMBuffer)
    func end()
}

extension TrackTranscriber: TrackEngine {}

#if compiler(>=6.2)
/// Uses Apple's newer SpeechAnalyzer (macOS 26), built for long recordings such as meetings.
/// It is far more accurate and faster than the older recogniser, and runs on this Mac.
/// If it can't start for any reason, it hands the track to the older engine.
@available(macOS 26.0, *)
final class ModernTrackTranscriber: TrackEngine {
    let speaker: String
    var onPartial: ((String) -> Void)?
    var onCommit: ((String) -> Void)?

    private let queue: DispatchQueue
    private var analyzer: SpeechAnalyzer?
    private var inputBuilder: AsyncStream<AnalyzerInput>.Continuation?
    private var targetFormat: AVAudioFormat?
    private var converter: AVAudioConverter?
    private var converterInput: AVAudioFormat?
    private var ready = false
    private var active = false
    private var waiting: [AVAudioPCMBuffer] = []
    private var fallback: TrackTranscriber?
    private var bufferCount = 0

    init(speaker: String) {
        self.speaker = speaker
        self.queue = DispatchQueue(label: "meetingagent.modern.\(speaker)")
    }

    func begin() {
        queue.async { [self] in
            active = true
            ready = false
            waiting = []
            fallback = nil
            bufferCount = 0
        }
        Task { await setUp() }
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        queue.async { [self] in
            guard active else { return }
            if let fallback { fallback.append(buffer); return }
            bufferCount += 1
            if bufferCount == 1 || bufferCount % 2000 == 0 {
                Log.write("speech (\(speaker)): \(bufferCount) audio buffers received (new engine)")
            }
            if !ready {
                // The language model may still be loading. Keep a few seconds of audio meanwhile.
                waiting.append(buffer)
                if waiting.count > 1500 { waiting.removeFirst() }
                return
            }
            feed(buffer)
        }
    }

    func end() {
        let (builder, analyzer, older): (AsyncStream<AnalyzerInput>.Continuation?, SpeechAnalyzer?, TrackTranscriber?) = queue.sync {
            active = false
            ready = false
            let taken = (self.inputBuilder, self.analyzer, self.fallback)
            self.inputBuilder = nil
            self.analyzer = nil
            self.fallback = nil
            return taken
        }
        older?.end()
        builder?.finish()
        if let analyzer {
            Task { try? await analyzer.finalizeAndFinishThroughEndOfInput() }
        }
    }

    // MARK: - Setup

    private func chosenLocale() async -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        func isSupported(_ id: String) -> Locale? {
            let wanted = Locale(identifier: id).identifier(.bcp47)
            return supported.first { $0.identifier(.bcp47) == wanted }
        }
        var saved = UserDefaults.standard.string(forKey: "speechLocale") ?? "auto"
        if saved == "hinglish" { saved = "hi-IN" }   // the Hindi engine copes best with Hindi and English mixed
        if saved != "auto" {
            if let match = isSupported(saved) { return match }
            Log.write("speech (\(speaker)): Apple does not offer \(saved) on this Mac, using English instead")
        }
        for id in ["en-IN", "en-US", "en-GB"] {
            if let match = isSupported(id) { return match }
        }
        return Locale(identifier: "en-US")
    }

    private func setUp() async {
        do {
            let locale = await chosenLocale()
            let transcriber = SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )

            // First use downloads the language model once. After that it is stored on the Mac.
            let installed = await SpeechTranscriber.installedLocales
            if !installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
                Log.write("speech (\(speaker)): downloading the \(locale.identifier) speech model, this can take a minute")
                if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                    try await request.downloadAndInstall()
                }
            }

            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
            let (stream, builder) = AsyncStream.makeStream(of: AnalyzerInput.self)

            Task { [weak self] in
                do {
                    for try await result in transcriber.results {
                        self?.handle(result)
                    }
                } catch {
                    Log.write("speech (\(self?.speaker ?? "?")): results stopped: \(error.localizedDescription)")
                }
            }

            try await analyzer.start(inputSequence: stream)
            Log.write("speech (\(speaker)): using SpeechAnalyzer, locale \(locale.identifier), format \(format.map { "\($0.sampleRate) Hz" } ?? "default")")

            queue.async { [self] in
                guard active else { builder.finish(); return }
                self.analyzer = analyzer
                self.inputBuilder = builder
                self.targetFormat = format
                self.ready = true
                let backlog = waiting
                waiting = []
                for buffer in backlog { feed(buffer) }
            }
        } catch {
            Log.write("speech (\(speaker)): new engine unavailable (\(error.localizedDescription)); using the older engine")
            queue.async { [self] in
                guard active else { return }
                let older = TrackTranscriber(speaker: speaker)
                older.onPartial = onPartial
                older.onCommit = onCommit
                older.begin()
                fallback = older
                let backlog = waiting
                waiting = []
                for buffer in backlog { older.append(buffer) }
            }
        }
    }

    // MARK: - Audio and results

    private func feed(_ buffer: AVAudioPCMBuffer) {
        guard let builder = inputBuilder, let converted = convert(buffer) else { return }
        builder.yield(AnalyzerInput(buffer: converted))
    }

    private func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let target = targetFormat else { return buffer }
        if buffer.format == target { return buffer }
        if converter == nil || converterInput != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
            converterInput = buffer.format
        }
        guard let converter else { return nil }
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: out, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if status == .error || out.frameLength == 0 { return nil }
        return out
    }

    private func handle(_ result: SpeechTranscriber.Result) {
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.isFinal {
            guard !text.isEmpty else { return }
            DispatchQueue.main.async {
                self.onCommit?(text)
                self.onPartial?("")
            }
        } else {
            DispatchQueue.main.async { self.onPartial?(text) }
        }
    }
}
#endif
