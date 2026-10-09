import Foundation

// MARK: - VoiceActionRunner tests with mock implementations

// ── Mock MusicControlling ─────────────────────────────────────────────────────

final class MockMusic: MusicControlling, @unchecked Sendable {
    var musicRunning = true
    var spotifyRunning = false
    var isMusicRunning: Bool { musicRunning }
    var isSpotifyRunning: Bool { spotifyRunning }

    var calls: [String] = []
    func playPause()            { calls.append("playPause") }
    func nextTrack()            { calls.append("nextTrack") }
    func previousTrack()        { calls.append("prevTrack") }
    func volumeUp()             { calls.append("volUp") }
    func volumeDown()           { calls.append("volDown") }
    func playArtist(_ n: String) { calls.append("artist:\(n)") }
    func playPlaylist(_ n: String) { calls.append("playlist:\(n)") }
}

// ── Mock PillControlling ──────────────────────────────────────────────────────

@MainActor
final class MockPills: PillControlling {
    var active: Set<String> = ["integration_github", "integration_vercel"]
    var main = "integration_claude"
    var calls: [String] = []

    func activeIds()  -> Set<String> { active }
    func mainPillId() -> String      { main }
    func activeCount() -> Int        { active.count }
    func toggleIntegration(_ id: String) {
        calls.append("toggle:\(id)")
        if active.contains(id) { active.remove(id) } else { active.insert(id) }
    }
    func setMainPill(_ id: String) {
        calls.append("setMain:\(id)")
        main = id
    }
}

// ── Test runner ───────────────────────────────────────────────────────────────

let pills: [PillDefinition] = [
    .init(id: "integration_github",  name: "GitHub",  color: "#F4505E",
          category: .service,   subtitle: "Integration", source: .n8n),
    .init(id: "integration_vercel",  name: "Vercel",  color: "#7C5CFF",
          category: .service,   subtitle: "Integration", source: .n8n),
    .init(id: "integration_notion",  name: "Notion",  color: "#8C8C8C",
          category: .service,   subtitle: "Integration", source: .n8n),
    .init(id: "agent_cursor",        name: "Cursor",  color: "#C0C4CC",
          category: .workspace, subtitle: "Integration", source: .agent),
    .init(id: "integration_claude",  name: "VS Code", color: "#F5F6F8",
          category: .workspace, subtitle: "Integration", source: .claudeCode),
]

@main
enum VoiceActionRunnerTests {

    static var pass = 0
    static var fail = 0

    static func main() async {
        // Runner under test
        let runner = VoiceActionRunner()
        let music  = MockMusic()
        let pills_ = MockPills()
        runner.music = music
        runner.pills = pills_

        // ── Music: no app running → failure ──────────────────────────────────
        music.musicRunning   = false
        music.spotifyRunning = false
        let noApp = await runner.run(.musicPlay, availablePills: pills)
        check("no music app → failure", noApp.outcome, .failure)

        // ── Music commands with app running ───────────────────────────────────
        music.musicRunning = true

        let play = await runner.run(.musicPlay, availablePills: pills)
        check("play → success", play.outcome, .success)
        check("play → playPause called", music.calls.last, "playPause")
        music.calls = []

        let pause_ = await runner.run(.musicPause, availablePills: pills)
        check("pause → success", pause_.outcome, .success)
        check("pause → playPause called", music.calls.last, "playPause")
        music.calls = []

        let next = await runner.run(.musicNext, availablePills: pills)
        check("next → success", next.outcome, .success)
        check("next → nextTrack called", music.calls.last, "nextTrack")
        music.calls = []

        let prev = await runner.run(.musicPrevious, availablePills: pills)
        check("previous → success", prev.outcome, .success)
        check("previous → prevTrack called", music.calls.last, "prevTrack")
        music.calls = []

        let vup = await runner.run(.musicVolumeUp, availablePills: pills)
        check("volUp → success", vup.outcome, .success)
        check("volUp → volUp called", music.calls.last, "volUp")
        music.calls = []

        let vdn = await runner.run(.musicVolumeDown, availablePills: pills)
        check("volDown → success", vdn.outcome, .success)
        check("volDown → volDown called", music.calls.last, "volDown")
        music.calls = []

        let artist = await runner.run(.musicPlayArtist(name: "Daft Punk"), availablePills: pills)
        check("artist → success", artist.outcome, .success)
        check("artist → playArtist called", music.calls.last, "artist:Daft Punk")
        music.calls = []

        let pl = await runner.run(.musicPlayPlaylist(name: "Workout"), availablePills: pills)
        check("playlist → success", pl.outcome, .success)
        check("playlist → playPlaylist called", music.calls.last, "playlist:Workout")
        music.calls = []

        // ── Pills: add (slot available) ───────────────────────────────────────
        pills_.active = ["integration_github"]   // 1 active, room for more
        pills_.calls  = []
        let addNotion = await runner.run(.pillAdd(id: "integration_notion"), availablePills: pills)
        check("pillAdd → success", addNotion.outcome, .success)
        check("pillAdd → toggle called", pills_.calls.first, "toggle:integration_notion")

        // ── Pills: add (already active) ────────────────────────────────────────
        pills_.active = ["integration_github", "integration_notion"]
        pills_.calls  = []
        let addAgain = await runner.run(.pillAdd(id: "integration_github"), availablePills: pills)
        check("pillAdd already active → success (no-op)", addAgain.outcome, .success)
        check("pillAdd already active → no toggle", pills_.calls.isEmpty, true)

        // ── Pills: add (limit reached) ────────────────────────────────────────
        pills_.active = Set(["integration_github","integration_vercel","integration_notion",
                              "integration_resend"])  // 4 = max
        pills_.calls  = []
        let addLimit = await runner.run(.pillAdd(id: "agent_cursor"), availablePills: pills)
        check("pillAdd limit → failure", addLimit.outcome, .failure)

        // ── Pills: remove ─────────────────────────────────────────────────────
        pills_.active = ["integration_github", "integration_vercel"]
        pills_.calls  = []
        let rem = await runner.run(.pillRemove(id: "integration_github"), availablePills: pills)
        check("pillRemove → success", rem.outcome, .success)
        check("pillRemove → toggle called", pills_.calls.first, "toggle:integration_github")

        // ── Pills: remove (not active) ────────────────────────────────────────
        pills_.active = ["integration_vercel"]
        pills_.calls  = []
        let remAbsent = await runner.run(.pillRemove(id: "integration_github"), availablePills: pills)
        check("pillRemove not active → failure", remAbsent.outcome, .failure)

        // ── Pills: set main ───────────────────────────────────────────────────
        pills_.main  = "integration_claude"
        pills_.calls = []
        let setMain = await runner.run(.pillSetMain(id: "agent_cursor"), availablePills: pills)
        check("pillSetMain → success", setMain.outcome, .success)
        check("pillSetMain → setMain called", pills_.calls.first, "setMain:agent_cursor")

        // ── Unknown ───────────────────────────────────────────────────────────
        let unk = await runner.run(.unknown, availablePills: pills)
        check("unknown → failure", unk.outcome, .failure)

        // Summary
        let total = pass + fail
        if fail == 0 { print("\n\(total)/\(total) passed.") }
        else { print("\n\(fail) FAILED / \(total) total"); exit(1) }
    }

    static func check<T: Equatable>(_ label: String, _ got: T, _ want: T) {
        if got == want {
            print("✓  \(label)"); pass += 1
        } else {
            print("✗  \(label) — got \(got), want \(want)"); fail += 1
        }
    }
}
