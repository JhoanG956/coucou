#if !APPSTORE
import AppKit

// MARK: - LiveMusicControl

/// Routes to MusicController (Apple Music) or SpotifyController depending on what's running.
/// Prefers Apple Music; falls back to Spotify if only Spotify is running.
final class LiveMusicControl: MusicControlling, @unchecked Sendable {
    var isMusicRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").count > 0
    }
    var isSpotifyRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").count > 0
    }

    @MainActor func playPause() {
        if isMusicRunning   { MusicController.shared.playPause() }
        else                { SpotifyController.shared.playPause() }
    }
    @MainActor func nextTrack() {
        if isMusicRunning   { MusicController.shared.nextTrack() }
        else                { SpotifyController.shared.nextTrack() }
    }
    @MainActor func previousTrack() {
        if isMusicRunning   { MusicController.shared.previousTrack() }
        else                { SpotifyController.shared.previousTrack() }
    }
    @MainActor func volumeUp() {
        if isMusicRunning   { MusicController.shared.adjustVolume(by: +25) }
        else                { SpotifyController.shared.adjustVolume(by: +25) }
    }
    @MainActor func volumeDown() {
        if isMusicRunning   { MusicController.shared.adjustVolume(by: -25) }
        else                { SpotifyController.shared.adjustVolume(by: -25) }
    }
    @MainActor func playArtist(_ name: String) {
        // Apple Music supports artist search via AppleScript; Spotify has no search API.
        if isMusicRunning   { MusicController.shared.playArtist(name) }
    }
    @MainActor func playPlaylist(_ name: String) {
        if isMusicRunning   { MusicController.shared.playPlaylist(name) }
    }
}

// MARK: - LivePillControl

@MainActor
final class LivePillControl: PillControlling {
    func activeIds()  -> Set<String> { AppState.shared.activeIntegrations }
    func mainPillId() -> String      { AppState.shared.mainPillId }
    func activeCount() -> Int        { AppState.shared.activeIntegrations.count }
    func toggleIntegration(_ id: String) { AppState.shared.toggleIntegration(id) }
    func setMainPill(_ id: String)       { AppState.shared.setMainPill(id) }
}

// MARK: - Configuration

extension VoiceActionRunner {
    /// Wire up live implementations. Call once at app startup.
    func configureLive() {
        music = LiveMusicControl()
        pills = LivePillControl()
    }
}
#endif
