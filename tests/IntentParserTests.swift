import Foundation

// MARK: - IntentParser tests
// Compiled standalone: swift <sources…> tests/IntentParserTests.swift

@main
enum IntentParserTests {

    static var pass = 0
    static var fail = 0

    static func main() {
        // Provide a minimal pill list for pill-intent tests
        let pills = [
            PillDefinition(id: "integration_github",  name: "GitHub",      color: "#F4505E",
                           category: .service,   subtitle: "Integration", source: .n8n),
            PillDefinition(id: "integration_vercel",  name: "Vercel",      color: "#7C5CFF",
                           category: .service,   subtitle: "Integration", source: .n8n),
            PillDefinition(id: "integration_notion",  name: "Notion",      color: "#8C8C8C",
                           category: .service,   subtitle: "Integration", source: .n8n),
            PillDefinition(id: "integration_resend",  name: "Resend",      color: "#22C55E",
                           category: .service,   subtitle: "Integration", source: .n8n),
            PillDefinition(id: "agent_cursor",        name: "Cursor",      color: "#C0C4CC",
                           category: .workspace, subtitle: "Integration", source: .agent),
            PillDefinition(id: "integration_claude",  name: "VS Code",     color: "#F5F6F8",
                           category: .workspace, subtitle: "Integration", source: .claudeCode),
        ]

        // ── Music: play/pause ─────────────────────────────────────────────────
        check("pause",                       parse("pause"),                   .musicPause)
        check("stop",                        parse("stop"),                    .musicPause)
        check("stoppe",                      parse("stoppe"),                  .musicPause)
        check("mets en pause",               parse("mets en pause"),           .musicPause)
        check("arrête la musique",           parse("arrête la musique"),       .musicPause)
        check("PAUSE",                       parse("PAUSE"),                   .musicPause)
        check("lance la musique",            parse("lance la musique"),        .musicPlay)
        check("reprends",                    parse("reprends"),                .musicPlay)
        check("reprends la musique",         parse("reprends la musique"),     .musicPlay)
        check("play music",                  parse("play music"),              .musicPlay)
        check("resume music",                parse("resume music"),            .musicPlay)

        // ── Music: next/previous ──────────────────────────────────────────────
        check("suivant",                     parse("suivant"),                 .musicNext)
        check("morceau suivant",             parse("morceau suivant"),         .musicNext)
        check("chanson suivante",            parse("chanson suivante"),        .musicNext)
        check("next",                        parse("next"),                    .musicNext)
        check("next track",                  parse("next track"),              .musicNext)
        check("skip",                        parse("skip"),                    .musicNext)
        check("précédent",                   parse("précédent"),               .musicPrevious)
        check("morceau précédent",           parse("morceau précédent"),      .musicPrevious)
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

        // ── Music: artist ─────────────────────────────────────────────────────
        checkArtist("mets du Daft Punk",     parse("mets du Daft Punk"),      "daft punk")
        checkArtist("mets de la jazz",       parse("mets de la jazz"),        "jazz")
        checkArtist("joue du rock",          parse("joue du rock"),           "rock")
        checkArtist("joue Daft Punk",        parse("joue Daft Punk"),         "daft punk")
        checkArtist("play Radiohead",        parse("play Radiohead"),         "radiohead")
        checkArtist("play some jazz",        parse("play some jazz"),         "jazz")
        checkArtist("lance du Bowie",        parse("lance du Bowie"),         "bowie")
        checkArtist("mets les Beatles",      parse("mets les Beatles"),       "beatles")
        checkArtist("joue de l'électro",     parse("joue de l'électro"),      "electro")

        // ── Music: playlist ───────────────────────────────────────────────────
        checkPlaylist("mets la playlist Workout",   parse("mets la playlist Workout"),  "workout")
        checkPlaylist("joue la playlist Jazz",      parse("joue la playlist Jazz"),     "jazz")
        checkPlaylist("lance la playlist Summer",   parse("lance la playlist Summer"),  "summer")
        checkPlaylist("play playlist My Favs",      parse("play playlist My Favs"),     "my favs")
        checkPlaylist("start playlist Chill",       parse("start playlist Chill"),      "chill")

        // ── Pill: add ─────────────────────────────────────────────────────────
        check("ajoute GitHub",               parse("ajoute GitHub", pills: pills),
              .pillAdd(id: "integration_github"))
        check("ajoute Vercel",               parse("ajoute Vercel", pills: pills),
              .pillAdd(id: "integration_vercel"))
        check("active Notion",               parse("active Notion", pills: pills),
              .pillAdd(id: "integration_notion"))
        check("add GitHub",                  parse("add GitHub", pills: pills),
              .pillAdd(id: "integration_github"))
        check("enable Vercel",               parse("enable Vercel", pills: pills),
              .pillAdd(id: "integration_vercel"))
        check("show Resend",                 parse("show Resend", pills: pills),
              .pillAdd(id: "integration_resend"))
        check("affiche Notion",              parse("affiche Notion", pills: pills),
              .pillAdd(id: "integration_notion"))

        // ── Pill: remove ──────────────────────────────────────────────────────
        check("enlève GitHub",               parse("enlève GitHub", pills: pills),
              .pillRemove(id: "integration_github"))
        check("enlève Vercel",               parse("enlève Vercel", pills: pills),
              .pillRemove(id: "integration_vercel"))
        check("désactive Notion",            parse("désactive Notion", pills: pills),
              .pillRemove(id: "integration_notion"))
        check("cache Resend",                parse("cache Resend", pills: pills),
              .pillRemove(id: "integration_resend"))
        check("remove GitHub",               parse("remove GitHub", pills: pills),
              .pillRemove(id: "integration_github"))
        check("disable Vercel",              parse("disable Vercel", pills: pills),
              .pillRemove(id: "integration_vercel"))
        check("hide Notion",                 parse("hide Notion", pills: pills),
              .pillRemove(id: "integration_notion"))

        // ── Pill: set main ────────────────────────────────────────────────────
        check("passe sur Cursor",            parse("passe sur Cursor", pills: pills),
              .pillSetMain(id: "agent_cursor"))
        check("switch to Cursor",            parse("switch to Cursor", pills: pills),
              .pillSetMain(id: "agent_cursor"))
        check("utilise VS Code",             parse("utilise VS Code", pills: pills),
              .pillSetMain(id: "integration_claude"))

        // ── Unknown ───────────────────────────────────────────────────────────
        check("unknown command xyz",         parse("unknown command xyz"),     .unknown)
        check("empty",                       parse(""),                        .unknown)
        check("coucou seul",                 parse("coucou"),                  .unknown)

        // ── Normalisation edge cases ──────────────────────────────────────────
        check("MONTE LE SON caps",           parse("MONTE LE SON"),            .musicVolumeUp)
        check("mònte lê sôn diacritics",     parse("mònte lê sôn"),            .musicVolumeUp)
        check("next trailing punct",         parse("next!"),                   .musicNext)

        // Summary
        let total = pass + fail
        if fail == 0 { print("\n\(total)/\(total) passed.") }
        else { print("\n\(fail) FAILED / \(total) total"); exit(1) }
    }

    // MARK: - Helpers

    static func parse(_ s: String, pills: [PillDefinition] = []) -> VoiceIntent {
        IntentParser.parse(s, pills: pills)
    }

    static func check(_ label: String, _ got: VoiceIntent, _ want: VoiceIntent) {
        if got == want {
            print("✓  \(label)")
            pass += 1
        } else {
            print("✗  \(label) — got \(got), want \(want)")
            fail += 1
        }
    }

    static func checkArtist(_ label: String, _ got: VoiceIntent, _ want: String) {
        if case .musicPlayArtist(let name) = got,
           IntentParser.normalise(name) == want {
            print("✓  \(label)")
            pass += 1
        } else {
            print("✗  \(label) — got \(got), want artist '\(want)'")
            fail += 1
        }
    }

    static func checkPlaylist(_ label: String, _ got: VoiceIntent, _ want: String) {
        if case .musicPlayPlaylist(let name) = got,
           IntentParser.normalise(name) == want {
            print("✓  \(label)")
            pass += 1
        } else {
            print("✗  \(label) — got \(got), want playlist '\(want)'")
            fail += 1
        }
    }
}
