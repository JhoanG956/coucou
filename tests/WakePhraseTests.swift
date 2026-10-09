import Foundation

// MARK: - WakePhrase tests (pure functions, no concurrency)

@main
enum WakePhraseTests {

    static var failures = 0

    static func main() {
        // MARK: matchesWake — should trigger
        check("ok coucou",             expected: true,  WakePhrase.matchesWake("ok coucou"))
        check("OK COUCOU",             expected: true,  WakePhrase.matchesWake("OK COUCOU"))
        check("okay coucou",           expected: true,  WakePhrase.matchesWake("okay coucou"))
        check("Okay Coucou",           expected: true,  WakePhrase.matchesWake("Okay Coucou"))
        check("ok cuckoo",             expected: true,  WakePhrase.matchesWake("ok cuckoo"))
        check("ok kuku",               expected: true,  WakePhrase.matchesWake("ok kuku"))
        check("ok cou cou",            expected: true,  WakePhrase.matchesWake("ok cou cou"))
        check("hey coucou",            expected: true,  WakePhrase.matchesWake("hey coucou"))
        check("Hey Coucou",            expected: true,  WakePhrase.matchesWake("Hey Coucou"))
        check("ok coucou add github",  expected: true,  WakePhrase.matchesWake("ok coucou add github"))
        check("ok coucou ouvre figma", expected: true,  WakePhrase.matchesWake("ok coucou ouvre figma"))
        // MARK: matchesWake — should NOT trigger
        check("standalone coucou",       expected: false, WakePhrase.matchesWake("coucou"))
        check("standalone COUCOU",       expected: false, WakePhrase.matchesWake("COUCOU"))
        check("partial coucou ça va",    expected: false, WakePhrase.matchesWake("coucou ça va"))
        check("partial coucou comment",  expected: false, WakePhrase.matchesWake("coucou comment tu vas"))
        check("ok google",               expected: false, WakePhrase.matchesWake("ok google"))
        check("hey siri",                expected: false, WakePhrase.matchesWake("hey siri"))
        check("bonjour coucou",          expected: false, WakePhrase.matchesWake("bonjour coucou"))
        check("okkkk coucou",            expected: false, WakePhrase.matchesWake("okkkk coucou"))
        check("empty string",            expected: false, WakePhrase.matchesWake(""))
        // MARK: stripWakePhrase
        checkEq("strip ok coucou",   WakePhrase.stripWakePhrase("ok coucou ajoute GitHub"),  "ajoute GitHub")
        checkEq("strip hey coucou",  WakePhrase.stripWakePhrase("hey coucou open figma"),    "open figma")
        checkEq("strip ok cuckoo",   WakePhrase.stripWakePhrase("ok cuckoo search"),         "search")
        checkEq("strip okay coucou", WakePhrase.stripWakePhrase("okay coucou translate"),    "translate")
        checkEq("no wake prefix",    WakePhrase.stripWakePhrase("bonjour"),                  "bonjour")
        checkEq("wake phrase only",  WakePhrase.stripWakePhrase("ok coucou"),                "")
        // Summary
        if failures == 0 { print("\n25/25 tests passed.") }
        else { print("\n\(failures) test(s) FAILED."); exit(1) }
    }

    static func check(_ label: String, expected: Bool, _ got: Bool) {
        if got == expected { print("✓  \(label)") }
        else { print("✗  \(label) — expected \(expected), got \(got)"); failures += 1 }
    }

    static func checkEq(_ label: String, _ got: String, _ want: String) {
        if got == want { print("✓  \(label)") }
        else { print("✗  \(label) — got \"\(got)\", want \"\(want)\""); failures += 1 }
    }
}
