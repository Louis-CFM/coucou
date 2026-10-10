import Foundation

// A colour of the user's own for each pill's Mochi (CoucouKit/PillColors.swift).
// Mirrors windows/tests/pill-colors.test.mjs so every platform reads the same
// preference the same way.

@main
enum PillColorsTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static let vsCode = "#F5F6F8"
    static let teal   = "#2DD4BF"

    static func main() {
        print("PillColors.normalized — #RRGGBB in upper case")
        check("lower case → upper",      PillColors.normalized("#2dd4bf") == teal)
        check("no # → #",                PillColors.normalized("2DD4BF") == teal)
        check("spaces around → trimmed", PillColors.normalized("  #2DD4BF ") == teal)
        for bad in ["", "#2DD4B", "#2DD4BFF", "#GGGGGG", "teal", "rgb(1,2,3)", "#２DD4BF"] {
            check("'\(bad)' → nil", PillColors.normalized(bad) == nil)
        }
        check("nil → nil", PillColors.normalized(nil) == nil)

        print("PillColors.palette — the ten colours Windows and Linux offer too")
        check("same list as PILL_PALETTE", PillColors.palette == [
            "#F5F6F8", "#F4505E", "#F29B38", "#FACC15", "#4ADE80",
            "#2DD4BF", "#38BDF8", "#818CF8", "#C084FC", "#E879F9",
        ])
        check("all different", Set(PillColors.palette).count == PillColors.palette.count)
        check("all written #RRGGBB", PillColors.palette.allSatisfy { PillColors.normalized($0) == $0 })

        print("PillColors.parsed — keeps what is a colour, drops the rest")
        let mixed: [String: Any] = [
            "integration_claude": "#2dd4bf", "agent_cursor": "blue", "": "#FFFFFF",
            "agent_new": "#abcdef", "n": 3,
        ]
        check("colours kept, junk dropped",
              PillColors.parsed(mixed) == ["integration_claude": teal, "agent_new": "#ABCDEF"])
        check("nil → empty",            PillColors.parsed(nil).isEmpty)
        check("a string → empty",       PillColors.parsed("x").isEmpty)
        check("an array → empty",       PillColors.parsed(["#2DD4BF"]).isEmpty)

        print("PillColors.color — the user's colour, else the catalog's")
        check("no preference → catalog",
              PillColors.color(for: "integration_claude", catalogColor: vsCode, in: [:]) == vsCode)
        check("picked → picked",
              PillColors.color(for: "integration_claude", catalogColor: vsCode,
                               in: ["integration_claude": "#2dd4bf"]) == teal)
        check("not a colour → catalog",
              PillColors.color(for: "integration_claude", catalogColor: vsCode,
                               in: ["integration_claude": "nope"]) == vsCode)
        check("another pill's colour → catalog",
              PillColors.color(for: "agent_cursor", catalogColor: "#C0C4CC",
                               in: ["integration_claude": teal]) == "#C0C4CC")

        print("PillColors.picking — stores a colour; the default, nothing or junk clears it")
        let before = ["agent_cursor": "#F4505E"]
        let picked = PillColors.picking("#2dd4bf", for: "integration_claude", catalogColor: vsCode, in: before)
        check("picked is stored",
              picked == ["agent_cursor": "#F4505E", "integration_claude": teal])
        check("nil clears",
              PillColors.picking(nil, for: "integration_claude", catalogColor: vsCode, in: picked) == before)
        check("the catalog colour clears",
              PillColors.picking("#f5f6f8", for: "integration_claude", catalogColor: vsCode, in: picked) == before)
        check("junk clears",
              PillColors.picking("teal", for: "integration_claude", catalogColor: vsCode, in: picked) == before)

        print("PillColors.stored — UserDefaults key pillColors")
        UserDefaults.standard.removeObject(forKey: "pillColors")
        check("missing → empty", PillColors.stored.isEmpty)
        PillColors.stored = ["integration_claude": teal]
        check("round trip", PillColors.stored == ["integration_claude": teal])
        check("stored under pillColors",
              (UserDefaults.standard.dictionary(forKey: "pillColors") as? [String: String]) == ["integration_claude": teal])
        UserDefaults.standard.set("not a dictionary", forKey: "pillColors")
        check("unusable → empty", PillColors.stored.isEmpty)
        UserDefaults.standard.set(["integration_claude": "nope", "agent_cursor": "#f4505e"], forKey: "pillColors")
        check("damaged entry costs only itself", PillColors.stored == ["agent_cursor": "#F4505E"])
        PillColors.stored = [:]
        check("empty removes the key", UserDefaults.standard.object(forKey: "pillColors") == nil)

        if failures == 0 { print("\nAll tests passed.") }
        else              { print("\n\(failures) test(s) FAILED."); exit(1) }
    }
}
