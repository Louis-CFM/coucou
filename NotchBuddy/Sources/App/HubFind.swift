import SwiftUI

// What the Coucou window's search box does once you pick a result: the page opens, scrolls to the
// setting and lights it for a moment. Nothing here draws anything at rest. It is not behind
// `#if !APPSTORE` because Settings, which the App Store build shares, marks its groups with it.

/// "Bring this setting into view": the id of the setting, and a counter so that picking the same
/// result twice lights it twice.
struct HubFindRequest: Equatable {
    let target: String
    let token: Int
}

private struct HubFindKey: EnvironmentKey {
    static let defaultValue: HubFindRequest? = nil
}

extension EnvironmentValues {
    var hubFind: HubFindRequest? {
        get { self[HubFindKey.self] }
        set { self[HubFindKey.self] = newValue }
    }
}

/// Marks a setting so that the search can scroll to it and light it.
private struct HubFindable: ViewModifier {
    let target: String
    @Environment(\.hubFind) private var find
    @State private var lit = false

    func body(content: Content) -> some View {
        content
            .id(target)
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(Color(hex: "#FB923C"), lineWidth: 2)
                    .padding(-5)
                    .opacity(lit ? 1 : 0)
                    .allowsHitTesting(false)
            }
            // Runs when the page appears with a request pending, and when a new one arrives.
            .task(id: find) {
                guard let find, find.target == target else { return }
                // After the scroll has brought it to the middle.
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.2)) { lit = true }
                try? await Task.sleep(for: .milliseconds(1800))
                withAnimation(.easeIn(duration: 0.4)) { lit = false }
            }
    }
}

/// Scrolls the scroll view it is put on to the setting a search result led to.
private struct HubScrollsToFind: ViewModifier {
    @Environment(\.hubFind) private var find

    func body(content: Content) -> some View {
        ScrollViewReader { proxy in
            content
                .task(id: find) {
                    guard let find else { return }
                    // The page has just been drawn: let it lay out.
                    try? await Task.sleep(for: .milliseconds(250))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(find.target, anchor: .center) }
                }
        }
    }
}

extension View {
    /// A setting the search box can lead to. `id` is the one the index (HubSearch.swift) gives.
    func hubFindable(_ id: String) -> some View { modifier(HubFindable(target: id)) }

    /// Put on a `ScrollView` that holds `hubFindable` views.
    func hubScrollsToFind() -> some View { modifier(HubScrollsToFind()) }
}
