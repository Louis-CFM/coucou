import Foundation

// The stable project-colour fold (CoucouKit/IslandTypes.swift, colorForProject).
// The wrapping &* / &+ fold can produce any Int — including Int.min, where
// abs() traps. magnitude must pick a colour for every input, identical to
// abs() everywhere abs() was defined.
//
// EyeShape lives in BotEngine.swift (CoreGraphics) — a stub lets
// IslandTypes.swift compile alone, like the other script tests do with
// their single file.
enum EyeShape: String { case pill, wide, happy, flat, closed, tired, spiral }

@main
enum ProjectColorFoldTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    /// The same fold IslandConst.colorForProject uses — duplicated here so the
    /// parity check compares the real output against the formula.
    static func fold(_ key: String) -> Int {
        key.unicodeScalars.reduce(0) { ($0 &* 31) &+ Int($1.value) }
    }

    static func main() {
        // 1. Every project-colour lookup lands on a declared colour — the path
        //    that used to crash when the fold produced Int.min.
        let probes = ["a", "z", "korus-api-x", "notch-buddy-2", "proj", "x",
                      "abcdefghijklmnopqrstuvwxyz0123456789", "příliš-žluťoučký",
                      "mixedCASEname", "  padded  ", "emoji-🎉", "-", ""]
        for p in probes {
            let c = IslandConst.colorForProject(p)
            check("colorForProject(\"\(p.prefix(12))…\") returns a colour",
                  c.hasPrefix("#") && c.count == 7)
        }

        // 2. Deterministic: the same name always gets the same colour.
        check("deterministic",
              IslandConst.colorForProject("some-random-proj")
                  == IslandConst.colorForProject("some-random-proj"))

        // 3. Parity with the old abs() mapping wherever abs() was defined:
        //    magnitude == abs for every non-Int.min h, so colours must match.
        var negativeSeen = false
        var parity = true
        for i in 0..<5000 {
            let key = "proj-\(i)-\(i * 2654435761 % 100003)"
            let h = fold(key)
            if h < 0 { negativeSeen = true }
            // Skip keys that hit the explicit/prefix colour tables — they
            // never reach the fold.
            let low = key.lowercased().trimmingCharacters(in: .whitespaces)
            let explicit = IslandConst.projectColors.keys.contains {
                low.hasPrefix($0) || low.contains($0)
            }
            if explicit { continue }
            let got = IslandConst.colorForProject(key)
            let want = IslandConst.fallbackColors[Int(h.magnitude % UInt(IslandConst.fallbackColors.count))]
            if got != want { parity = false; print("    mismatch \(key): \(got) != \(want)") }
        }
        check("5000-key parity with magnitude fold", parity)
        check("fold actually produces negative h (path exercised)", negativeSeen)

        // 4. The trap itself: magnitude on Int.min is 2^63 — safe; abs(Int.min)
        //    would trap. Evaluate the exact expression the code uses.
        let minVal = Int.min
        let idx = Int(minVal.magnitude % UInt(IslandConst.fallbackColors.count))
        check("Int.min folds to a valid index (no trap)", (0..<IslandConst.fallbackColors.count).contains(idx))

        print(failures == 0 ? "ProjectColorFoldTests: all checks passed"
                            : "ProjectColorFoldTests: \(failures) FAILED")
        if failures > 0 { exit(1) }
    }
}
