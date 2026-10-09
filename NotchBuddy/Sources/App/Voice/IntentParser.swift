#if !APPSTORE
import Foundation

// MARK: - IntentParser

/// Parses a raw voice transcript into a VoiceIntent.
/// Pure Foundation — no AppKit, no AppState, no I/O.
/// Standalone compilable (used directly in test scripts via `swiftc`).
enum IntentParser {

    // MARK: - Public API

    static func parse(_ raw: String, pills: [PillDefinition] = []) -> VoiceIntent {
        let norm  = normalise(raw)
        let words = norm.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return .unknown }

        // ── 1. Explicit music-only patterns ──────────────────────────────────
        if matchesAny(words, in: pausePrefixes)   { return .musicPause }
        if matchesAny(words, in: nextPrefixes)    { return .musicNext }
        if matchesAny(words, in: prevPrefixes)    { return .musicPrevious }
        if matchesAny(words, in: volUpPrefixes)   { return .musicVolumeUp }
        if matchesAny(words, in: volDownPrefixes) { return .musicVolumeDown }

        // ── 2. Volume set: "volume à 50" / "set volume 50" ──────────────────
        if let pct = extractVolume(words) { return .musicSetVolume(pct) }

        // ── 3. "principale/principal" keyword → pillSetMain ──────────────────
        //    "passe la pilule principale sur Cursor"
        if words.contains("principale") || words.contains("principal") {
            if let surIdx = words.firstIndex(of: "sur"), surIdx + 1 < words.count {
                let entity = words[(surIdx+1)...].joined(separator: " ")
                let clean  = stripArticles(entity)
                if !clean.isEmpty,
                   let id = EntityResolver.resolve(clean, from: pills, category: .workspace) {
                    return .pillSetMain(id: id)
                }
            }
        }
        // "mets Cursor en principal" — entity BEFORE "en principal[e]"
        if let enIdx = words.indices.dropLast().first(where: {
            words[$0] == "en" && (words[$0+1] == "principal" || words[$0+1] == "principale")
        }), enIdx > 0 {
            let entity = words[1..<enIdx].joined(separator: " ")   // skip leading verb
            let clean  = stripArticles(entity)
            if !clean.isEmpty,
               let id = EntityResolver.resolve(clean, from: pills, category: .workspace) {
                return .pillSetMain(id: id)
            }
        }

        // ── 4. pillReplace: "remplace n8n par github" ────────────────────────
        if let (old, new) = extractReplace(words, pills: pills) {
            return .pillReplace(old: old, new: new)
        }

        // ── 5. pillOnly: "garde seulement GitHub et Vercel" ──────────────────
        if let ids = extractOnly(words, pills: pills) {
            return .pillOnly(ids)
        }

        // ── 6. Playlist triggers (before generic music so "mets la playlist…" wins) ─
        if let name = extractAfter(words, triggers: playlistTriggers) {
            let clean = stripArticles(name)
            if !clean.isEmpty { return .musicPlayPlaylist(name: clean) }
        }

        // ── 7. pillMain triggers (setMain-only verbs) ────────────────────────
        if let name = extractAfter(words, triggers: pillMainTriggers) {
            let clean = stripArticles(name)
            if !clean.isEmpty {
                let id = EntityResolver.resolve(clean, from: pills, category: .workspace)
                return id != nil ? .pillSetMain(id: id!) : .unknown
            }
        }

        // ── 8. Ambiguous triggers: pill-first, then music ────────────────────
        if let name = extractAfter(words, triggers: musicPillTriggers) {
            let clean = stripArticles(name)
            if !clean.isEmpty {
                // Music service pills → musicPlay
                if let id = EntityResolver.resolve(clean, from: pills),
                   musicServicePillIds.contains(id) {
                    return .musicPlay
                }
                // Workspace pill → pillSetMain
                if let id = EntityResolver.resolve(clean, from: pills, category: .workspace) {
                    return .pillSetMain(id: id)
                }
                // Other pill → pillAdd
                if let id = EntityResolver.resolve(clean, from: pills) {
                    return .pillAdd(id: id)
                }
                // Generic music word → musicPlay
                if musicGenericWords.contains(clean) { return .musicPlay }
                // Not a pill, not generic → artist
                return .musicPlayArtist(name: clean)
            }
        }

        // ── 9. pillRemove triggers ────────────────────────────────────────────
        if let name = extractAfter(words, triggers: pillRemoveTriggers) {
            let clean = stripArticles(name)
            if !clean.isEmpty {
                if let id = EntityResolver.resolve(clean, from: pills) { return .pillRemove(id: id) }
                return .unknown
            }
        }

        // ── 10. pillAdd-only triggers (affiche, show, montre, enable) ─────────
        if let name = extractAfter(words, triggers: pillAddOnlyTriggers) {
            let clean = stripArticles(name)
            if !clean.isEmpty {
                if let id = EntityResolver.resolve(clean, from: pills) { return .pillAdd(id: id) }
                return .unknown
            }
        }

        // ── 11. Generic musicPlay phrases (bare / multi-word) ─────────────────
        if matchesAny(words, in: playPrefixes) { return .musicPlay }

        // Bare single music verb
        if words.count == 1, let v = words.first, bareMusicVerbs.contains(v) {
            return .musicPlay
        }

        return .unknown
    }

    // MARK: - Normalisation

    static func normalise(_ s: String) -> String {
        var r = s.lowercased()
        r = r.replacingOccurrences(of: "'",       with: " ")
        r = r.replacingOccurrences(of: "\u{2019}", with: " ")
        r = r.replacingOccurrences(of: "-",       with: " ")
        r = r.folding(options: .diacriticInsensitive, locale: nil)
        r = r.filter { $0.isLetter || $0.isNumber || $0 == " " }
        return r.split(separator: " ").joined(separator: " ")
    }

    // MARK: - Pattern helpers

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

    private static func stripArticles(_ name: String) -> String {
        let articles: Set<String> = ["du", "de", "la", "le", "les", "des", "l",
                                      "some", "the", "a", "an", "pilule", "pill"]
        var ws = name.split(separator: " ").map(String.init)
        while let first = ws.first, articles.contains(first) { ws.removeFirst() }
        return ws.joined(separator: " ")
    }

    // MARK: - Volume extraction

    private static func extractVolume(_ words: [String]) -> Int? {
        guard words.contains("volume"),
              let numStr = words.last(where: { Int($0) != nil }),
              let pct = Int(numStr), pct >= 0, pct <= 100 else { return nil }
        // Ensure "volume" appears before the number
        guard let volIdx  = words.firstIndex(of: "volume"),
              let numIdx  = words.indices.last(where: { Int(words[$0]) != nil }),
              volIdx < numIdx else { return nil }
        return pct
    }

    // MARK: - pillReplace extraction

    private static func extractReplace(_ words: [String], pills: [PillDefinition]) -> (String, String)? {
        let startTriggers: [[String]] = [["remplace"], ["replace"], ["echange"], ["swap"], ["change"]]
        let separators = ["par", "for", "contre", "with", "by"]
        for start in startTriggers {
            guard contains(words, sequence: start) else { continue }
            let rest = Array(words[start.count...])
            for sep in separators {
                guard let sepIdx = rest.firstIndex(of: sep), sepIdx > 0, sepIdx < rest.count - 1 else { continue }
                let e1 = stripArticles(rest[..<sepIdx].joined(separator: " "))
                let e2 = stripArticles(rest[(sepIdx+1)...].joined(separator: " "))
                if let id1 = EntityResolver.resolve(e1, from: pills),
                   let id2 = EntityResolver.resolve(e2, from: pills) {
                    return (id1, id2)
                }
            }
        }
        return nil
    }

    // MARK: - pillOnly extraction

    private static func extractOnly(_ words: [String], pills: [PillDefinition]) -> [String]? {
        let starts: [[String]] = [["garde", "seulement"], ["keep", "only"], ["garder", "seulement"]]
        for start in starts {
            guard contains(words, sequence: start) else { continue }
            let rest = Array(words[start.count...])
            var parts: [[String]] = []
            var cur:   [String]  = []
            for w in rest {
                if w == "et" || w == "and" { if !cur.isEmpty { parts.append(cur); cur = [] } }
                else { cur.append(w) }
            }
            if !cur.isEmpty { parts.append(cur) }
            var ids: [String] = []
            for part in parts {
                let clean = stripArticles(part.joined(separator: " "))
                if !clean.isEmpty, let id = EntityResolver.resolve(clean, from: pills) {
                    ids.append(id)
                }
            }
            if !ids.isEmpty { return ids }
        }
        return nil
    }

    // MARK: - Keyword tables

    private static let pausePrefixes: [[String]] = [
        ["pause"], ["stop"], ["stoppe"],
        ["mets", "en", "pause"], ["met", "en", "pause"],
        ["arrete", "la", "musique"], ["arrete", "la", "chanson"],
        ["arrete", "la", "lecture"],
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
        ["balance", "la", "playlist"],
    ]

    // SetMain-only verbs — no fall-through to music on miss
    private static let pillMainTriggers: [[String]] = [
        ["passe", "sur"], ["change", "pour"], ["met", "sur"], ["mets", "sur"],
        ["switch", "to"], ["set", "main", "to"], ["change", "to"],
        ["utilise"], ["use"],
    ]

    // Ambiguous verbs — pill first, then music
    private static let musicPillTriggers: [[String]] = [
        ["joue"], ["play"], ["mets"], ["met"], ["lance"], ["start"],
        ["demarre"], ["balance"], ["envoie"], ["reprends"], ["resume"],
    ]

    // Pill-add-only verbs
    private static let pillAddOnlyTriggers: [[String]] = [
        ["active"], ["affiche"], ["montre"], ["rajoute"], ["ajoute"],
        ["add"], ["enable"], ["show"], ["activate"],
    ]

    private static let pillRemoveTriggers: [[String]] = [
        ["enleve"], ["supprime"], ["desactive"], ["cache"], ["retire"], ["efface"],
        ["remove"], ["disable"], ["hide"], ["delete"],
    ]

    // Bare music verbs (single word → musicPlay)
    private static let bareMusicVerbs: Set<String> = [
        "joue", "lance", "play", "start", "demarre", "balance",
        "reprends", "resume",
    ]

    // Generic musicPlay nouns (entity after verb → musicPlay, not artist)
    private static let musicGenericWords: Set<String> = [
        "musique", "son", "music", "audio", "chanson", "chansons",
    ]

    // Music-service pill ids — pill detected but route to musicPlay
    private static let musicServicePillIds: Set<String> = [
        "integration_music", "integration_spotify",
    ]

    private static let playPrefixes: [[String]] = [
        ["lance", "la", "musique"], ["lance", "la", "chanson"],
        ["reprends", "la", "musique"], ["reprends"],
        ["play", "music"], ["start", "music"], ["resume", "music"], ["resume"],
        ["play", "some", "music"],
        ["balance", "de", "la", "musique"], ["balance", "la", "musique"],
        ["envoie", "de", "la", "musique"],
        ["mets", "de", "la", "musique"], ["mets", "du", "son"],
    ]
}
#endif
