import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Decides which AI to use for a piece of work: the saved cloud key, or the model built into this Mac.
enum AIAccess {
    /// Stands in for a key when the work should stay on this Mac.
    static let localKey = "local:on-device"

    /// True when the person chose to keep all AI work on this Mac.
    static var localEverywhere: Bool { UserDefaults.standard.bool(forKey: "aiLocalOnly") }

    /// True when the Mac's built-in model (Apple Intelligence) can be used right now.
    static var localAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .available = SystemLanguageModel.default.availability { return true }
        }
        #endif
        return false
    }

    /// Why the on-device model can't be used, in plain words.
    static var localProblem: String {
        #if arch(x86_64)
        return "The on-device AI needs a Mac with an Apple chip (M1 or newer). Choose Google Gemini or Claude instead."
        #endif
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            if case .unavailable = SystemLanguageModel.default.availability {
                return "Apple Intelligence isn't ready on this Mac. Turn it on in System Settings > Apple Intelligence & Siri, and wait for it to finish downloading."
            }
            return ""
        }
        #endif
        return "The on-device AI needs macOS 26 or later."
    }

    /// The key to use for work on this project (empty name means no project). nil means no AI is available.
    static func key(project: String = "", projects: ProjectStore? = nil) -> String? {
        let wantsLocal = localEverywhere || (!project.isEmpty && (projects?.isOnDeviceOnly(project) ?? false))
        if wantsLocal { return localAvailable ? localKey : nil }
        return Keychain.read()
    }

    /// True when the AI is ready for general use.
    static var isReady: Bool {
        localEverywhere ? localAvailable : Keychain.read() != nil
    }

    // MARK: - On-device completion

    static func completeLocal(
        system: String,
        history: [(question: String, answer: String)],
        prompt: String
    ) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            guard localAvailable else { throw ChatError.message(localProblem) }
            var budget = 9000
            var text = prompt
            if let last = history.last {
                text = "Earlier question: \(last.question)\nEarlier answer: \(String(last.answer.prefix(600)))\n\n" + prompt
            }
            for _ in 0..<3 {
                do {
                    let session = LanguageModelSession(instructions: system)
                    let response = try await session.respond(to: fit(text, to: budget))
                    return response.content
                } catch {
                    let description = String(describing: error).lowercased()
                    if description.contains("context") || description.contains("window") || description.contains("too long") {
                        budget /= 2
                        continue
                    }
                    throw ChatError.message("The on-device AI couldn't answer: \(error.localizedDescription)")
                }
            }
            throw ChatError.message("That was too much text for the on-device AI. Try a shorter question.")
        }
        #endif
        throw ChatError.message(localProblem)
    }

    /// Keeps the start and, more of, the end of a long text, since the end is usually what matters.
    private static func fit(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = limit / 4
        let tail = limit - head
        return String(text.prefix(head)) + "\n…\n" + String(text.suffix(tail))
    }
}
