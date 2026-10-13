import SwiftUI

// Back-port of SwiftUI's macOS-14 `onChange(of:initial:_:)` (the two-parameter
// `{ oldValue, newValue in }` form) to macOS 13, so the app can target Ventura.
// On macOS 14+ it forwards to the native modifier; on macOS 13 it tracks the
// previous value itself, because the macOS-13 `onChange(of:perform:)` only hands
// back the new value.
extension View {
    @ViewBuilder
    func onChangeCompat<V: Equatable>(
        of value: V,
        initial: Bool = false,
        _ action: @escaping (V, V) -> Void
    ) -> some View {
        if #available(macOS 14.0, *) {
            onChange(of: value, initial: initial, action)
        } else {
            modifier(OnChangeCompatModifier(value: value, initial: initial, action: action))
        }
    }
}

private struct OnChangeCompatModifier<V: Equatable>: ViewModifier {
    let value: V
    let initial: Bool
    let action: (V, V) -> Void
    @State private var previous: V?

    func body(content: Content) -> some View {
        content
            .onAppear {
                if previous == nil {
                    previous = value
                    if initial { action(value, value) }
                }
            }
            .onChange(of: value) { newValue in
                let old = previous ?? newValue
                action(old, newValue)
                previous = newValue
            }
    }
}
