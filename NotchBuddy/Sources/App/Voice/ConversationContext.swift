#if !APPSTORE
import Foundation

// MARK: - ConversationContext
//
// Tracks the last executed intent so relative follow-up commands can be resolved:
//   • "et Vercel aussi", "pareil pour Stripe", "also X"  → same verb, new target
//   • "remets-la", "annule ça", "undo"                   → inverse of last reversible action
//
// Pure value type — no AppKit, no AppState, no I/O.
struct ConversationContext {
    private(set) var lastIntent: VoiceIntent? = nil

    /// Update context after a successful turn.
    mutating func update(_ intent: VoiceIntent) {
        switch intent {
        case .pillAdd, .pillAddMultiple, .pillRemove, .pillRemoveMultiple,
             .pillSetMain, .pillReplace, .musicPlay, .musicPause,
             .musicVolumeUp, .musicVolumeDown:
            lastIntent = intent
        default:
            break
        }
    }

    /// Reset at end of conversation window.
    mutating func reset() { lastIntent = nil }

    /// Try to resolve `raw` as a relative command given context.
    /// Returns nil if the phrase is not relative (caller should parse normally).
    func resolveRelative(_ raw: String, pills: [PillDefinition]) -> VoiceIntent? {
        let norm = IntentParser.normalise(raw)
        let words = norm.split(separator: " ").map(String.init)
        if let same = resolveSameTarget(norm: norm, words: words, pills: pills) { return same }
        if let rev  = resolveReverse(norm: norm)                                { return rev  }
        return nil
    }

    // MARK: - Same-action, new target

    // Patterns: "et X aussi", "aussi X", "pareil pour X", "idem pour X", "also X", "same for X"
    private func resolveSameTarget(norm: String, words: [String], pills: [PillDefinition]) -> VoiceIntent? {
        guard let last = lastIntent else { return nil }
        var entityWords: [String]? = nil

        if words.first == "et", let aussiIdx = words.firstIndex(of: "aussi"), aussiIdx > 1 {
            entityWords = Array(words[1..<aussiIdx])
        } else if words.first == "aussi", words.count > 1 {
            entityWords = Array(words[1...])
        } else if words.first == "pareil", words.count > 2,
                  (words[1] == "pour" || words[1] == "avec" || words[1] == "de") {
            entityWords = Array(words[2...])
        } else if words.first == "pareil", words.count > 1 {
            entityWords = Array(words[1...])
        } else if words.first == "idem", words.count > 2,
                  (words[1] == "pour" || words[1] == "avec") {
            entityWords = Array(words[2...])
        } else if words.first == "idem", words.count > 1 {
            entityWords = Array(words[1...])
        } else if words.first == "also", words.count > 1 {
            entityWords = Array(words[1...])
        } else if words.first == "same", words.count > 2, words[1] == "for" {
            entityWords = Array(words[2...])
        }

        guard let ew = entityWords, !ew.isEmpty else { return nil }
        let entity = ew.joined(separator: " ")
        guard let pillId = EntityResolver.resolve(entity, from: pills) else { return nil }

        switch last {
        case .pillAdd:            return .pillAdd(id: pillId)
        case .pillAddMultiple:    return .pillAdd(id: pillId)
        case .pillRemove:         return .pillRemove(id: pillId)
        case .pillRemoveMultiple: return .pillRemove(id: pillId)
        case .pillSetMain:        return .pillSetMain(id: pillId)
        default:                  return nil
        }
    }

    // MARK: - Reverse / undo

    // Triggers: "remets la", "remets le", "annule ca", "undo", "defait",
    //           "cancel that", "undo this"
    // Note: bare "annule" removed — it is a conversation-end phrase (TurnEndPolicy).
    private func resolveReverse(norm: String) -> VoiceIntent? {
        let triggers = ["remets la", "remets le", "annule ca", "undo", "defait",
                        "cancel that", "undo this"]
        let isReverse = triggers.contains { norm == $0 || norm.hasPrefix($0 + " ") }
        guard isReverse, let last = lastIntent else { return nil }
        return inverse(of: last)
    }

    private func inverse(of intent: VoiceIntent) -> VoiceIntent? {
        switch intent {
        case .pillAdd(let id):    return .pillRemove(id: id)
        case .pillRemove(let id): return .pillAdd(id: id)
        case .musicPause:         return .musicPlay(target: nil)
        case .musicPlay:          return .musicPause
        case .musicVolumeUp:      return .musicVolumeDown
        case .musicVolumeDown:    return .musicVolumeUp
        default:                  return nil
        }
    }
}
#endif
