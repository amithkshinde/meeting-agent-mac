import AVFoundation
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Looks at the screen once a second while recording and does two things:
///  1. Notes who is speaking, by finding the outline the call app draws around the active speaker
///     and reading the name on that tile. Saved to speakers.jsonl.
///  2. Saves a screenshot whenever the shared screen changes a lot (a new Figma frame, the next
///     slide), so feedback can be grouped under each screen. Saved to screens/ and screens.json.
/// Frames are copied and processed on a background queue, so recording is never held up.
final class CallWatcher {
    private struct Frame {
        let data: Data
        let width: Int
        let height: Int
        let bytesPerRow: Int
    }

    var onSpeaker: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "meetingagent.watcher", qos: .utility)
    /// Guards `running` and `busy`, which the video callback checks. It must never wait on `queue`,
    /// because `queue` can be busy reading a name for a moment, and the video callback also carries the audio.
    private let state = NSLock()
    private var folder: URL?
    private var start = Date()
    private var running = false
    private var busy = false
    private var lastSample = Date.distantPast
    private var detector = ScreenChangeDetector()
    private var shots: [ScreenShot] = []
    private var nameCache: [String: (name: String, at: Double)] = [:]
    private var lastSpeaker: String?
    private var loggedFirstRing = false

    private var wantSpeakers: Bool { UserDefaults.standard.object(forKey: "watchSpeakers") as? Bool ?? true }
    private var wantScreens: Bool { UserDefaults.standard.object(forKey: "watchScreens") as? Bool ?? true }

    func begin(folder: URL, start: Date) {
        setRunning(true)
        queue.sync {
            self.folder = folder
            self.start = start
            self.lastSample = .distantPast
            self.detector = ScreenChangeDetector()
            self.shots = []
            self.nameCache = [:]
            self.lastSpeaker = nil
            self.loggedFirstRing = false
        }
    }

    private func setRunning(_ value: Bool) {
        state.lock()
        running = value
        busy = false
        state.unlock()
    }

    func end() {
        setRunning(false)
        queue.sync { lastSpeaker = nil }
        DispatchQueue.main.async { self.onSpeaker?(nil) }
    }

    /// Called for every video frame. Cheap unless a second has passed since the last one used.
    func offer(_ sampleBuffer: CMSampleBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastSample) >= 1.0, wantSpeakers || wantScreens else { return }
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA else { return }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixels) else { return }
        let width = CVPixelBufferGetWidth(pixels)
        let height = CVPixelBufferGetHeight(pixels)
        let stride = CVPixelBufferGetBytesPerRow(pixels)

        state.lock()
        let proceed = running && !busy
        if proceed { busy = true }
        state.unlock()
        guard proceed else { return }
        lastSample = now

        let frame = Frame(data: Data(bytes: base, count: stride * height), width: width, height: height, bytesPerRow: stride)
        let seconds = now.timeIntervalSince(start)
        let speakers = wantSpeakers
        let screens = wantScreens
        queue.async { [self] in
            analyse(frame, at: seconds, speakers: speakers, screens: screens)
            state.lock()
            busy = false
            state.unlock()
        }
    }


    // MARK: - Recordings made earlier

    /// Looks through a saved video, one frame a second, and fills in speakers.jsonl and the screenshots,
    /// the same way the live watcher would have. Replaces anything found before.
    func analyseVideo(at videoURL: URL, folder: URL, progress: @escaping (Double) -> Void) async -> (screens: Int, speakerSamples: Int) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: SpeakerLog.url(folder))
        try? fileManager.removeItem(at: ScreenIndex.url(folder))
        try? fileManager.removeItem(at: folder.appendingPathComponent("screens", isDirectory: true))
        try? fileManager.removeItem(at: ScreenFeedback.url(folder))

        let asset = AVURLAsset(url: videoURL)
        guard let duration = try? await asset.load(.duration).seconds, duration.isFinite, duration > 1 else { return (0, 0) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        setRunning(true)
        queue.sync {
            self.folder = folder
            self.start = Date()
            self.detector = ScreenChangeDetector()
            self.shots = []
            self.nameCache = [:]
            self.lastSpeaker = nil
            self.loggedFirstRing = false
        }

        var t = 0.0
        while t < duration {
            if Task.isCancelled { break }
            if let result = try? await generator.image(at: CMTime(seconds: t, preferredTimescale: 600)),
               let frame = Self.frame(from: result.image) {
                queue.sync { analyse(frame, at: t, speakers: true, screens: true) }
            }
            progress(min(1, t / duration))
            t += 1
        }
        setRunning(false)
        queue.sync { lastSpeaker = nil }
        progress(1)
        return (shots.count, SpeakerLog.load(folder).count)
    }

    private static func frame(from image: CGImage) -> Frame? {
        let width = image.width
        let height = image.height
        let stride = width * 4
        var data = Data(count: stride * height)
        let drawn = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: stride,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? Frame(data: data, width: width, height: height, bytesPerRow: stride) : nil
    }

    // MARK: - Analysis (runs on the watcher queue)

    private func analyse(_ frame: Frame, at t: Double, speakers wantSpeakers: Bool, screens wantScreens: Bool) {
        guard running, let folder else { return }
        let luma = Self.luma(of: frame)

        if wantScreens {
            let digest = ScreenChangeDetector.digest(luma: luma, width: frame.width, height: frame.height)
            if detector.feed(digest: digest, at: t), let image = Self.image(of: frame) {
                saveShot(image, at: t, in: folder)
            }
        }

        if wantSpeakers {
            let boxes = SpeakerRing.find(luma: luma, width: frame.width, height: frame.height)
            var name: String?
            if !boxes.isEmpty, let image = Self.image(of: frame) {
                for box in boxes.prefix(2) {
                    if let found = speakerName(in: box, image: image, at: t) { name = found; break }
                }
            }
            if let name {
                SpeakerLog.append(SpeakerSample(t: (t * 10).rounded() / 10, name: name), to: folder)
                if !loggedFirstRing {
                    loggedFirstRing = true
                    Log.write("speaker detection: first active speaker seen, \(name)")
                }
            }
            if name != lastSpeaker {
                lastSpeaker = name
                DispatchQueue.main.async { self.onSpeaker?(name) }
            }
        }
    }

    private func saveShot(_ image: CGImage, at t: Double, in folder: URL) {
        let number = shots.count + 1
        let name = String(format: "screens/%03d.jpg", number)
        let directory = folder.appendingPathComponent("screens", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return }
        shots.append(ScreenShot(id: number, t: (t * 10).rounded() / 10, file: name))
        ScreenIndex.save(shots, to: folder)
        Log.write("screen change saved: \(name) at \(Transcript.clock(t))")
    }

    /// Reads the name on the tile outlined as the active speaker. Names don't move often, so recent readings are reused.
    private func speakerName(in box: PixelBox, image: CGImage, at t: Double) -> String? {
        let key = "\(box.x / 30),\(box.y / 30),\(box.w / 40),\(box.h / 40)"
        if let cached = nameCache[key], t - cached.at < 10 { return cached.name }

        // The name is in the lower part of the tile.
        let lowerHeight = max(24, Int(Double(box.h) * 0.45))
        let rect = CGRect(x: box.x, y: box.y + box.h - lowerHeight, width: box.w, height: lowerHeight)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard !rect.isEmpty, let crop = image.cropping(to: rect) else { return nil }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: crop, options: [:])
        do { try handler.perform([request]) } catch {
            return nil
        }
        let lines = (request.results ?? []).compactMap { observation -> (text: String, bottom: Double, left: Double)? in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            // Vision's origin is the bottom left of the crop, which is 45% of the tile's height.
            return (text, Double(observation.boundingBox.minY) * 0.45, Double(observation.boundingBox.minX))
        }
        guard let name = TileName.pick(from: lines) else { return nil }
        nameCache[key] = (name, t)
        return name
    }

    // MARK: - Pixels

    /// A grey-scale copy of the frame.
    private static func luma(of frame: Frame) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: frame.width * frame.height)
        frame.data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
            out.withUnsafeMutableBufferPointer { target in
                for y in 0..<frame.height {
                    let row = base + y * frame.bytesPerRow
                    let outRow = y * frame.width
                    for x in 0..<frame.width {
                        let p = row + x * 4   // B, G, R, A
                        target[outRow + x] = UInt8((Int(p[2]) * 77 + Int(p[1]) * 150 + Int(p[0]) * 29) >> 8)
                    }
                }
            }
        }
        return out
    }

    private static func image(of frame: Frame) -> CGImage? {
        guard let provider = CGDataProvider(data: frame.data as CFData) else { return nil }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(
            width: frame.width,
            height: frame.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: frame.bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: info,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
