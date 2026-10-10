#if !APPSTORE
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - LocalModelStatus
// Exposed outside the FoundationModels guard so SettingsView can reference it on macOS 15.
enum LocalModelStatus {
    case available
    case notMacOS26         // running on macOS < 26 or device not eligible
    case appleIntelligenceOff
    case languageUnsupported
}

// MARK: - VoiceBrain
//
// macOS 26 + Apple Intelligence: uses a LanguageModelSession per conversation.
// On macOS < 26 or when Apple Intelligence is off, every call returns nil immediately
// and the caller falls back to IntentParser + ConversationContext.
//
// Thread: @MainActor throughout.
@MainActor
final class VoiceBrain {
    static let shared = VoiceBrain()

    /// Current model availability status, updated lazily.
    private(set) var modelStatus: LocalModelStatus

    /// Opaque session holder — avoids @available on stored property.
    private var sessionBox: AnyObject? = nil

    private init() {
        modelStatus = VoiceBrain._checkStatus()
    }

    // MARK: - Conversation lifecycle

    func beginConversation() {
        sessionBox = VoiceBrain._makeSession()
    }

    func endConversation() {
        sessionBox = nil
    }

    // MARK: - Intent resolution

    /// Try to resolve `transcript` using the language model.
    /// Returns nil if the model is unavailable, or if the model cannot map to a VoiceIntent.
    func resolve(_ transcript: String, pills: [PillDefinition]) async -> VoiceIntent? {
        await VoiceBrain._resolve(transcript, pills: pills, sessionBox: sessionBox)
    }

    // MARK: - Static impl helpers

    static func _checkStatus() -> LocalModelStatus {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled:
                    return .appleIntelligenceOff
                case .deviceNotEligible:
                    return .notMacOS26
                default:
                    return .notMacOS26
                }
            @unknown default:
                return .notMacOS26
            }
        }
        #endif
        return .notMacOS26
    }

    static func _makeSession() -> AnyObject? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard SystemLanguageModel.default.availability == .available else { return nil }
            return LanguageModelSession(
                instructions: """
                Tu es Coucou, un assistant dans le notch du MacBook.
                Réponds toujours dans la langue de l'utilisateur.
                Réponds avec une phrase courte.
                """
            )
        }
        #endif
        return nil
    }

    static func _resolve(_ transcript: String,
                         pills: [PillDefinition],
                         sessionBox: AnyObject?) async -> VoiceIntent? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard SystemLanguageModel.default.availability == .available else { return nil }
            guard let session = sessionBox as? LanguageModelSession else { return nil }
            do {
                let prompt = "User said: \"\(transcript)\". Available pill names: \(pills.map(\.name).joined(separator: ", ")). Is this a command or a question? Respond in one sentence."
                _ = try await session.respond(to: prompt)
                // For now: VoiceBrain provides the fallback text answer (to be spoken),
                // but returns nil to VoiceIntent so execution falls through to .unknown.
                return nil
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}

#endif // !APPSTORE
