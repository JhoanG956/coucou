#if !APPSTORE
import Foundation

// MARK: - VoiceIntent

/// Structured intent extracted from a voice command transcript.
/// Pure value type — no AppKit, no SwiftUI, no I/O.
enum VoiceIntent: Equatable {

    // ── Music ────────────────────────────────────────────────────────────────

    case musicPlay                          // "lance la musique" / "play"
    case musicPause                         // "pause" / "arrête"
    case musicNext                          // "morceau suivant" / "next track"
    case musicPrevious                      // "morceau précédent" / "previous"
    case musicPlayArtist(name: String)      // "mets du Daft Punk"
    case musicPlayPlaylist(name: String)    // "mets la playlist Workout"
    case musicVolumeUp                      // "monte le son"
    case musicVolumeDown                    // "baisse le son"

    // ── Pills ─────────────────────────────────────────────────────────────────

    case pillAdd(id: String)                // "ajoute GitHub"
    case pillRemove(id: String)             // "enlève Vercel"
    case pillSetMain(id: String)            // "passe sur Cursor" (workspace pills only)

    // ── Unknown ───────────────────────────────────────────────────────────────

    case unknown
}

// MARK: - VoiceActionResult

/// Outcome displayed in VoiceResultView for ~2 s after a command runs.
struct VoiceActionResult: Equatable {
    enum Outcome: Equatable { case success, failure }
    let outcome: Outcome
    let message: String   // e.g. "Musique lancée" / "Je n'ai pas compris"
}
#endif
