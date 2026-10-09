#if !APPSTORE
import Foundation

// MARK: - EntityResolver

/// Fuzzy-matches a voice entity name against a pill list.
/// Uses Levenshtein distance ≤ 2 (≤ 1 for short queries).
/// No AppKit — uses PillDefinition/PillCategory from CoucouKit.
enum EntityResolver {

    // MARK: - Public API

    /// Resolve `query` to a pill id from `pills`.
    /// Pass `category` to restrict to workspace pills (for main-pill commands).
    /// Returns nil when no match within tolerance, or when the match is ambiguous.
    static func resolve(
        _ query: String,
        from pills: [PillDefinition],
        category: PillCategory? = nil
    ) -> String? {
        let q = IntentParser.normalise(query)
        var pool = pills
        if let cat = category { pool = pool.filter { $0.category == cat } }
        guard !pool.isEmpty, !q.isEmpty else { return nil }

        // Exact match wins immediately (no tolerance needed)
        if let exact = pool.first(where: { IntentParser.normalise($0.name) == q }) {
            return exact.id
        }

        var best:       (id: String, dist: Int)?
        var secondBest: (id: String, dist: Int)?

        for def in pool {
            let target = IntentParser.normalise(def.name)
            let d = levenshtein(q, target)
            if d < (best?.dist ?? Int.max) {
                secondBest = best
                best = (def.id, d)
            } else if d < (secondBest?.dist ?? Int.max) {
                secondBest = (def.id, d)
            }
        }

        guard let winner = best else { return nil }

        // Tolerance: 1 edit for short queries (≤ 4 chars), 2 for longer
        let tolerance = q.count <= 4 ? 1 : 2
        guard winner.dist <= tolerance else { return nil }

        // Ambiguity: reject if runner-up is also within tolerance
        if let runner = secondBest, runner.dist <= tolerance { return nil }

        return winner.id
    }

    // MARK: - Levenshtein distance

    /// Standard Wagner–Fischer DP. Operates on Character arrays.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let ac = Array(a), bc = Array(b)
        let m = ac.count, n = bc.count
        if m == 0 { return n }
        if n == 0 { return m }
        var row = Array(0...n)
        for i in 1...m {
            var prev = row[0]
            row[0] = i
            for j in 1...n {
                let temp = row[j]
                row[j] = ac[i-1] == bc[j-1]
                    ? prev
                    : Swift.min(prev, Swift.min(row[j], row[j-1])) + 1
                prev = temp
            }
        }
        return row[n]
    }
}
#endif
