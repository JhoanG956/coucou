import Foundation

// MARK: - WakePhrase
// Pure functions — no Speech or AVFoundation dependencies.
// Compiled into both the app and standalone test scripts.

enum WakePhrase {

    /// Returns `true` when `raw` contains a recognised wake pattern.
    ///
    /// Accepted patterns (case-insensitive, after phonetic normalisation):
    /// - "ok coucou" and variants: "okay coucou", "ok cuckoo", "ok kuku" …
    /// - "hey coucou"
    ///
    /// The match may be followed by command words ("ok coucou add GitHub").
    ///
    /// Intentionally excluded:
    /// - Standalone "coucou" — partial results arrive word-by-word, so the
    ///   recogniser emits "coucou" before completing "coucou ça va", causing
    ///   false wakes.
    /// - "dis coucou" — French ambiguity: "dis coucou à Marie" = "say hi to Marie".
    static func matchesWake(_ raw: String) -> Bool {
        // 1. Lower-case and strip punctuation
        var text = raw.lowercased()
            .components(separatedBy: .punctuationCharacters)
            .joined()
            .trimmingCharacters(in: .whitespaces)

        // 2. Normalise common phonetic / spelling variants
        text = text
            .replacingOccurrences(of: "cuckoo",  with: "coucou")
            .replacingOccurrences(of: "kuku",    with: "coucou")
            .replacingOccurrences(of: "kucou",   with: "coucou")
            .replacingOccurrences(of: "cou cou", with: "coucou")
            .replacingOccurrences(of: "okay",    with: "ok")
            .replacingOccurrences(of: "o k ",    with: "ok ")
        while text.contains("  ") { text = text.replacingOccurrences(of: "  ", with: " ") }

        // 3. Prefix-based patterns (may be followed by command words).
        let wakePrefixes = ["ok coucou", "hey coucou"]
        for prefix in wakePrefixes {
            if text == prefix               { return true }
            if text.hasPrefix(prefix + " ") { return true }
        }
        return false
    }

    /// Strip the wake phrase from the start of a transcript, returning the remainder.
    static func stripWakePhrase(_ raw: String) -> String {
        let lower = raw.lowercased()
        let phrases = ["ok coucou", "okay coucou", "ok cuckoo", "ok kuku",
                       "hey coucou", "coucou"]
        for phrase in phrases where lower.hasPrefix(phrase) {
            return String(raw.dropFirst(phrase.count))
                .trimmingCharacters(in: .whitespaces)
        }
        return raw
    }
}
