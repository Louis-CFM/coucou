import Foundation

/// Which step groups of a finished turn the user opened, by message id, so a turn he opened stays open when the
/// island closes or the conversation changes. Memory only for the life of the app session (never written to disk),
/// capped, and read once when a block is built: nothing observes it, so a toggle redraws no other turn.
/// In both builds, no flag.
struct ChatFoldMemory<Key: Hashable>: Equatable {
    static var maxEntries: Int { 200 }

    struct Entry: Equatable {
        var expanded: Set<Int>
        /// The user clicked at least once: the default for a turn that ends without an answer no longer applies.
        var touched: Bool
    }

    private var entries: [Key: Entry] = [:]
    /// Oldest written first.
    private var order: [Key] = []

    var count: Int { entries.count }

    func entry(for key: Key) -> Entry? { entries[key] }

    /// A turn the user never touched leaves nothing behind.
    mutating func set(_ entry: Entry, for key: Key) {
        guard entry.touched || !entry.expanded.isEmpty else { forget(key); return }
        order.removeAll { $0 == key }
        order.append(key)
        entries[key] = entry
        while order.count > Self.maxEntries {
            entries[order.removeFirst()] = nil
        }
    }

    mutating func forget(_ key: Key) {
        entries[key] = nil
        order.removeAll { $0 == key }
    }

    /// A conversation was cleared or its agent removed: its messages are gone.
    mutating func forget(_ keys: [Key]) {
        let gone = Set(keys)
        guard !gone.isEmpty else { return }
        for key in gone { entries[key] = nil }
        order.removeAll { gone.contains($0) }
    }
}
