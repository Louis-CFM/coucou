import Foundation

@main
enum DiffEngineTests {

    static var failures = 0

    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ✓ \(label)") }
        else      { print("  ✗ \(label)"); failures += 1 }
    }

    static func checkInt(_ label: String, _ got: Int, _ expected: Int) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)  got: \(got)  expected: \(expected)"); failures += 1 }
    }

    static func main() {

        // ── DiffEngine.fromEdit — additions ───────────────────────────────────
        print("DiffEngine.fromEdit — additions")
        do {
            let d = DiffEngine.fromEdit(old: "", new: "hello\nworld\n", path: "/a/b.swift")
            checkInt("added == 2",      d.added,    2)
            checkInt("removed == 0",    d.removed,  0)
            checkTrue("!tooLarge",      !d.tooLarge)
            checkTrue("1 hunk",         d.hunks.count == 1)
            checkTrue("name == b.swift", d.name == "b.swift")
        }

        // ── DiffEngine.fromEdit — removals ────────────────────────────────────
        print("DiffEngine.fromEdit — removals")
        do {
            let d = DiffEngine.fromEdit(old: "hello\nworld\n", new: "", path: "/x.py")
            checkInt("added == 0",   d.added,   0)
            checkInt("removed == 2", d.removed, 2)
            checkTrue("1 hunk",      d.hunks.count == 1)
        }

        // ── DiffEngine.fromEdit — replacement ─────────────────────────────────
        print("DiffEngine.fromEdit — replacement")
        do {
            let d = DiffEngine.fromEdit(old: "foo\nbar\nbaz\n",
                                         new: "foo\nqux\nbaz\n",
                                         path: "/f.ts")
            checkInt("added == 1",   d.added,   1)
            checkInt("removed == 1", d.removed, 1)
            checkTrue("has context lines",
                      d.hunks.first?.lines.contains(where: { $0.kind == .context }) == true)
        }

        // ── DiffEngine.fromNew — new file ──────────────────────────────────────
        print("DiffEngine.fromNew — new file")
        do {
            let d = DiffEngine.fromNew(content: "line1\nline2\nline3\n", path: "/new.rs")
            checkInt("added == 3",   d.added,   3)
            checkInt("removed == 0", d.removed, 0)
            checkTrue("all lines .added",
                      d.hunks.flatMap { $0.lines }.allSatisfy { $0.kind == .added })
        }

        // ── DiffEngine.fromEdit — MultiEdit (two edits) ────────────────────────
        print("DiffEngine.fromEdit — MultiEdit (two edits)")
        do {
            let d1 = DiffEngine.fromEdit(old: "aaa\n", new: "bbb\n", path: "/m.kt")
            let d2 = DiffEngine.fromEdit(old: "ccc\n", new: "ddd\n", path: "/m.kt")
            checkInt("d1 added == 1",   d1.added,   1)
            checkInt("d1 removed == 1", d1.removed, 1)
            checkInt("d2 added == 1",   d2.added,   1)
            checkInt("d2 removed == 1", d2.removed, 1)
        }

        // ── DiffEngine — tooLarge ──────────────────────────────────────────────
        print("DiffEngine — tooLarge")
        do {
            // Generate > 200 KB combined content
            let bigOld = String(repeating: "x", count: 150 * 1024)
            let bigNew = String(repeating: "y", count: 60 * 1024)
            let d = DiffEngine.fromEdit(old: bigOld, new: bigNew, path: "/big.swift")
            checkTrue("tooLarge == true",   d.tooLarge)
            checkTrue("hunks.isEmpty",      d.hunks.isEmpty)
        }

        // ── DiffEngine — CRLF ─────────────────────────────────────────────────
        print("DiffEngine — CRLF")
        do {
            let d = DiffEngine.fromEdit(old: "a\r\nb\r\n", new: "a\r\nc\r\n", path: "/win.txt")
            checkInt("added == 1",   d.added,   1)
            checkInt("removed == 1", d.removed, 1)
        }

        // ── DiffEngine — no trailing newline ──────────────────────────────────
        print("DiffEngine — no trailing newline")
        do {
            let d = DiffEngine.fromEdit(old: "hello", new: "hello\nworld", path: "/t.txt")
            checkInt("added == 1",   d.added,   1)
            checkInt("removed == 0", d.removed, 0)
        }

        // ── DiffEngine — 3-line context ───────────────────────────────────────
        print("DiffEngine — 3-line context")
        do {
            // 10-line file, change line 5
            let oldContent = (1...10).map { "line\($0)" }.joined(separator: "\n") + "\n"
            let newContent = (1...10).map { $0 == 5 ? "changed" : "line\($0)" }.joined(separator: "\n") + "\n"
            let d = DiffEngine.fromEdit(old: oldContent, new: newContent, path: "/ctx.swift")
            checkInt("added == 1",   d.added,   1)
            checkInt("removed == 1", d.removed, 1)
            checkTrue("1 hunk",      d.hunks.count == 1)
            let hunk = d.hunks[0]
            let contextLines = hunk.lines.filter { $0.kind == .context }
            checkTrue("has context before change", contextLines.count >= 3)
        }

        // ── DiffEngine — firstChangedLine > 0 ────────────────────────────────
        print("DiffEngine — firstChangedLine > 0")
        do {
            let d = DiffEngine.fromEdit(old: "foo\nbar\nbaz\n",
                                         new: "foo\nqux\nbaz\n",
                                         path: "/f.ts")
            checkTrue("firstChangedLine > 0", d.firstChangedLine > 0)
        }

        // ── String.makeDiffStep / parseDiffStep ───────────────────────────────
        print("String.makeDiffStep / parseDiffStep")
        do {
            let s = String.makeDiffStep(filename: "foo.swift", added: 3, removed: 1, diffIdx: 7)
            checkTrue("isDiffStep", s.isDiffStep)
            let parsed = s.parseDiffStep()
            checkTrue("parsed != nil",         parsed != nil)
            checkTrue("filename round-trips",  parsed?.filename == "foo.swift")
            checkTrue("added round-trips",     parsed?.added    == 3)
            checkTrue("removed round-trips",   parsed?.removed  == 1)
            checkTrue("diffIdx round-trips",   parsed?.diffIdx  == 7)

            // Non-diff step should not parse
            checkTrue("normal step !isDiffStep", !"Edit foo.swift".isDiffStep)
            checkTrue("normal step parseDiffStep == nil", "Edit foo.swift".parseDiffStep() == nil)
        }

        // ── finish ─────────────────────────────────────────────────────────────
        if failures == 0 {
            print("\nAll tests passed.")
            exit(0)
        } else {
            print("\n\(failures) test(s) failed.")
            exit(1)
        }
    }
}
