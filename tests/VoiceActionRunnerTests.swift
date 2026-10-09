import Foundation

// MARK: - VoiceActionRunner tests with mock implementations

final class MockMusic: MusicControlling, @unchecked Sendable {
    var musicRunning  = true
    var spotifyRunning = false
    var isMusicRunning: Bool  { musicRunning }
    var isSpotifyRunning: Bool { spotifyRunning }

    var calls: [String] = []
    var artistResult  = true   // mock return for playArtist
    var playlistResult = true  // mock return for playPlaylist

    @MainActor func play()                     { calls.append("play") }
    @MainActor func pause()                    { calls.append("pause") }
    @MainActor func nextTrack()                { calls.append("nextTrack") }
    @MainActor func previousTrack()            { calls.append("prevTrack") }
    @MainActor func volumeUp()                 { calls.append("volUp") }
    @MainActor func volumeDown()               { calls.append("volDown") }
    @MainActor func setVolume(_ p: Int)        { calls.append("setVolume:\(p)") }
    @MainActor func playArtist(_ n: String) async -> Bool  { calls.append("artist:\(n)"); return artistResult }
    @MainActor func playPlaylist(_ n: String) async -> Bool { calls.append("playlist:\(n)"); return playlistResult }
    @MainActor func launchAndPlay() async      { calls.append("launchAndPlay") }
}

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
    func setMainPill(_ id: String) { calls.append("setMain:\(id)"); main = id }
    func hooksInstalled(for id: String) -> Bool { true }
}

let pills = PillFixture.available

@main
enum VoiceActionRunnerTests {

    static var pass = 0
    static var fail = 0

    static func main() async {
        let runner = VoiceActionRunner()
        let music  = MockMusic()
        let pills_ = MockPills()
        runner.music = music
        runner.pills = pills_

        // ── Music: no app running → launch ───────────────────────────────────
        music.musicRunning   = false
        music.spotifyRunning = false
        music.calls = []
        let noApp = await runner.run(.musicPlay, availablePills: pills)
        check("no music app → launch",   noApp.outcome, .success)
        check("no music app → launchAndPlay called", music.calls.contains("launchAndPlay"), true)

        // ── Music commands with app running ───────────────────────────────────
        music.musicRunning = true
        music.calls = []

        let play = await runner.run(.musicPlay, availablePills: pills)
        check("play → success",       play.outcome, .success)
        check("play → play called",   music.calls.last, "play")
        music.calls = []

        let pause_ = await runner.run(.musicPause, availablePills: pills)
        check("pause → success",      pause_.outcome, .success)
        check("pause → pause called", music.calls.last, "pause")
        music.calls = []

        let next = await runner.run(.musicNext, availablePills: pills)
        check("next → success",       next.outcome, .success)
        check("next → nextTrack",     music.calls.last, "nextTrack")
        music.calls = []

        let prev = await runner.run(.musicPrevious, availablePills: pills)
        check("previous → success",   prev.outcome, .success)
        check("previous → prevTrack", music.calls.last, "prevTrack")
        music.calls = []

        let vup = await runner.run(.musicVolumeUp, availablePills: pills)
        check("volUp → success",      vup.outcome, .success)
        check("volUp → volUp",        music.calls.last, "volUp")
        music.calls = []

        let vdn = await runner.run(.musicVolumeDown, availablePills: pills)
        check("volDown → success",    vdn.outcome, .success)
        check("volDown → volDown",    music.calls.last, "volDown")
        music.calls = []

        let vol50 = await runner.run(.musicSetVolume(50), availablePills: pills)
        check("setVolume(50) → success", vol50.outcome, .success)
        check("setVolume(50) → setVolume:50", music.calls.last, "setVolume:50")
        music.calls = []

        let artist = await runner.run(.musicPlayArtist(name: "Daft Punk"), availablePills: pills)
        check("artist → success",     artist.outcome, .success)
        check("artist → artist:Daft Punk", music.calls.last, "artist:Daft Punk")
        music.calls = []

        // Artist not found → failure
        music.artistResult = false
        let artistFail = await runner.run(.musicPlayArtist(name: "XYZ"), availablePills: pills)
        check("artist not found → failure", artistFail.outcome, .failure)
        music.artistResult = true
        music.calls = []

        let pl = await runner.run(.musicPlayPlaylist(name: "Workout"), availablePills: pills)
        check("playlist → success",   pl.outcome, .success)
        check("playlist → playlist:Workout", music.calls.last, "playlist:Workout")
        music.calls = []

        // ── Pills: add ────────────────────────────────────────────────────────
        pills_.active = ["integration_github"]
        pills_.calls  = []
        let addNotion = await runner.run(.pillAdd(id: "integration_notion"), availablePills: pills)
        check("pillAdd → success",    addNotion.outcome, .success)
        check("pillAdd → toggle",     pills_.calls.first, "toggle:integration_notion")

        // Already active → success no-op
        pills_.active = ["integration_github", "integration_notion"]
        let addAgain  = await runner.run(.pillAdd(id: "integration_github"), availablePills: pills)
        check("pillAdd already active → success", addAgain.outcome, .success)

        // Limit → question
        pills_.active = Set(["integration_github","integration_vercel","integration_notion","integration_resend"])
        pills_.calls  = []
        let addLimit  = await runner.run(.pillAdd(id: "agent_cursor"), availablePills: pills)
        if case .question(_) = addLimit.outcome { print("✓  pillAdd limit → question"); pass += 1 }
        else { print("✗  pillAdd limit — got \(addLimit.outcome)"); fail += 1 }

        // ── Pills: remove ─────────────────────────────────────────────────────
        pills_.active = ["integration_github", "integration_vercel"]
        pills_.calls  = []
        let rem = await runner.run(.pillRemove(id: "integration_github"), availablePills: pills)
        check("pillRemove → success", rem.outcome, .success)
        check("pillRemove → toggle",  pills_.calls.first, "toggle:integration_github")

        pills_.active = ["integration_vercel"]
        let remAbsent = await runner.run(.pillRemove(id: "integration_github"), availablePills: pills)
        check("pillRemove not active → failure", remAbsent.outcome, .failure)

        // ── Pills: setMain ────────────────────────────────────────────────────
        pills_.main  = "integration_claude"
        pills_.calls = []
        let setMain = await runner.run(.pillSetMain(id: "agent_cursor"), availablePills: pills)
        check("pillSetMain → success", setMain.outcome, .success)
        check("pillSetMain → setMain", pills_.calls.first, "setMain:agent_cursor")

        // ── Pills: replace ────────────────────────────────────────────────────
        pills_.active = ["integration_n8n", "integration_github"]
        pills_.calls  = []
        let rep = await runner.run(.pillReplace(old: "integration_n8n", new: "integration_vercel"), availablePills: pills)
        check("pillReplace → success",           rep.outcome, .success)
        check("pillReplace → toggle old off",    pills_.calls.contains("toggle:integration_n8n"),    true)
        check("pillReplace → toggle new on",     pills_.calls.contains("toggle:integration_vercel"), true)

        // ── Pills: only ───────────────────────────────────────────────────────
        pills_.active = ["integration_github", "integration_n8n", "integration_notion"]
        pills_.calls  = []
        let only = await runner.run(.pillOnly(["integration_github", "integration_vercel"]), availablePills: pills)
        check("pillOnly → success", only.outcome, .success)
        // n8n and notion should be removed; vercel should be added
        check("pillOnly → removed n8n",    pills_.calls.contains("toggle:integration_n8n"),    true)
        check("pillOnly → removed notion", pills_.calls.contains("toggle:integration_notion"), true)
        check("pillOnly → added vercel",   pills_.calls.contains("toggle:integration_vercel"), true)

        // ── Unknown ───────────────────────────────────────────────────────────
        let unk = await runner.run(.unknown, availablePills: pills)
        check("unknown → failure", unk.outcome, .failure)

        let unkTx = await runner.run(.unknown, availablePills: pills, rawTranscript: "blabla")
        check("unknown with transcript → failure", unkTx.outcome, .failure)

        let total = pass + fail
        if fail == 0 { print("\n\(total)/\(total) passed.") }
        else { print("\n\(fail) FAILED / \(total) total"); exit(1) }
    }

    static func check<T: Equatable>(_ label: String, _ got: T, _ want: T) {
        if got == want { print("✓  \(label)"); pass += 1 }
        else { print("✗  \(label) — got \(got), want \(want)"); fail += 1 }
    }
}
