#if !APPSTORE
import Foundation

// MARK: - IntentParser

/// Parses a raw voice transcript into a VoiceIntent.
/// Pure Foundation — no AppKit, no AppState, no I/O.
/// Standalone compilable (used directly in test scripts via `swift`).
enum IntentParser {

    // MARK: - Public API

    /// Parse `raw` into the most specific matching VoiceIntent.
    /// Pill intents are resolved against `pills`; pass `PillCatalog.available` in production.
    static func parse(_ raw: String, pills: [PillDefinition] = []) -> VoiceIntent {
        let norm  = normalise(raw)
        let words = norm.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return .unknown }

        // ── Music: pause/stop ─────────────────────────────────────────────────
        if matchesAny(words, in: pausePrefixes) { return .musicPause }

        // ── Music: next ───────────────────────────────────────────────────────
        if matchesAny(words, in: nextPrefixes) { return .musicNext }

        // ── Music: previous ───────────────────────────────────────────────────
        if matchesAny(words, in: prevPrefixes) { return .musicPrevious }

        // ── Music: volume up ──────────────────────────────────────────────────
        if matchesAny(words, in: volUpPrefixes) { return .musicVolumeUp }

        // ── Music: volume down ────────────────────────────────────────────────
        if matchesAny(words, in: volDownPrefixes) { return .musicVolumeDown }

        // ── Music: playlist (more specific — check before generic play/artist) ─
        if let name = extractAfter(words, triggers: playlistTriggers) {
            let clean = stripArticles(name)
            if !clean.isEmpty { return .musicPlayPlaylist(name: clean) }
        }

        // ── Music: generic play phrases (no entity — "lance la musique") ──────
        // Check BEFORE artist triggers so "play music" → musicPlay not artist.
        if matchesAny(words, in: playPrefixes) { return .musicPlay }

        // ── Music: artist (entity follows trigger) ────────────────────────────
        // Longer triggers tried first to avoid "joue" eating "joue la playlist"
        if let name = extractAfter(words, triggers: artistTriggers) {
            let clean = stripArticles(name)
            if !clean.isEmpty { return .musicPlayArtist(name: clean) }
        }
        // Bare verb with nothing after — generic play
        if words.count == 1,
           let v = words.first,
           ["joue", "lance", "play", "start", "demarre"].contains(v) {
            return .musicPlay
        }

        // ── Pill: set main workspace ──────────────────────────────────────────
        if let name = extractAfter(words, triggers: pillMainTriggers) {
            let clean = stripArticles(name)
            if !clean.isEmpty {
                let id = EntityResolver.resolve(clean, from: pills, category: .workspace)
                return id != nil ? .pillSetMain(id: id!) : .unknown
            }
        }

        // ── Pill: remove ──────────────────────────────────────────────────────
        if let name = extractAfter(words, triggers: pillRemoveTriggers) {
            let clean = stripArticles(name)
            if !clean.isEmpty {
                let id = EntityResolver.resolve(clean, from: pills)
                return id != nil ? .pillRemove(id: id!) : .unknown
            }
        }

        // ── Pill: add ─────────────────────────────────────────────────────────
        if let name = extractAfter(words, triggers: pillAddTriggers) {
            let clean = stripArticles(name)
            if !clean.isEmpty {
                let id = EntityResolver.resolve(clean, from: pills)
                return id != nil ? .pillAdd(id: id!) : .unknown
            }
        }

        return .unknown
    }

    // MARK: - Normalisation

    /// Lowercase, strip diacritics, apostrophes/hyphens → space, strip non-alpha/digit/space.
    static func normalise(_ s: String) -> String {
        var r = s.lowercased()
        r = r.replacingOccurrences(of: "'", with: " ")    // apostrophe
        r = r.replacingOccurrences(of: "\u{2019}", with: " ")  // right single quotation mark
        r = r.replacingOccurrences(of: "-", with: " ")
        r = r.folding(options: .diacriticInsensitive, locale: nil)
        r = r.filter { $0.isLetter || $0.isNumber || $0 == " " }
        return r.split(separator: " ").joined(separator: " ")
    }

    // MARK: - Pattern helpers

    /// True if `words` contains any entry in `table` as a contiguous word-sequence.
    private static func matchesAny(_ words: [String], in table: [[String]]) -> Bool {
        table.contains { contains(words, sequence: $0) }
    }

    private static func contains(_ words: [String], sequence seq: [String]) -> Bool {
        guard seq.count <= words.count else { return false }
        for i in 0...(words.count - seq.count) {
            if words[i..<(i + seq.count)].elementsEqual(seq) { return true }
        }
        return false
    }

    /// Returns the entity text following the first matching trigger (longest wins).
    private static func extractAfter(_ words: [String], triggers: [[String]]) -> String? {
        let sorted = triggers.sorted { $0.count > $1.count }
        for trigger in sorted {
            guard trigger.count < words.count else { continue }
            for i in 0...(words.count - trigger.count) {
                if words[i..<(i + trigger.count)].elementsEqual(trigger) {
                    let tail = words[(i + trigger.count)...].joined(separator: " ")
                    if !tail.isEmpty { return tail }
                }
            }
        }
        return nil
    }

    /// Strip French/English articles from the start of a normalised entity name.
    private static func stripArticles(_ name: String) -> String {
        let articles: Set<String> = ["du", "de", "la", "le", "les", "des", "l",
                                      "some", "the", "a", "an"]
        var words = name.split(separator: " ").map(String.init)
        while let first = words.first, articles.contains(first) { words.removeFirst() }
        return words.joined(separator: " ")
    }

    // MARK: - Music keyword tables
    // Each entry is a sequence of normalised words to match contiguously.

    private static let pausePrefixes: [[String]] = [
        ["pause"], ["stop"], ["stoppe"],
        ["mets", "en", "pause"], ["met", "en", "pause"],
        ["arrete", "la", "musique"], ["arrete", "la", "chanson"],
    ]

    private static let nextPrefixes: [[String]] = [
        ["morceau", "suivant"], ["chanson", "suivante"], ["suivant"], ["prochain"],
        ["next", "track"], ["next", "song"], ["next"], ["skip"],
    ]

    private static let prevPrefixes: [[String]] = [
        ["morceau", "precedent"], ["chanson", "precedente"], ["precedent"], ["en", "arriere"],
        ["previous", "track"], ["previous", "song"], ["previous"], ["back"],
    ]

    private static let volUpPrefixes: [[String]] = [
        ["monte", "le", "son"], ["monte", "le", "volume"],
        ["augmente", "le", "son"], ["augmente", "le", "volume"],
        ["plus", "fort"], ["volume", "up"], ["louder"], ["turn", "up"],
    ]

    private static let volDownPrefixes: [[String]] = [
        ["baisse", "le", "son"], ["baisse", "le", "volume"],
        ["diminue", "le", "son"], ["diminue", "le", "volume"],
        ["moins", "fort"], ["volume", "down"], ["quieter"], ["turn", "down"],
    ]

    private static let playlistTriggers: [[String]] = [
        ["joue", "la", "playlist"], ["lance", "la", "playlist"],
        ["mets", "la", "playlist"], ["demarre", "la", "playlist"],
        ["play", "playlist"], ["start", "playlist"],
    ]

    // Artist triggers; article stripping handles "du/de la" extraction.
    private static let artistTriggers: [[String]] = [
        ["joue"], ["play"], ["mets"], ["lance"], ["demarre"],
    ]

    private static let playPrefixes: [[String]] = [
        ["lance", "la", "musique"], ["lance", "la", "chanson"],
        ["reprends", "la", "musique"], ["reprends"],
        ["play", "music"], ["start", "music"], ["resume", "music"], ["resume"],
        ["play", "some", "music"],
    ]

    // MARK: - Pill keyword tables

    private static let pillAddTriggers: [[String]] = [
        ["ajoute"], ["active"], ["affiche"], ["montre"], ["rajoute"],
        ["add"], ["enable"], ["show"], ["activate"],
    ]

    private static let pillRemoveTriggers: [[String]] = [
        ["enleve"], ["supprime"], ["desactive"], ["cache"], ["retire"], ["efface"],
        ["remove"], ["disable"], ["hide"], ["delete"],
    ]

    private static let pillMainTriggers: [[String]] = [
        ["passe", "sur"], ["change", "pour"], ["met", "sur"], ["mets", "sur"],
        ["utilise"], ["switch", "to"], ["use"], ["set", "main", "to"], ["change", "to"],
    ]
}
#endif
