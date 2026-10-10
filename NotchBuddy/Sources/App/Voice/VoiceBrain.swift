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
}

// MARK: - BrainResult

struct BrainResult {
    let intents: [VoiceIntent]  // tool-derived intents (may be empty)
    let text: String            // natural-language reply to speak / display
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

    /// Opaque session container — avoids @available on stored property.
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
    /// Returns nil if the model is unavailable or if the model cannot map to any intent.
    func resolve(_ transcript: String, pills: [PillDefinition]) async -> BrainResult? {
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
            let collector = IntentCollector()
            let session = LanguageModelSession(
                tools: [PillTool(collector: collector),
                        MusicTool(collector: collector),
                        StatusTool(collector: collector)],
                instructions: """
                Tu es Coucou, un assistant dans le notch du MacBook.
                Réponds toujours dans la langue de l'utilisateur.
                Réponds avec une phrase courte et directe.
                Utilise les outils disponibles pour exécuter des commandes sur les pills et la musique.
                """
            )
            return SessionContainer(session: session, collector: collector)
        }
        #endif
        return nil
    }

    static func _resolve(_ transcript: String,
                         pills: [PillDefinition],
                         sessionBox: AnyObject?) async -> BrainResult? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard SystemLanguageModel.default.availability == .available else { return nil }
            guard let container = sessionBox as? SessionContainer else { return nil }
            let collector = container.collector
            collector.reset()

            let pillList = pills.prefix(20)
                               .map { "\($0.id) (\($0.name))" }
                               .joined(separator: ", ")
            let prompt = """
                User said: "\(transcript)"
                Available pills: \(pillList)
                Use a tool if this is a command. Otherwise answer naturally in the user's language.
                """

            do {
                let response = try await withBrainTimeout(seconds: 4) {
                    try await container.session.respond(to: prompt)
                }
                return BrainResult(intents: collector.intents, text: response.content)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }
}

// MARK: - Timeout helper (file-private)

private func withBrainTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CancellationError()
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else { throw CancellationError() }
        return result
    }
}

// MARK: - FoundationModels types (macOS 26 only)

#if canImport(FoundationModels)

// MARK: IntentCollector

@available(macOS 26, *)
final class IntentCollector: @unchecked Sendable {
    private(set) var intents: [VoiceIntent] = []

    func append(_ intent: VoiceIntent) { intents.append(intent) }
    func reset() { intents = [] }
}

// MARK: SessionContainer

@available(macOS 26, *)
final class SessionContainer: @unchecked Sendable {
    let session: LanguageModelSession
    let collector: IntentCollector
    init(session: LanguageModelSession, collector: IntentCollector) {
        self.session   = session
        self.collector = collector
    }
}

// MARK: PillTool

@available(macOS 26, *)
struct PillTool: Tool, @unchecked Sendable {
    let name        = "pill"
    let description = "Add, remove, set as main, or list pills in the notch"

    @Generable
    struct Arguments {
        @Guide(description: "Action to perform: add | remove | setMain | list")
        var action: String
        @Guide(description: "Pill identifier, e.g. integration_github or agent_cursor. Empty for list.")
        var pillId: String
    }

    let collector: IntentCollector

    func call(arguments: Arguments) async throws -> String {
        let intent: VoiceIntent? = switch arguments.action {
        case "add":     .pillAdd(id: arguments.pillId)
        case "remove":  .pillRemove(id: arguments.pillId)
        case "setMain": .pillSetMain(id: arguments.pillId)
        default:        nil
        }
        if let i = intent { collector.append(i) }
        return arguments.action == "list" ? "Listing active pills" : "\(arguments.action) \(arguments.pillId)"
    }
}

// MARK: MusicTool

@available(macOS 26, *)
struct MusicTool: Tool, @unchecked Sendable {
    let name        = "music"
    let description = "Control music playback: play, pause, next, previous, volumeUp, volumeDown, search, playlist"

    @Generable
    struct Arguments {
        @Guide(description: "Action: play | pause | next | prev | volumeUp | volumeDown | search | playlist")
        var action: String
        @Guide(description: "Track or playlist name for search/playlist. Empty for other actions.")
        var query: String
    }

    let collector: IntentCollector

    func call(arguments: Arguments) async throws -> String {
        let intent: VoiceIntent? = switch arguments.action {
        case "play":       .musicPlay(target: nil)
        case "pause":      .musicPause
        case "next":       .musicNext
        case "prev":       .musicPrevious
        case "volumeUp":   .musicVolumeUp
        case "volumeDown": .musicVolumeDown
        case "search":     arguments.query.isEmpty ? nil : .musicPlaySearch(name: arguments.query)
        case "playlist":   arguments.query.isEmpty ? nil : .musicPlayPlaylist(name: arguments.query)
        default:           nil
        }
        if let i = intent { collector.append(i) }
        return "music \(arguments.action)"
    }
}

// MARK: StatusTool

@available(macOS 26, *)
struct StatusTool: Tool, @unchecked Sendable {
    let name        = "status"
    let description = "Report Coucou status: list active pills, current agent session, or overall app state"

    @Generable
    struct Arguments {
        @Guide(description: "What to report: pills | session | all")
        var query: String
    }

    let collector: IntentCollector

    func call(arguments: Arguments) async throws -> String {
        // Status is answered in natural language by the model; no VoiceIntent needed.
        return "status:\(arguments.query)"
    }
}

#endif // canImport(FoundationModels)
#endif // !APPSTORE
