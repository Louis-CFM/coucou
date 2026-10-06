import SwiftUI

// Back-deploy shims for the legacy build (scripts/build-legacy.sh, macOS 12+).
// On macOS 14+ every shim calls the native SwiftUI API, so the default
// macOS 15 build behaves exactly as before.

extension View {
    /// `onChange(of:) { old, new in }` — native on macOS 14+, old-value tracking before.
    func onChangeCompat<V: Equatable>(of value: V, _ action: @escaping (V, V) -> Void) -> some View {
        modifier(OnChangeCompat(value: value, action: action))
    }

    /// `.scrollContentBackground(.hidden)` where available (macOS 13+).
    @ViewBuilder func scrollContentBackgroundHidden() -> some View {
        if #available(macOS 13, *) { scrollContentBackground(.hidden) } else { self }
    }

    /// `.underline()` where available (macOS 13+), plain otherwise.
    @ViewBuilder func underlineIfAvailable() -> some View {
        if #available(macOS 13, *) { underline() } else { self }
    }

    /// Rolling-digits transition where available (macOS 13+).
    @ViewBuilder func numericTextTransition() -> some View {
        if #available(macOS 13, *) { contentTransition(.numericText(countsDown: false)) } else { self }
    }
}

private struct OnChangeCompat<V: Equatable>: ViewModifier {
    let value: V
    let action: (V, V) -> Void
    @State private var old: V

    init(value: V, action: @escaping (V, V) -> Void) {
        self.value = value
        self.action = action
        _old = State(initialValue: value)
    }

    func body(content: Content) -> some View {
        if #available(macOS 14, *) {
            content.onChange(of: value) { o, n in action(o, n) }
        } else {
            content.onChange(of: value) { n in
                let o = old
                old = n
                action(o, n)
            }
        }
    }
}

/// ChipFlowLayout on macOS 13+, an adaptive grid before `Layout` existed.
struct ChipFlow<Content: View>: View {
    var spacing: CGFloat = 6
    @ViewBuilder var content: Content

    var body: some View {
        if #available(macOS 13, *) {
            ChipFlowLayout(spacing: spacing) { content }
        } else {
            // ponytail: grid, not a true flow — chips sit in equal columns on macOS 12
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: spacing, alignment: .leading)],
                      alignment: .leading, spacing: spacing) { content }
        }
    }
}
