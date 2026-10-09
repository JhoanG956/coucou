import Foundation

// MARK: - IntentParser tests (uses PillFixture.available — real catalog)

@main
enum IntentParserTests {

    static var pass = 0
    static var fail = 0

    static let pills = PillFixture.available

    static func main() {

        // ── Music: pause ──────────────────────────────────────────────────────
        check("pause",                       parse("pause"),                   .musicPause)
        check("stop",                        parse("stop"),                    .musicPause)
        check("stoppe",                      parse("stoppe"),                  .musicPause)
        check("mets en pause",               parse("mets en pause"),           .musicPause)
        check("arrête la musique",           parse("arrête la musique"),       .musicPause)
        check("PAUSE",                       parse("PAUSE"),                   .musicPause)

        // ── Music: play (generic) ─────────────────────────────────────────────
        check("lance la musique",            parse("lance la musique"),        .musicPlay)
        check("reprends",                    parse("reprends"),                .musicPlay)
        check("reprends la musique",         parse("reprends la musique"),     .musicPlay)
        check("play music",                  parse("play music"),              .musicPlay)
        check("resume music",                parse("resume music"),            .musicPlay)
        check("play some music",             parse("play some music"),         .musicPlay)
        check("balance de la musique",       parse("balance de la musique"),   .musicPlay)
        check("mets de la musique",          parse("mets de la musique"),      .musicPlay)
        check("mets du son",                 parse("mets du son"),             .musicPlay)
        check("lance Apple Music",           parse("lance Apple Music", pills: pills), .musicPlay)
        check("lance Spotify",               parse("lance Spotify", pills: pills),     .musicPlay)

        // ── Music: next/prev ──────────────────────────────────────────────────
        check("suivant",                     parse("suivant"),                 .musicNext)
        check("morceau suivant",             parse("morceau suivant"),         .musicNext)
        check("chanson suivante",            parse("chanson suivante"),        .musicNext)
        check("next",                        parse("next"),                    .musicNext)
        check("next track",                  parse("next track"),              .musicNext)
        check("skip",                        parse("skip"),                    .musicNext)
        check("next song",                   parse("next song"),               .musicNext)
        check("précédent",                   parse("précédent"),               .musicPrevious)
        check("morceau précédent",           parse("morceau précédent"),       .musicPrevious)
        check("previous",                    parse("previous"),                .musicPrevious)
        check("previous track",              parse("previous track"),          .musicPrevious)
        check("back",                        parse("back"),                    .musicPrevious)

        // ── Music: volume ─────────────────────────────────────────────────────
        check("monte le son",                parse("monte le son"),            .musicVolumeUp)
        check("monte le volume",             parse("monte le volume"),         .musicVolumeUp)
        check("plus fort",                   parse("plus fort"),               .musicVolumeUp)
        check("volume up",                   parse("volume up"),               .musicVolumeUp)
        check("louder",                      parse("louder"),                  .musicVolumeUp)
        check("baisse le son",               parse("baisse le son"),           .musicVolumeDown)
        check("baisse le volume",            parse("baisse le volume"),        .musicVolumeDown)
        check("moins fort",                  parse("moins fort"),              .musicVolumeDown)
        check("volume down",                 parse("volume down"),             .musicVolumeDown)
        check("quieter",                     parse("quieter"),                 .musicVolumeDown)
        check("turn down",                   parse("turn down"),               .musicVolumeDown)
        check("monte le son",                parse("monte le son"),            .musicVolumeUp)

        // ── Music: volume set ─────────────────────────────────────────────────
        check("volume à 50",                 parse("volume à 50"),             .musicSetVolume(50))
        check("set volume 75",               parse("set volume 75"),           .musicSetVolume(75))
        check("volume 0",                    parse("volume 0"),                .musicSetVolume(0))
        check("volume 100",                  parse("volume 100"),              .musicSetVolume(100))

        // ── Music: artist ─────────────────────────────────────────────────────
        checkArtist("mets du Daft Punk",     parse("mets du Daft Punk",   pills: pills), "daft punk")
        checkArtist("mets de la jazz",       parse("mets de la jazz",     pills: pills), "jazz")
        checkArtist("joue du rock",          parse("joue du rock",        pills: pills), "rock")
        checkArtist("joue Daft Punk",        parse("joue Daft Punk",      pills: pills), "daft punk")
        checkArtist("play Radiohead",        parse("play Radiohead",      pills: pills), "radiohead")
        checkArtist("lance du Bowie",        parse("lance du Bowie",      pills: pills), "bowie")
        checkArtist("mets les Beatles",      parse("mets les Beatles",    pills: pills), "beatles")
        checkArtist("joue de l'électro",     parse("joue de l'électro",   pills: pills), "electro")

        // ── Music: playlist ───────────────────────────────────────────────────
        checkPlaylist("mets la playlist Workout",   parse("mets la playlist Workout",  pills: pills), "workout")
        checkPlaylist("joue la playlist Jazz",      parse("joue la playlist Jazz",     pills: pills), "jazz")
        checkPlaylist("lance la playlist Summer",   parse("lance la playlist Summer",  pills: pills), "summer")
        checkPlaylist("play playlist My Favs",      parse("play playlist My Favs",     pills: pills), "my favs")
        checkPlaylist("start playlist Chill",       parse("start playlist Chill",      pills: pills), "chill")
        checkPlaylist("mets la playlist Focus",     parse("mets la playlist Focus",    pills: pills), "focus")

        // ── Pill: add ─────────────────────────────────────────────────────────
        check("ajoute GitHub",               parse("ajoute GitHub",        pills: pills), .pillAdd(id: "integration_github"))
        check("ajoute Vercel",               parse("ajoute Vercel",        pills: pills), .pillAdd(id: "integration_vercel"))
        check("active Notion",               parse("active Notion",        pills: pills), .pillAdd(id: "integration_notion"))
        check("add GitHub",                  parse("add GitHub",            pills: pills), .pillAdd(id: "integration_github"))
        check("enable Vercel",               parse("enable Vercel",         pills: pills), .pillAdd(id: "integration_vercel"))
        check("show Resend",                 parse("show Resend",           pills: pills), .pillAdd(id: "integration_resend"))
        check("affiche Notion",              parse("affiche Notion",        pills: pills), .pillAdd(id: "integration_notion"))
        check("ajoute gemini",               parse("ajoute gemini",         pills: pills), .pillAdd(id: "agent_gemini"))
        check("ajoute claude",               parse("ajoute claude",         pills: pills), .pillAdd(id: "integration_claude"))
        check("mets la pilule Gemini",       parse("mets la pilule Gemini", pills: pills), .pillAdd(id: "agent_gemini"))

        // ── Pill: remove ──────────────────────────────────────────────────────
        check("enlève GitHub",               parse("enlève GitHub",        pills: pills), .pillRemove(id: "integration_github"))
        check("enlève Vercel",               parse("enlève Vercel",        pills: pills), .pillRemove(id: "integration_vercel"))
        check("désactive Notion",            parse("désactive Notion",     pills: pills), .pillRemove(id: "integration_notion"))
        check("cache Resend",                parse("cache Resend",          pills: pills), .pillRemove(id: "integration_resend"))
        check("remove GitHub",               parse("remove GitHub",         pills: pills), .pillRemove(id: "integration_github"))
        check("disable Vercel",              parse("disable Vercel",        pills: pills), .pillRemove(id: "integration_vercel"))
        check("hide Notion",                 parse("hide Notion",           pills: pills), .pillRemove(id: "integration_notion"))
        check("enlève stripe",               parse("enlève stripe",         pills: pills), .pillRemove(id: "integration_stripe"))

        // ── Pill: setMain ─────────────────────────────────────────────────────
        check("passe sur Cursor",            parse("passe sur Cursor",         pills: pills), .pillSetMain(id: "agent_cursor"))
        check("switch to Cursor",            parse("switch to Cursor",         pills: pills), .pillSetMain(id: "agent_cursor"))
        check("utilise VS Code",             parse("utilise VS Code",          pills: pills), .pillSetMain(id: "integration_claude"))
        check("passe la pilule principale sur cursor",
              parse("passe la pilule principale sur cursor", pills: pills),
              .pillSetMain(id: "agent_cursor"))
        check("mets Cursor en principal",
              parse("mets Cursor en principal", pills: pills),
              .pillSetMain(id: "agent_cursor"))

        // ── Pill: replace / only ──────────────────────────────────────────────
        check("remplace n8n par github",
              parse("remplace n8n par github", pills: pills),
              .pillReplace(old: "integration_n8n", new: "integration_github"))
        check("garde seulement GitHub et Vercel",
              parse("garde seulement GitHub et Vercel", pills: pills),
              .pillOnly(["integration_github", "integration_vercel"]))

        // ── Unknown: non-pill entities / bare trigger words ───────────────────
        check("unknown command xyz",         parse("unknown command xyz"),     .unknown)
        check("empty",                       parse(""),                        .unknown)
        check("coucou seul",                 parse("coucou"),                  .unknown)
        check("utilise ton cerveau",         parse("utilise ton cerveau", pills: pills), .unknown)
        check("show me",                     parse("show me", pills: pills),   .unknown)

        // ── Normalisation edge cases ──────────────────────────────────────────
        check("MONTE LE SON caps",           parse("MONTE LE SON"),            .musicVolumeUp)
        check("mònte lê sôn diacritics",     parse("mònte lê sôn"),            .musicVolumeUp)
        check("next trailing punct",         parse("next!"),                   .musicNext)

        // Summary
        let total = pass + fail
        if fail == 0 { print("\n\(total)/\(total) passed.") }
        else { print("\n\(fail) FAILED / \(total) total"); exit(1) }
    }

    static func parse(_ s: String, pills: [PillDefinition] = []) -> VoiceIntent {
        IntentParser.parse(s, pills: pills)
    }

    static func check(_ label: String, _ got: VoiceIntent, _ want: VoiceIntent) {
        if got == want {
            print("✓  \(label)"); pass += 1
        } else {
            print("✗  \(label) — got \(got), want \(want)"); fail += 1
        }
    }

    static func checkArtist(_ label: String, _ got: VoiceIntent, _ want: String) {
        if case .musicPlayArtist(let name) = got,
           IntentParser.normalise(name) == want {
            print("✓  \(label)"); pass += 1
        } else {
            print("✗  \(label) — got \(got), want artist '\(want)'"); fail += 1
        }
    }

    static func checkPlaylist(_ label: String, _ got: VoiceIntent, _ want: String) {
        if case .musicPlayPlaylist(let name) = got,
           IntentParser.normalise(name) == want {
            print("✓  \(label)"); pass += 1
        } else {
            print("✗  \(label) — got \(got), want playlist '\(want)'"); fail += 1
        }
    }
}
