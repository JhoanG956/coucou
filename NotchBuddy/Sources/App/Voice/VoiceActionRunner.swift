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
    @MainActor func playSearch(_ name: String) async -> Bool
    @MainActor func playPlaylist(_ name: String) async -> Bool
    @MainActor func launchAndPlay() async
    @MainActor func launchSpotify() async
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
    @MainActor func play()                           {}
    @MainActor func pause()                          {}
    @MainActor func nextTrack()                      {}
    @MainActor func previousTrack()                  {}
    @MainActor func volumeUp()                       {}
    @MainActor func volumeDown()                     {}
    @MainActor func setVolume(_ pct: Int)            {}
    @MainActor func playSearch(_ n: String) async -> Bool   { false }
    @MainActor func playPlaylist(_ n: String) async -> Bool { false }
    @MainActor func launchAndPlay() async            {}
    @MainActor func launchSpotify() async            {}
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

@MainActor
final class VoiceActionRunner {
    static let shared = VoiceActionRunner()

    var music: MusicControlling = NullMusic()
    var pills: PillControlling  = NullPills()

    /// Pending follow-up question (4-pill limit, ambiguity). Set when outcome is .question.
    var pendingQuestion: PendingVoiceQuestion? = nil

    init() {}

    func run(_ intent: VoiceIntent,
             availablePills: [PillDefinition] = [],
             rawTranscript: String = "") async -> VoiceActionResult {
        switch intent {

        // ── Music ─────────────────────────────────────────────────────────────

        case .musicPlay(let target):
            switch target {
            case .spotify:
                if !music.isSpotifyRunning { await music.launchSpotify() }
                else { music.play() }
                return ok("voice.music-playing")
            case .appleMusic:
                if !music.isMusicRunning { await music.launchAndPlay() }
                else { music.play() }
                return ok("voice.music-playing")
            case nil:
                if music.isMusicRunning || music.isSpotifyRunning {
                    music.play()
                    return ok("voice.music-playing")
                }
                await music.launchAndPlay()
                return ok("voice.music-launch")
            }

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
            return .init(outcome: .success, message: fmt.contains("%") ? String(format: fmt, pct) : "\(pct)%")

        case .musicPlaySearch(let name):
            if !music.isMusicRunning && !music.isSpotifyRunning {
                await music.launchAndPlay()
            }
            let found = await music.playSearch(name)
            if found { return ok("voice.music-playing") }
            let fmt = NSLocalizedString("voice.music-artist-err", comment: "")
            return .init(outcome: .failure,
                         message: fmt.contains("%@") ? String(format: fmt, name) : name)

        case .musicPlayPlaylist(let name):
            if !music.isMusicRunning && !music.isSpotifyRunning {
                await music.launchAndPlay()
            }
            let found = await music.playPlaylist(name)
            if found { return ok("voice.music-playing") }
            let fmt = NSLocalizedString("voice.music-artist-err", comment: "")
            return .init(outcome: .failure,
                         message: fmt.contains("%@") ? String(format: fmt, name) : name)

        // ── Pills ─────────────────────────────────────────────────────────────

        case .pillAdd(let id):
            if pills.activeIds().contains(id) {
                return ok("voice.pill-already-active")
            }
            guard pills.activeCount() < 4 else {
                let qFmt = NSLocalizedString("voice.ask-which-remove", comment: "")
                pendingQuestion = PendingVoiceQuestion(kind: .removeWhich(toAdd: id), text: qFmt)
                return .init(outcome: .question(text: qFmt), message: qFmt)
            }
            pills.toggleIntegration(id)
            let name = pillName(id, from: availablePills)
            let fmt  = NSLocalizedString("voice.pill-added", comment: "")
            let msg  = fmt.contains("%@") ? String(format: fmt, name) : name
            return .init(outcome: .success, message: msg)

        case .pillAddMultiple(let ids):
            var added: [String] = []
            for id in ids {
                guard !pills.activeIds().contains(id), pills.activeCount() < 4 else { continue }
                pills.toggleIntegration(id)
                added.append(pillName(id, from: availablePills))
            }
            let names = added.joined(separator: ", ")
            let fmt   = NSLocalizedString("voice.pill-added", comment: "")
            let msg   = fmt.contains("%@") ? String(format: fmt, names) : names
            return .init(outcome: added.isEmpty ? .failure : .success,
                         message: added.isEmpty ? NSLocalizedString("voice.unknown", comment: "") : msg)

        case .pillRemove(let id):
            guard pills.activeIds().contains(id) else {
                return fail("voice.pill-not-active")
            }
            pills.toggleIntegration(id)
            let name = pillName(id, from: availablePills)
            let fmt  = NSLocalizedString("voice.pill-removed", comment: "")
            let msg  = fmt.contains("%@") ? String(format: fmt, name) : name
            return .init(outcome: .success, message: msg)

        case .pillRemoveMultiple(let ids):
            var removed: [String] = []
            for id in ids {
                guard pills.activeIds().contains(id) else { continue }
                pills.toggleIntegration(id)
                removed.append(pillName(id, from: availablePills))
            }
            let names = removed.joined(separator: ", ")
            let fmt   = NSLocalizedString("voice.pill-removed", comment: "")
            let msg   = fmt.contains("%@") ? String(format: fmt, names) : names
            return .init(outcome: removed.isEmpty ? .failure : .success,
                         message: removed.isEmpty ? NSLocalizedString("voice.unknown", comment: "") : msg)

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
            let current = pills.activeIds()
            for id in current { if !ids.contains(id) { pills.toggleIntegration(id) } }
            for id in ids { if !pills.activeIds().contains(id) { pills.toggleIntegration(id) } }
            let names = ids.map { pillName($0, from: availablePills) }.joined(separator: ", ")
            let fmt   = NSLocalizedString("voice.pill-only", comment: "")
            let msg   = fmt.contains("%@") ? String(format: fmt, names) : names
            return .init(outcome: .success, message: msg)

        case .unknown:
            if rawTranscript.isEmpty { return fail("voice.unknown") }
            let fmt = NSLocalizedString("voice.unknown-transcript", comment: "")
            let msg = fmt.contains("%@") ? String(format: fmt, rawTranscript) : rawTranscript
            return .init(outcome: .failure, message: msg)
        }
    }

    // MARK: - Follow-up question answer

    /// Handle a follow-up answer transcript after a .question outcome.
    func handleAnswer(_ transcript: String, availablePills: [PillDefinition] = []) async -> VoiceActionResult {
        guard let pending = pendingQuestion else { return fail("voice.unknown") }
        pendingQuestion = nil

        guard !transcript.trimmingCharacters(in: .whitespaces).isEmpty else {
            return ok("voice.question-cancelled")
        }

        let norm = IntentParser.normalise(transcript)
        guard let entity = EntityResolver.resolve(norm, from: availablePills) else {
            return fail("voice.unknown")
        }

        switch pending.kind {
        case .removeWhich(let toAdd):
            if pills.activeIds().contains(entity) {
                pills.toggleIntegration(entity)
            }
            if !pills.activeIds().contains(toAdd), pills.activeCount() < 4 {
                pills.toggleIntegration(toAdd)
            }
            let removedName = pillName(entity, from: availablePills)
            let addedName   = pillName(toAdd,  from: availablePills)
            let fmt = NSLocalizedString("voice.pill-replaced", comment: "")
            let msg = fmt.contains("%@") ? String(format: fmt, removedName, addedName)
                                         : "\(removedName) → \(addedName)"
            return .init(outcome: .success, message: msg)
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
