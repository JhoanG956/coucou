import Foundation

// MARK: - EntityResolver tests

@main
enum EntityResolverTests {

    static var pass = 0
    static var fail = 0

    static let pills: [PillDefinition] = [
        .init(id: "integration_github",  name: "GitHub",      color: "#F4505E",
              category: .service,   subtitle: "Integration", source: .n8n),
        .init(id: "integration_vercel",  name: "Vercel",      color: "#7C5CFF",
              category: .service,   subtitle: "Integration", source: .n8n),
        .init(id: "integration_notion",  name: "Notion",      color: "#8C8C8C",
              category: .service,   subtitle: "Integration", source: .n8n),
        .init(id: "integration_resend",  name: "Resend",      color: "#22C55E",
              category: .service,   subtitle: "Integration", source: .n8n),
        .init(id: "integration_stripe",  name: "Stripe",      color: "#0570DE",
              category: .service,   subtitle: "Integration", source: .n8n),
        .init(id: "ai_anthropic",        name: "Anthropic",   color: "#E07950",
              category: .ai,        subtitle: "Chat",        source: .n8n),
        .init(id: "agent_cursor",        name: "Cursor",      color: "#C0C4CC",
              category: .workspace, subtitle: "Integration", source: .agent),
        .init(id: "integration_claude",  name: "VS Code",     color: "#F5F6F8",
              category: .workspace, subtitle: "Integration", source: .claudeCode),
        .init(id: "integration_n8n",     name: "n8n",         color: "#F29B38",
              category: .service,   subtitle: "Integration", source: .n8n),
    ]

    static func main() {

        // ── Exact matches ─────────────────────────────────────────────────────
        check("GitHub exact",     resolve("GitHub"),     "integration_github")
        check("Vercel exact",     resolve("Vercel"),     "integration_vercel")
        check("Notion exact",     resolve("Notion"),     "integration_notion")
        check("Resend exact",     resolve("Resend"),     "integration_resend")
        check("Stripe exact",     resolve("Stripe"),     "integration_stripe")
        check("Anthropic exact",  resolve("Anthropic"),  "ai_anthropic")
        check("Cursor exact",     resolve("Cursor"),     "agent_cursor")
        check("n8n exact",        resolve("n8n"),        "integration_n8n")

        // ── Case/diacritic insensitive ────────────────────────────────────────
        check("GITHUB caps",      resolve("GITHUB"),     "integration_github")
        check("github lower",     resolve("github"),     "integration_github")
        check("vèrcel diacritic", resolve("vèrcel"),     "integration_vercel")
        check("nótion diacritic", resolve("nótion"),     "integration_notion")

        // ── Levenshtein ≤ 2 ──────────────────────────────────────────────────
        check("Githb (1 del)",    resolve("Githb"),      "integration_github")
        check("Notoon (1 sub)",   resolve("Notoon"),     "integration_notion")
        check("Vecel (1 del)",    resolve("Vecel"),      "integration_vercel")
        check("Rêsend (1 sub)",   resolve("Rêsend"),     "integration_resend")

        // ── No match (distance > tolerance) ──────────────────────────────────
        checkNil("xyz → nil",     resolve("xyz"))
        checkNil("empty → nil",   resolve(""))
        checkNil("Gitxyz far",    resolve("Gitxyz"))

        // ── Category filter: workspace only ──────────────────────────────────
        check("Cursor workspace", resolve("Cursor",  cat: .workspace), "agent_cursor")
        check("VS Code workspace",resolve("VS Code", cat: .workspace), "integration_claude")
        checkNil("GitHub not workspace", resolve("GitHub", cat: .workspace))

        // ── Levenshtein distance ──────────────────────────────────────────────
        let lev = EntityResolver.levenshtein
        checkDist("abc/abc",     lev("abc",    "abc"),    0)
        checkDist("abc/abd",     lev("abc",    "abd"),    1)
        checkDist("kitten/sitting", lev("kitten","sitting"), 3)
        checkDist("empty/abc",   lev("",       "abc"),    3)
        checkDist("abc/empty",   lev("abc",    ""),       3)

        // Summary
        let total = pass + fail
        if fail == 0 { print("\n\(total)/\(total) passed.") }
        else { print("\n\(fail) FAILED / \(total) total"); exit(1) }
    }

    // MARK: - Helpers

    static func resolve(_ query: String, cat: PillCategory? = nil) -> String? {
        EntityResolver.resolve(query, from: pills, category: cat)
    }

    static func check(_ label: String, _ got: String?, _ want: String) {
        if got == want {
            print("✓  \(label)"); pass += 1
        } else {
            print("✗  \(label) — got \(got ?? "nil"), want \(want)"); fail += 1
        }
    }

    static func checkNil(_ label: String, _ got: String?) {
        if got == nil {
            print("✓  \(label)"); pass += 1
        } else {
            print("✗  \(label) — expected nil, got \(got!)"); fail += 1
        }
    }

    static func checkDist(_ label: String, _ got: Int, _ want: Int) {
        if got == want {
            print("✓  lev(\(label)) = \(want)"); pass += 1
        } else {
            print("✗  lev(\(label)) — got \(got), want \(want)"); fail += 1
        }
    }
}
