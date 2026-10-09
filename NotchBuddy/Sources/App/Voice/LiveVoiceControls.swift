#if !APPSTORE
import AppKit

// MARK: - LiveMusicControl

final class LiveMusicControl: MusicControlling, @unchecked Sendable {
    var isMusicRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").count > 0
    }
    var isSpotifyRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.spotify.client").count > 0
    }

    @MainActor func play() {
        if isMusicRunning   { MusicController.shared.play() }
        else                { SpotifyController.shared.play() }
    }
    @MainActor func pause() {
        if isMusicRunning   { MusicController.shared.pause() }
        else                { SpotifyController.shared.pause() }
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
    @MainActor func setVolume(_ pct: Int) {
        if isMusicRunning   { MusicController.shared.setVolume(pct) }
        else                { SpotifyController.shared.setVolume(pct) }
    }
    @MainActor func playArtist(_ name: String) async -> Bool {
        guard isMusicRunning else { return false }
        return await MusicController.shared.playArtist(name)
    }
    @MainActor func playPlaylist(_ name: String) async -> Bool {
        guard isMusicRunning else { return false }
        return await MusicController.shared.playPlaylist(name)
    }
    @MainActor func launchAndPlay() async {
        if !isMusicRunning {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Music.app"))
            // Give Music ~1.5 s to launch before sending play
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
        if isMusicRunning { MusicController.shared.play() }
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
    func hooksInstalled(for id: String) -> Bool {
        // Hooks are irrelevant for workspace pills (they auto-detect via process name)
        // For service/agent pills, check if the user has gone through hook setup
        guard let def = PillCatalog.definition(for: id) else { return true }
        if def.source == .claudeCode || def.category == .workspace { return true }
        return AppState.shared.installedHookPills.contains(id)
    }
}

// MARK: - Configuration

extension VoiceActionRunner {
    func configureLive() {
        music = LiveMusicControl()
        pills = LivePillControl()
    }
}
#endif
