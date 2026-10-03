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

        // ── DiffEngine — m*n > 1_000_000 → tooLarge ─────────────────────────
        print("DiffEngine — m*n > 1_000_000 → tooLarge")
        do {
            // 1001 old lines × 1001 new lines = > 1M
            let many = (0..<1001).map { "line\($0)" }.joined(separator: "\n")
            let d = DiffEngine.fromEdit(old: many, new: many + "\nextra", path: "/big.swift")
            checkTrue("tooLarge when m*n > 1M", d.tooLarge)
            checkTrue("hunks empty",            d.hunks.isEmpty)
        }

        // ── DiffEngine.fromNew — too large ────────────────────────────────────
        print("DiffEngine.fromNew — too large")
        do {
            let bigContent = String(repeating: "x\n", count: FileDiff.maxLines + 1)
            let d = DiffEngine.fromNew(content: bigContent, path: "/new.swift")
            checkTrue("fromNew tooLarge",    d.tooLarge)
            checkTrue("fromNew isNewFile",   d.isNewFile)
            checkTrue("fromNew hunks empty", d.hunks.isEmpty)
            checkTrue("fromNew added > 0",   d.added > 0)
        }

        // ── String.makeDiffStep / parseDiffStep ───────────────────────────────
        print("String.makeDiffStep / parseDiffStep")
        do {
            let s = String.makeDiffStep(filename: "foo.swift", added: 3, removed: 1, diffId: 7)
            checkTrue("isDiffStep", s.isDiffStep)
            let parsed = s.parseDiffStep()
            checkTrue("parsed != nil",        parsed != nil)
            checkTrue("filename round-trips", parsed?.filename == "foo.swift")
            checkTrue("added round-trips",    parsed?.added    == 3)
            checkTrue("removed round-trips",  parsed?.removed  == 1)
            checkTrue("diffId round-trips",   parsed?.diffId   == 7)

            // id > 9 (multi-digit) round-trips correctly
            let s2 = String.makeDiffStep(filename: "bar.ts", added: 0, removed: 2, diffId: 42)
            checkTrue("diffId 42 round-trips", s2.parseDiffStep()?.diffId == 42)

            // Non-diff step should not parse
            checkTrue("normal step !isDiffStep", !"Edit foo.swift".isDiffStep)
            checkTrue("normal step parseDiffStep == nil", "Edit foo.swift".parseDiffStep() == nil)
        }

        // ── DiffEngine.toOneLine ──────────────────────────────────────────────
        print("DiffEngine.toOneLine")
        do {
            // multi-line joined with space
            checkTrue("multi-line joined",
                DiffEngine.toOneLine("line one\nline two\nline three") == "line one line two line three")

            // bold stripped
            checkTrue("bold stripped",
                DiffEngine.toOneLine("**hello** world") == "hello world")

            // heading stripped
            checkTrue("heading stripped",
                DiffEngine.toOneLine("## My Title\nsome text") == "My Title some text")

            // empty input → empty
            checkTrue("empty → empty", DiffEngine.toOneLine("").isEmpty)

            // truncation
            let long = DiffEngine.toOneLine(String(repeating: "x ", count: 200), maxChars: 10)
            checkTrue("truncated to maxChars", long.count <= 10)

            // stop at blank line
            checkTrue("blank line → first para only",
                DiffEngine.toOneLine("First para.\n\nSecond para.") == "First para.")

            // stop at --- separator
            checkTrue("--- separator → first para only",
                DiffEngine.toOneLine("Done. Single commit 450a657 on github-pulse.\n\n---\n\nFiles touched (7)…")
                    == "Done. Single commit 450a657 on github-pulse.")

            // stop at *** separator
            checkTrue("*** separator → first para only",
                DiffEngine.toOneLine("Summary line.\n***\nMore details.") == "Summary line.")

            // stop at table row (|)
            checkTrue("table row → first para only",
                DiffEngine.toOneLine("Result:\n| Col1 | Col2 |\n|---|---|\n| A | B |") == "Result:")

            // strip leading bullet -
            checkTrue("strip bullet -",
                DiffEngine.toOneLine("- item one\n- item two") == "item one item two")

            // strip leading bullet *
            checkTrue("strip bullet *",
                DiffEngine.toOneLine("* first\n* second") == "first second")

            // strip ordered list
            checkTrue("strip ordered list",
                DiffEngine.toOneLine("1. step one\n2. step two") == "step one step two")

            // first paragraph empty → fall through to next
            checkTrue("empty first para → next",
                DiffEngine.toOneLine("\n\nActual content.") == "Actual content.")
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
