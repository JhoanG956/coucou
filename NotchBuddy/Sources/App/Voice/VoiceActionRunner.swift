#if !APPSTORE
import Foundation

// MARK: - Protocols (injectable for tests)

/// Abstraction over Apple Music + Spotify playback.
protocol MusicControlling: Sendable {
    var isMusicRunning: Bool { get }
    var isSpotifyRunning: Bool { get }
    @MainActor func playPause()
    @MainActor func nextTrack()
    @MainActor func previousTrack()
    @MainActor func volumeUp()
    @MainActor func volumeDown()
    @MainActor func playArtist(_ name: String)
    @MainActor func playPlaylist(_ name: String)
}

/// Abstraction over AppState pill management.
@MainActor
protocol PillControlling {
    func activeIds() -> Set<String>
    func mainPillId() -> String
    func activeCount() -> Int
    func toggleIntegration(_ id: String)
    func setMainPill(_ id: String)
}

// MARK: - Null implementations (test-safe, no AppKit)

private final class NullMusic: MusicControlling, @unchecked Sendable {
    var isMusicRunning: Bool   { false }
    var isSpotifyRunning: Bool { false }
    @MainActor func playPause()               {}
    @MainActor func nextTrack()               {}
    @MainActor func previousTrack()           {}
    @MainActor func volumeUp()                {}
    @MainActor func volumeDown()              {}
    @MainActor func playArtist(_ n: String)   {}
    @MainActor func playPlaylist(_ n: String) {}
}

@MainActor
private final class NullPills: PillControlling {
    func activeIds() -> Set<String>        { [] }
    func mainPillId() -> String            { "" }
    func activeCount() -> Int              { 0 }
    func toggleIntegration(_ id: String)   {}
    func setMainPill(_ id: String)         {}
}

// MARK: - VoiceActionRunner

/// Translates a VoiceIntent into live app actions and returns a displayable result.
/// Live MusicControlling/PillControlling wired up by LiveVoiceControls.configureLive().
@MainActor
final class VoiceActionRunner {
    static let shared = VoiceActionRunner()

    var music: MusicControlling = NullMusic()
    var pills: PillControlling  = NullPills()

    init() {}

    func run(_ intent: VoiceIntent, availablePills: [PillDefinition] = []) async -> VoiceActionResult {
        switch intent {

        // ── Music ─────────────────────────────────────────────────────────────

        case .musicPlay:
            guard music.isMusicRunning || music.isSpotifyRunning else {
                return fail("voice.no-music-app")
            }
            music.playPause()
            return ok("voice.music-playing")

        case .musicPause:
            guard music.isMusicRunning || music.isSpotifyRunning else {
                return fail("voice.no-music-app")
            }
            music.playPause()
            return ok("voice.music-paused")

        case .musicNext:
            guard music.isMusicRunning || music.isSpotifyRunning else {
                return fail("voice.no-music-app")
            }
            music.nextTrack()
            return ok("voice.music-next")

        case .musicPrevious:
            guard music.isMusicRunning || music.isSpotifyRunning else {
                return fail("voice.no-music-app")
            }
            music.previousTrack()
            return ok("voice.music-prev")

        case .musicVolumeUp:
            guard music.isMusicRunning || music.isSpotifyRunning else {
                return fail("voice.no-music-app")
            }
            music.volumeUp()
            return ok("voice.music-vol-up")

        case .musicVolumeDown:
            guard music.isMusicRunning || music.isSpotifyRunning else {
                return fail("voice.no-music-app")
            }
            music.volumeDown()
            return ok("voice.music-vol-down")

        case .musicPlayArtist(let name):
            guard music.isMusicRunning || music.isSpotifyRunning else {
                return fail("voice.no-music-app")
            }
            music.playArtist(name)
            return ok("voice.music-playing")

        case .musicPlayPlaylist(let name):
            guard music.isMusicRunning || music.isSpotifyRunning else {
                return fail("voice.no-music-app")
            }
            music.playPlaylist(name)
            return ok("voice.music-playing")

        // ── Pills ─────────────────────────────────────────────────────────────

        case .pillAdd(let id):
            if pills.activeIds().contains(id) {
                return ok("voice.pill-already-active")
            }
            guard pills.activeCount() < 4 else {
                return fail("voice.pill-limit")
            }
            pills.toggleIntegration(id)
            return ok(pillName(id, from: availablePills))

        case .pillRemove(let id):
            guard pills.activeIds().contains(id) else {
                return fail("voice.pill-not-active")
            }
            pills.toggleIntegration(id)
            return ok(pillName(id, from: availablePills))

        case .pillSetMain(let id):
            pills.setMainPill(id)
            return ok(pillName(id, from: availablePills))

        case .unknown:
            return fail("voice.unknown")
        }
    }

    // MARK: - Helpers

    private func ok(_ key: String) -> VoiceActionResult {
        .init(outcome: .success, message: NSLocalizedString(key, comment: ""))
    }

    private func fail(_ key: String) -> VoiceActionResult {
        .init(outcome: .failure, message: NSLocalizedString(key, comment: ""))
    }

    private func pillName(_ id: String, from available: [PillDefinition]) -> String {
        available.first(where: { $0.id == id })?.name ?? id
    }
}
#endif
