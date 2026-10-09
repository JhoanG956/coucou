#if !APPSTORE
import Foundation

// MARK: - Protocols (injectable for tests)

/// Abstraction over Apple Music + Spotify playback.
protocol MusicControlling: Sendable {
    var isMusicRunning: Bool { get }
    var isSpotifyRunning: Bool { get }
    @MainActor func play()
    @MainActor func pause()
    @MainActor func nextTrack()
    @MainActor func previousTrack()
    @MainActor func volumeUp()
    @MainActor func volumeDown()
    @MainActor func setVolume(_ pct: Int)
    @MainActor func playArtist(_ name: String) async -> Bool
    @MainActor func playPlaylist(_ name: String) async -> Bool
    @MainActor func launchAndPlay() async
}

/// Abstraction over AppState pill management.
@MainActor
protocol PillControlling {
    func activeIds() -> Set<String>
    func mainPillId() -> String
    func activeCount() -> Int
    func toggleIntegration(_ id: String)
    func setMainPill(_ id: String)
    func hooksInstalled(for id: String) -> Bool
}

// MARK: - Null implementations (test-safe, no AppKit)

private final class NullMusic: MusicControlling, @unchecked Sendable {
    var isMusicRunning: Bool   { false }
    var isSpotifyRunning: Bool { false }
    @MainActor func play()                        {}
    @MainActor func pause()                       {}
    @MainActor func nextTrack()                   {}
    @MainActor func previousTrack()               {}
    @MainActor func volumeUp()                    {}
    @MainActor func volumeDown()                  {}
    @MainActor func setVolume(_ pct: Int)         {}
    @MainActor func playArtist(_ n: String) async -> Bool  { false }
    @MainActor func playPlaylist(_ n: String) async -> Bool { false }
    @MainActor func launchAndPlay() async         {}
}

@MainActor
private final class NullPills: PillControlling {
    func activeIds() -> Set<String>        { [] }
    func mainPillId() -> String            { "" }
    func activeCount() -> Int              { 0 }
    func toggleIntegration(_ id: String)   {}
    func setMainPill(_ id: String)         {}
    func hooksInstalled(for id: String) -> Bool { true }
}

// MARK: - VoiceActionRunner

@MainActor
final class VoiceActionRunner {
    static let shared = VoiceActionRunner()

    var music: MusicControlling = NullMusic()
    var pills: PillControlling  = NullPills()

    init() {}

    func run(_ intent: VoiceIntent,
             availablePills: [PillDefinition] = [],
             rawTranscript: String = "") async -> VoiceActionResult {
        switch intent {

        // ── Music ─────────────────────────────────────────────────────────────

        case .musicPlay:
            if !music.isMusicRunning && !music.isSpotifyRunning {
                await music.launchAndPlay()
                return ok("voice.music-launch")
            }
            music.play()
            return ok("voice.music-playing")

        case .musicPause:
            guard music.isMusicRunning || music.isSpotifyRunning else {
                return fail("voice.no-music-app")
            }
            music.pause()
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

        case .musicSetVolume(let pct):
            guard music.isMusicRunning || music.isSpotifyRunning else {
                return fail("voice.no-music-app")
            }
            music.setVolume(pct)
            let fmt = NSLocalizedString("voice.music-vol-set", comment: "")
            return .init(outcome: .success, message: String(format: fmt, pct))

        case .musicPlayArtist(let name):
            // "spotify" / "apple music" entity → route to appropriate service
            let norm = IntentParser.normalise(name)
            if norm == "spotify" {
                if !music.isSpotifyRunning { await music.launchAndPlay() }
                else { music.play() }
                return ok("voice.music-playing")
            }
            if norm == "apple music" || norm == "music" {
                if !music.isMusicRunning { await music.launchAndPlay() }
                else { music.play() }
                return ok("voice.music-playing")
            }
            if !music.isMusicRunning && !music.isSpotifyRunning {
                await music.launchAndPlay()
            }
            let found = await music.playArtist(name)
            if found { return ok("voice.music-playing") }
            let fmt = NSLocalizedString("voice.music-artist-err", comment: "")
            return .init(outcome: .failure, message: String(format: fmt, name))

        case .musicPlayPlaylist(let name):
            if !music.isMusicRunning && !music.isSpotifyRunning {
                await music.launchAndPlay()
            }
            let found = await music.playPlaylist(name)
            if found { return ok("voice.music-playing") }
            let fmt = NSLocalizedString("voice.music-artist-err", comment: "")
            return .init(outcome: .failure, message: String(format: fmt, name))

        // ── Pills ─────────────────────────────────────────────────────────────

        case .pillAdd(let id):
            if pills.activeIds().contains(id) {
                return ok("voice.pill-already-active")
            }
            guard pills.activeCount() < 4 else {
                let qFmt = NSLocalizedString("voice.ask-which-remove", comment: "")
                return .init(outcome: .question(text: qFmt), message: qFmt)
            }
            pills.toggleIntegration(id)
            let name = pillName(id, from: availablePills)
            let fmt  = NSLocalizedString("voice.pill-added", comment: "")
            let msg  = fmt.contains("%@") ? String(format: fmt, name) : name
            if !pills.hooksInstalled(for: id) {
                let hFmt = NSLocalizedString("voice.pill-no-hooks", comment: "")
                let hMsg = hFmt.contains("%@") ? String(format: hFmt, name) : "\(name) — hooks non installés"
                return .init(outcome: .success, message: hMsg)
            }
            return .init(outcome: .success, message: msg)

        case .pillRemove(let id):
            guard pills.activeIds().contains(id) else {
                return fail("voice.pill-not-active")
            }
            pills.toggleIntegration(id)
            let name = pillName(id, from: availablePills)
            let fmt  = NSLocalizedString("voice.pill-removed", comment: "")
            let msg  = fmt.contains("%@") ? String(format: fmt, name) : name
            return .init(outcome: .success, message: msg)

        case .pillSetMain(let id):
            pills.setMainPill(id)
            let name = pillName(id, from: availablePills)
            let fmt  = NSLocalizedString("voice.pill-main", comment: "")
            let msg  = fmt.contains("%@") ? String(format: fmt, name) : name
            return .init(outcome: .success, message: msg)

        case .pillReplace(let oldId, let newId):
            if pills.activeIds().contains(oldId) { pills.toggleIntegration(oldId) }
            if !pills.activeIds().contains(newId) { pills.toggleIntegration(newId) }
            let n1  = pillName(oldId, from: availablePills)
            let n2  = pillName(newId, from: availablePills)
            let fmt = NSLocalizedString("voice.pill-replaced", comment: "")
            let msg = fmt.contains("%@") ? String(format: fmt, n1, n2) : "\(n1) → \(n2)"
            return .init(outcome: .success, message: msg)

        case .pillOnly(let ids):
            // Remove all active pills not in the list, add all in the list
            let current = pills.activeIds()
            for id in current { if !ids.contains(id) { pills.toggleIntegration(id) } }
            for id in ids { if !pills.activeIds().contains(id) { pills.toggleIntegration(id) } }
            let names = ids.map { pillName($0, from: availablePills) }.joined(separator: ", ")
            let fmt   = NSLocalizedString("voice.pill-only", comment: "")
            let msg   = fmt.contains("%@") ? String(format: fmt, names) : names
            return .init(outcome: .success, message: msg)

        case .unknown:
            if rawTranscript.isEmpty {
                return fail("voice.unknown")
            }
            let fmt = NSLocalizedString("voice.unknown-transcript", comment: "")
            let msg = fmt.contains("%@") ? String(format: fmt, rawTranscript) : rawTranscript
            return .init(outcome: .failure, message: msg)
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
