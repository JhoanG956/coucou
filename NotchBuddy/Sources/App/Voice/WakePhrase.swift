import Foundation

// MARK: - WakePhrase
// Pure functions — no Speech or AVFoundation dependencies.
// Compiled into both the app and standalone test scripts.

enum WakePhrase {

    // MARK: - Public API

    struct SplitResult {
        let matched: Bool
        let command: String   // words after the LAST wake phrase occurrence (lowercased, normalised)
    }

    /// Scans `raw` for a wake phrase at a word boundary (anywhere in the transcript,
    /// not just the start). Returns the text following the **last** occurrence as the command.
    ///
    /// Accepted patterns (case-insensitive, after phonetic normalisation):
    /// - "ok coucou" and variants: "okay coucou", "ok cuckoo", "ok kuku", "ok cou cou" …
    /// - "hey coucou"
    ///
    /// Word-boundary search means "euh ok coucou add" matches and returns "add".
    /// Standalone "coucou" never matches (no preceding "ok"/"hey").
    static func split(_ raw: String) -> SplitResult {
        // 1. Strip punctuation, lowercase, normalise phonetic variants
        let normalised = normalise(raw)

        // 2. Split into words
        let words = normalised.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !words.isEmpty else { return SplitResult(matched: false, command: "") }

        // 3. Wake phrase word-arrays
        let patterns: [[String]] = [["ok", "coucou"], ["hey", "coucou"]]

        // 4. Find LAST occurrence of any pattern
        var lastMatchEnd: Int? = nil   // word index immediately after the matched pattern

        for pattern in patterns {
            var i = 0
            while i <= words.count - pattern.count {
                if Array(words[i ..< i + pattern.count]) == pattern {
                    let end = i + pattern.count
                    if lastMatchEnd == nil || end > lastMatchEnd! { lastMatchEnd = end }
                    i = end   // resume search after this match
                } else {
                    i += 1
                }
            }
        }

        guard let end = lastMatchEnd else { return SplitResult(matched: false, command: "") }

        let commandWords = Array(words[end...])
        return SplitResult(matched: true, command: commandWords.joined(separator: " "))
    }

    // MARK: - Internal

    /// Lowercase, strip punctuation, normalise phonetic / spelling variants.
    static func normalise(_ raw: String) -> String {
        var t = raw.lowercased()
            .components(separatedBy: .punctuationCharacters)
            .joined()
            .trimmingCharacters(in: .whitespaces)
        t = t
            .replacingOccurrences(of: "cuckoo",  with: "coucou")
            .replacingOccurrences(of: "kuku",    with: "coucou")
            .replacingOccurrences(of: "kucou",   with: "coucou")
            .replacingOccurrences(of: "cou cou", with: "coucou")
            .replacingOccurrences(of: "okay",    with: "ok")
            .replacingOccurrences(of: "o k ",    with: "ok ")
        while t.contains("  ") { t = t.replacingOccurrences(of: "  ", with: " ") }
        return t
    }
}
