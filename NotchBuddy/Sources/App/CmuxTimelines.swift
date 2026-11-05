import Foundation
import SwiftUI

#if !APPSTORE

/// What the reply view of a cmux session draws: the messages of the session on screen and whether its turn runs.
/// Only the timeline body observes it, so an event redraws that body and not the header, the chips or the field.
@MainActor
final class CmuxTimelineScreen: ObservableObject {
    @Published fileprivate(set) var messages: [ChatMessage] = []
    @Published fileprivate(set) var running = false
    /// Bumped on every publish: what the scroll follows.
    @Published fileprivate(set) var revision = 0
}

/// The holder of the cmux timelines: the pure store, the messages the chat list draws from it, and the live state of
/// each session. Not observable (`AppState` hears from it only through `cmuxTimelineBucket`). Memory only: nothing
/// here is encoded, saved, logged or sent, and nothing runs between hook events (no timer).
@MainActor
final class CmuxTimelines {
    static let shared = CmuxTimelines()

    let screen = CmuxTimelineScreen()
    private var store = TimelineStore()
    /// The session the reply view renders; its changes are published, the others only reduced.
    private var shown: String?
    private var live: [String: BotState] = [:]
    /// Rows of a burst are published at most `StepPublishBudget.perSecond` times a second; a change that found the
    /// budget spent goes out with the next event.
    private var budget = StepPublishBudget()
    private var dirty = false
    /// The one delayed flush of a change the budget held back: armed only while a session is shown and a change waits,
    /// one shot, cancelled by any publish and by `show(nil)`. Never a repeating timer.
    private var flush: DispatchWorkItem?
    private static let flushDelay: TimeInterval = 0.25

    private struct Kept {
        var user: ChatMessage?
        var assistant: ChatMessage?
    }
    /// The `ChatMessage` of each turn, by session and turn id. The ids are what the scroll anchors and the fold memory
    /// key on, so a turn keeps its message and only its segments change.
    private var kept: [String: [Int: Kept]] = [:]

    private init() {}

    // MARK: Reading

    func messageCount(for key: String) -> Int { store.messageCount(for: key) }

    // MARK: Events

    /// One event of a session. Only the session on screen publishes.
    func apply(_ event: TimelineEvent, to key: String) {
        let now = ProcessInfo.processInfo.systemUptime
        let applied = store.apply(event, to: key, now: now, shown: shown)
        // What the store dropped (a reset, a session over its cap) leaves nothing behind here.
        if applied.reset { drop(key, keepingLive: true) }
        for gone in applied.evicted { drop(gone, keepingLive: false) }
        guard key == shown else { return }
        if applied.changed || dirty {
            if Self.alwaysPublishes(event) || budget.take(at: Date()) { publish() } else { hold() }
        }
    }

    /// A change the budget refused goes out by itself shortly, even when no other hook event comes.
    private func hold() {
        dirty = true
        guard flush == nil, shown != nil else { return }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.flush = nil
                if self.dirty, self.shown != nil { self.publish() }
            }
        }
        flush = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.flushDelay, execute: item)
    }

    private func drop(_ key: String, keepingLive: Bool) {
        if !keepingLive { live[key] = nil }
        if let map = kept.removeValue(forKey: key) { forget(map) }
    }

    /// The last word of a turn, a prompt and a request are never held back.
    private static func alwaysPublishes(_ event: TimelineEvent) -> Bool {
        switch event {
        case .toolStarted, .toolFinished: return false
        default: return true
        }
    }

    /// The state of a session changed (every path goes through `setCmuxSurfaceState`).
    func setLive(_ key: String, _ state: BotState) {
        live[key] = state
        guard key == shown, screen.running != isRunning(key) else { return }
        publish()
    }

    /// The session ended, was forgotten or evicted.
    func remove(_ key: String) {
        store.remove(key)
        drop(key, keepingLive: false)
        if key == shown { publish() }
    }

    /// The reply view shows this session (nil: it shows none, nothing is published).
    func show(_ key: String?) {
        shown = key
        dirty = false
        flush?.cancel()
        flush = nil
        guard let key else {
            // Nothing is drawn: nothing of the last session stays on the screen object either.
            if !screen.messages.isEmpty { screen.messages = [] }
            if screen.running { screen.running = false }
            return
        }
        if live[key] == nil, let raw = HookServer.shared.cmuxSurface(key: key)?.state, let s = BotState(rawValue: raw) { live[key] = s }
        publish()
    }

    // MARK: Publishing

    private func isRunning(_ key: String) -> Bool {
        guard store.isOpen(key), let s = live[key] else { return false }
        return [.thinking, .working, .searching, .approval, .question].contains(s)
    }

    private func publish() {
        dirty = false
        flush?.cancel()
        flush = nil
        guard let key = shown else { return }
        let turns = store.turns(for: key)
        var map = kept[key] ?? [:]
        let alive = Set(turns.map(\.id))
        var gone: [Int: Kept] = [:]
        for (id, k) in map where !alive.contains(id) { gone[id] = k; map[id] = nil }
        forget(gone)
        var out: [ChatMessage] = []
        for turn in turns {
            var k = map[turn.id] ?? Kept()
            if let prompt = turn.prompt {
                if k.user == nil { k.user = ChatMessage(role: .user, content: prompt) }
                if let user = k.user { out.append(user) }
            }
            if !turn.segments.isEmpty {
                if k.assistant == nil { k.assistant = ChatMessage(role: .assistant, content: "") }
                k.assistant?.segments = turn.segments
                if let assistant = k.assistant { out.append(assistant) }
            }
            map[turn.id] = k
        }
        kept[key] = map
        screen.messages = out
        let running = isRunning(key)
        if screen.running != running { screen.running = running }
        screen.revision &+= 1
        let bucket = min(2, store.messageCount(for: key))
        if AppState.shared.cmuxTimelineBucket != bucket { AppState.shared.cmuxTimelineBucket = bucket }
    }

    private func forget(_ map: [Int: Kept]) {
        let ids = map.values.flatMap { [$0.user?.id, $0.assistant?.id] }.compactMap { $0 }
        if !ids.isEmpty { ChatFolds.memory.forget(ids) }
    }
}

#endif
