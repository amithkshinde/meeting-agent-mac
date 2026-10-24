import AVFoundation
import CoreGraphics
import ScreenCaptureKit

enum RecorderError: LocalizedError {
    case screenPermission
    case microphonePermission
    case noDisplay

    var errorDescription: String? {
        switch self {
        case .screenPermission:
            return "Screen Recording permission is off. Allow Meeting Agent in System Settings > Privacy & Security > Screen Recording, then restart the app."
        case .microphonePermission:
            return "Microphone permission is off. Allow Meeting Agent in System Settings > Privacy & Security > Microphone."
        case .noDisplay:
            return "No display found to record."
        }
    }
}

/// Writes one audio track to an AAC file. Buffers arrive on a ScreenCaptureKit queue, so all file
/// work is funnelled through a private serial queue.
final class AudioTrackWriter {
    private let url: URL
    private let name: String
    private let queue: DispatchQueue
    private var file: AVAudioFile?
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

    init(url: URL, name: String) {
        self.url = url
        self.name = name
        self.queue = DispatchQueue(label: "meetingagent.track.\(name)")
    }

    func append(_ sampleBuffer: CMSampleBuffer) {
        queue.async { [self] in
            guard sampleBuffer.isValid, CMSampleBufferGetNumSamples(sampleBuffer) > 0,
                  let buffer = Self.pcmBuffer(from: sampleBuffer) else { return }
            onBuffer?(buffer)
            do {
                if file == nil {
                    let format = buffer.format
                    let settings: [String: Any] = [
                        AVFormatIDKey: kAudioFormatMPEG4AAC,
                        AVSampleRateKey: format.sampleRate,
                        AVNumberOfChannelsKey: format.channelCount,
                        AVEncoderBitRateKey: 96_000,
                    ]
                    file = try AVAudioFile(
                        forWriting: url,
                        settings: settings,
                        commonFormat: format.commonFormat,
                        interleaved: format.isInterleaved
                    )
                }
                try file?.write(from: buffer)
            } catch {
                Log.write("\(name) track write failed: \(error.localizedDescription)")
            }
        }
    }

    func close() {
        queue.sync { file = nil }
    }

    private static func pcmBuffer(from sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description) else { return nil }
        var streamDescription = asbd.pointee
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else { return nil }
        let frames = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { return nil }
        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}

/// Records the screen to MP4 and the call audio (other people) and your microphone to two separate
/// files, so "you versus them" labels come for free later.
final class CallRecorder: NSObject, SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate {
    private struct Meta: Codable {
        let app: String
        let windowTitle: String
        let started: Date
        var ended: Date?
    }

    /// Called if capture stops without the user asking, for example when the display sleeps.
    var onUnexpectedStop: ((String) -> Void)?
    var transcriber: LiveTranscriber?
    /// Notes who is speaking and saves screenshots when the shared screen changes.
    let watcher = CallWatcher()
    /// The moment capture began. Transcript stamps, bookmarks and screenshots are all measured from here.
    private(set) var clockStart = Date()

    /// Seconds since this recording began.
    var elapsed: Double { Date().timeIntervalSince(clockStart) }

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var systemTrack: AudioTrackWriter?
    private var micTrack: AudioTrackWriter?
    private var meta: Meta?
    private(set) var folder: URL?
    private var stopping = false

    private let sampleQueue = DispatchQueue(label: "meetingagent.samples")

    var isRecording: Bool { stream != nil }

    func start(call: DetectedCall) async throws {
        guard stream == nil else { return }

        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw RecorderError.screenPermission
        }
        guard await AVCaptureDevice.requestAccess(for: .audio) else {
            throw RecorderError.microphonePermission
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        let folder = try Self.makeFolder(for: call)
        self.folder = folder
        // This file exists only while a recording is open. If the app is killed, it is how the next launch knows.
        try? "recording".write(to: folder.appendingPathComponent("recording.lock"), atomically: true, encoding: .utf8)

        // Cap the picture at 1080 lines and a low frame rate to keep CPU use down.
        let scale = min(1.0, 1080.0 / Double(display.height))
        let configuration = SCStreamConfiguration()
        configuration.width = Self.even(Double(display.width) * scale)
        configuration.height = Self.even(Double(display.height) * scale)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        configuration.showsCursor = true
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.captureMicrophone = true

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)

        let system = AudioTrackWriter(url: folder.appendingPathComponent("system.m4a"), name: "system")
        let mic = AudioTrackWriter(url: folder.appendingPathComponent("mic.m4a"), name: "mic")
        systemTrack = system
        micTrack = mic
        system.onBuffer = { [weak self] buffer in self?.transcriber?.appendSystem(buffer) }
        mic.onBuffer = { [weak self] buffer in self?.transcriber?.appendMic(buffer) }

        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = folder.appendingPathComponent("screen.mp4")
        recordingConfiguration.outputFileType = .mp4
        recordingConfiguration.videoCodecType = .hevc
        let output = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        try stream.addRecordingOutput(output)
        recordingOutput = output

        meta = Meta(app: call.app, windowTitle: call.windowTitle, started: Date(), ended: nil)
        clockStart = Date()
        try await stream.startCapture()
        transcriber?.begin(folder: folder, start: clockStart)
        watcher.begin(folder: folder, start: clockStart)
        self.stream = stream
        Log.write("recording started: \(folder.path)")
    }

    /// Stops capture, closes the files and returns the folder they were saved in.
    @discardableResult
    func stop() async -> URL? {
        guard let stream, !stopping else { return nil }
        stopping = true
        self.stream = nil

        do {
            try await stream.stopCapture()
        } catch {
            Log.write("stopCapture reported: \(error.localizedDescription)")
        }
        // Give the MP4 writer a moment to finish the file.
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        finalizeFiles()
        stopping = false
        return folder
    }

    private func finalizeFiles() {
        watcher.end()
        transcriber?.end()
        systemTrack?.close()
        micTrack?.close()
        systemTrack = nil
        micTrack = nil
        recordingOutput = nil

        if var finished = meta, let folder {
            finished.ended = Date()
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(finished) {
                try? data.write(to: folder.appendingPathComponent("meta.json"))
            }
        }
        meta = nil
        if let folder { try? FileManager.default.removeItem(at: folder.appendingPathComponent("recording.lock")) }
        Log.write("recording files closed: \(folder?.path ?? "?")")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .audio:
            systemTrack?.append(sampleBuffer)
        case .microphone:
            micTrack?.append(sampleBuffer)
        case .screen:
            // The picture itself is written by the recording output; this is only for looking at it.
            watcher.offer(sampleBuffer)
        default:
            break
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        // macOS can send this while we are stopping on purpose. Only treat it as a problem if the
        // stream was still meant to be running.
        guard !stopping, self.stream != nil else {
            Log.write("ignored stream-stop notice during normal stop: \(error.localizedDescription)")
            return
        }
        Log.write("stream stopped unexpectedly: \(error.localizedDescription)")
        self.stream = nil
        finalizeFiles()
        onUnexpectedStop?(error.localizedDescription)
    }

    // MARK: - SCRecordingOutputDelegate

    func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Log.write("screen recording failed: \(error.localizedDescription)")
    }

    func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Log.write("screen file finalised")
    }

    // MARK: - Helpers

    private static func even(_ value: Double) -> Int {
        let rounded = Int(value.rounded())
        return rounded - (rounded % 2)
    }

    private static func makeFolder(for call: DetectedCall) throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HHmm"
        let safeName = call.app
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "/", with: "-")
        let folder = Log.root.appendingPathComponent(
            "\(formatter.string(from: Date()))_\(safeName)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
}
