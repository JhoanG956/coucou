#if !APPSTORE
import Foundation

// MARK: - VoiceTranscriptHistory
//
// In-memory circular buffer of the last 20 transcripts heard in a voice session.
// Never written to disk. Cleared when the app closes (in-memory only).
// Used exclusively by the Settings → Voice debug section.

enum TranscriptOrigin: String {
    case parser  = "parser"   // IntentParser resolved the intent
    case context = "context"  // ConversationContext resolved a relative follow-up
    case brain   = "brain"    // VoiceBrain (FoundationModels) resolved the intent
}

struct TranscriptEntry: Identifiable {
    let id   = UUID()
    let date = Date()
    let transcript: String
    let intent:     String    // VoiceIntent description
    let origin:     TranscriptOrigin
}

@MainActor
final class VoiceTranscriptHistory: ObservableObject {
    static let shared = VoiceTranscriptHistory()
    private init() {}

    private static let maxEntries = 20
    @Published private(set) var entries: [TranscriptEntry] = []

    func record(transcript: String, intent: VoiceIntent, origin: TranscriptOrigin) {
        let entry = TranscriptEntry(
            transcript: transcript,
            intent:     String(describing: intent),
            origin:     origin
        )
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
    }

    func clear() { entries = [] }

    var plainText: String {
        entries.map { e in
            let t = ISO8601DateFormatter().string(from: e.date)
            return "[\(t)] [\(e.origin.rawValue)] \(e.transcript) → \(e.intent)"
        }.joined(separator: "\n")
    }
}
#endif
