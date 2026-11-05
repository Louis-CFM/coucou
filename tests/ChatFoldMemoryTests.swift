import Foundation

@main
enum ChatFoldMemoryTests {

    static var failures = 0

    static func check(_ label: String, _ ok: Bool) {
        if ok { print("  ✓ \(label)") }
        else  { print("  ✗ \(label)"); failures += 1 }
    }

    typealias Memory = ChatFoldMemory<Int>
    typealias Entry = Memory.Entry

    static func main() {
        print("chat fold memory")
        var m = Memory()
        check("1. nothing is remembered for a turn never seen", m.entry(for: 1) == nil && m.count == 0)

        m.set(Entry(expanded: [3], touched: true), for: 1)
        check("2. an opened group is remembered", m.entry(for: 1) == Entry(expanded: [3], touched: true))

        m.set(Entry(expanded: [], touched: true), for: 1)
        check("3. a group the user closed again stays remembered as touched (the default no longer applies)",
              m.entry(for: 1) == Entry(expanded: [], touched: true))

        m.set(Entry(expanded: [], touched: false), for: 1)
        check("4. an untouched turn leaves nothing behind", m.entry(for: 1) == nil && m.count == 0)

        m.set(Entry(expanded: [1], touched: true), for: 1)
        m.set(Entry(expanded: [2], touched: true), for: 2)
        m.set(Entry(expanded: [3], touched: true), for: 3)
        m.forget([1, 3, 99])
        check("5. forgetting a cleared conversation drops its turns only",
              m.entry(for: 1) == nil && m.entry(for: 3) == nil && m.entry(for: 2) != nil && m.count == 1)
        m.forget([])
        m.forget(2)
        check("6. forgetting one key and an empty list", m.count == 0)

        var capped = Memory()
        for k in 0..<(Memory.maxEntries + 25) { capped.set(Entry(expanded: [k], touched: true), for: k) }
        check("7. the store is capped, the oldest written goes first",
              capped.count == Memory.maxEntries && capped.entry(for: 0) == nil && capped.entry(for: 24) == nil
              && capped.entry(for: 25) != nil && capped.entry(for: Memory.maxEntries + 24) != nil)

        var touchedAgain = Memory()
        for k in 0..<Memory.maxEntries { touchedAgain.set(Entry(expanded: [k], touched: true), for: k) }
        touchedAgain.set(Entry(expanded: [0, 7], touched: true), for: 0)
        touchedAgain.set(Entry(expanded: [1], touched: true), for: 5000)
        check("8. a turn written again is no longer the oldest",
              touchedAgain.entry(for: 0) != nil && touchedAgain.entry(for: 1) == nil)

        var a = Memory(), b = Memory()
        a.set(Entry(expanded: [1], touched: true), for: 1)
        b.set(Entry(expanded: [1], touched: true), for: 1)
        check("9. equal contents are equal", a == b)

        print(failures == 0 ? "\nAll chat fold memory tests passed." : "\n\(failures) failure(s).")
        exit(failures == 0 ? 0 : 1)
    }
}
