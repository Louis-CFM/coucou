import SwiftUI

/// The Chat tab: ask Botan about your agents, services and OKs, like Messages, with Mochi
/// answering. Apple's model runs on the iPhone (BotanChat).
struct ChatView: View {
    @State private var chat = BotanChat.shared
    @State private var text = ""
    @State private var dictation = Dictation()
    @FocusState private var focused: Bool

    private static let suggestions = [
        "What happened today?",
        "Anything waiting for me?",
        "Did a deploy fail this week?",
        "What did I earn today?",
        "What did Claude do last?",
    ]

    /// One spring for everything that moves when a chat starts or ends.
    private static let move = Animation.spring(duration: 0.55, bounce: 0.12)

    var body: some View {
        NavigationStack {
            ZStack {
                ChatBackdrop(active: chat.answering)
                    .ignoresSafeArea()
                if let reason = chat.unavailableReason, chat.messages.isEmpty {
                    unavailable(reason)
                        .transition(.opacity)
                } else if chat.messages.isEmpty {
                    welcome
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 0.92)),
                                                removal: .opacity.combined(with: .scale(scale: 1.06))))
                } else {
                    conversation
                        .transition(.opacity)
                }
            }
            // A swipe down anywhere puts the keyboard away, like Messages.
            .simultaneousGesture(
                DragGesture(minimumDistance: 12).onChanged { drag in
                    if focused, drag.translation.height > 24, abs(drag.translation.width) < drag.translation.height {
                        focused = false
                    }
                }
            )
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !chat.messages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(Self.move) { chat.reset() }
                            Haptics.impact()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .disabled(chat.answering)
                        .accessibilityLabel("New chat")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if chat.unavailableReason == nil {
                    VStack(spacing: 0) {
                        // Always laid out, folded away once the chat starts: it fades and
                        // shrinks with the rest instead of vanishing.
                        let showSuggestions = chat.messages.isEmpty
                        suggestionsRow
                            .opacity(showSuggestions ? 1 : 0)
                            .scaleEffect(showSuggestions ? 1 : 0.9, anchor: .bottom)
                            .frame(height: showSuggestions ? nil : 0, alignment: .bottom)
                            .padding(.bottom, showSuggestions ? 10 : 0)
                            .clipped()
                            .allowsHitTesting(showSuggestions)
                        composer
                    }
                }
            }
            .onChange(of: dictation.transcript) { _, words in
                if dictation.isRecording { text = dictation.prefix + words }
            }
        }
    }

    // MARK: Empty states

    private var welcome: some View {
        VStack(spacing: 14) {
            Spacer()
            MochiLive(state: .idle)
                .frame(width: 96)
                .padding(.bottom, 4)
            Text("Ask Botan")
                .font(.title2.weight(.semibold))
            Text("Your agents, your services, what you allowed.\nApple's model answers on your iPhone: nothing leaves it.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 36)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { focused = false }
    }

    private func unavailable(_ reason: String) -> some View {
        ContentUnavailableView {
            VStack(spacing: 12) {
                MochiLive(state: .sleeping)
                    .frame(width: 80)
                Text("Botan can't talk here")
            }
        } description: {
            Text(reason)
        }
    }

    /// Small chips just above the field, scrolling sideways. Plain, not glass: the tab bar and
    /// the field are glass already.
    private var suggestionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button {
                        ask(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .background(Color.white.opacity(0.07), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .padding(.horizontal, 12)
        }
        .scrollClipDisabled()
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(chat.messages) { message in
                    bubble(message)
                        .id(message.id)
                        .transition(.asymmetric(
                            insertion: .opacity
                                .combined(with: .offset(y: 24))
                                .combined(with: .scale(scale: 0.9, anchor: message.role == .you ? .bottomTrailing : .bottomLeading)),
                            removal: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 20)
            .padding(.bottom, 12)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder private func bubble(_ message: ChatMessage) -> some View {
        switch message.role {
        case .you:
            HStack {
                Spacer(minLength: 48)
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .yourBubble()
                    .textSelection(.enabled)
            }
        case .botan:
            let last = message.id == chat.messages.last(where: { $0.role == .botan })?.id
            let thinking = message.text.isEmpty && chat.answering && last
            HStack(alignment: .bottom, spacing: 8) {
                // One Mochi only, beside Botan's latest answer, alive like everywhere else.
                Group {
                    if last {
                        MochiLive(state: chat.mood)
                            .transition(.scale.combined(with: .opacity))
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 30, height: 30)
                Group {
                    if thinking {
                        // Botan is thinking: three dots, like Messages.
                        Image(systemName: "ellipsis")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.secondary)
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                            .frame(width: 44, height: 22)
                    } else {
                        StreamingText(text: message.text, animate: last)
                            .font(.body)
                            .foregroundStyle(message.failed ? .secondary : .primary)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 19, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                Spacer(minLength: 32)
            }
            .animation(.spring(duration: 0.35), value: message.text.isEmpty)
        }
    }

    // MARK: Composer

    /// One glass capsule: the field, the mic and the send button inside it, like Messages.
    private var composer: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 0) {
            TextField("Ask Botan…", text: $text, axis: .vertical)
                .lineLimit(1...6)
                .focused($focused)
                .padding(.leading, 16)
                .padding(.vertical, 11)
            if empty {
                Button {
                    Task { await dictation.toggle(startingFrom: text) }
                } label: {
                    Image(systemName: dictation.isRecording ? "waveform" : "mic.fill")
                        .foregroundStyle(dictation.isRecording ? Color.red : Color.secondary)
                        .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                        .frame(width: 44, height: 42)
                }
                .transition(.scale.combined(with: .opacity))
            } else {
                Button {
                    ask(text)
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.botan, in: Circle())
                        .padding(5)
                }
                .buttonStyle(PressableButtonStyle())
                .disabled(chat.answering)
                .transition(.scale.combined(with: .opacity))
            }
        }
        .animation(.spring(duration: 0.3), value: empty)
        .glassPill(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func ask(_ question: String) {
        dictation.stop()
        var started: String?
        // Inside the animation: the welcome fades, the chips fold, the bubbles rise.
        withAnimation(Self.move) {
            started = chat.begin(question)
        }
        guard let started else { return }
        text = ""
        focused = false
        Haptics.impact()
        Task { await chat.respond(to: started) }
    }
}

// MARK: - Text that writes itself

/// Botan's answer, written letter by letter whatever chunks the model sends: the shown part
/// catches up smoothly and its last letters fade in.
struct StreamingText: View {
    let text: String
    @State private var shown: Double

    /// Letters that are still fading in, at the end.
    private static let tail = 10.0

    init(text: String, animate: Bool) {
        self.text = text
        _shown = State(initialValue: animate ? 0 : .greatestFiniteMagnitude)
    }

    var body: some View {
        let full = Self.styled(text)
        let total = full.characters.count
        Group {
            if shown >= Double(total) + Self.tail {
                Text(full)
            } else {
                let count = min(total, max(0, Int(shown)))
                let end = full.characters.index(full.startIndex, offsetBy: count)
                Text(AttributedString(full[full.startIndex..<end]))
                    .textRenderer(FadingTail(shown: shown, tail: Self.tail))
            }
        }
        .textSelection(.enabled)
        .task(id: text) {
            // Faster when far behind, never slower than a quick typing pace.
            while !Task.isCancelled, shown < Double(total) + Self.tail {
                let behind = Double(total) - shown
                shown += max(0.7, behind / 12)
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// Bold, italics and code from the model's answer; plain text when it isn't Markdown.
    static func styled(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// Draws the text with its newest letters fading in.
private struct FadingTail: TextRenderer {
    var shown: Double
    var tail: Double

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        var index = 0.0
        for line in layout {
            for run in line {
                for slice in run {
                    var copy = context
                    copy.opacity = max(0, min(1, (shown - index) / tail))
                    copy.draw(slice)
                    index += 1
                }
            }
        }
    }
}

// MARK: - Background

/// The chat's background: black, with a Botan-orange glow breathing and drifting at the bottom.
struct ChatBackdrop: View {
    var active: Bool
    /// Moves only while on screen (the tab view keeps hidden tabs alive).
    @State private var visible = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: !visible)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * (active ? 0.7 : 0.35)
            let glow = 0.42 + 0.1 * sin(t * 0.8) + (active ? 0.12 : 0)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5, 0], [1, 0],
                    [0, 0.55 + Self.wave(t, 1.3, 0.05)],
                    [0.5 + Self.wave(t, 2.1, 0.14), 0.62 + Self.wave(t * 1.3, 0.7, 0.07)],
                    [1, 0.55 + Self.wave(t, 2.9, 0.05)],
                    [0, 1], [0.5 + Self.wave(t * 0.9, 1.9, 0.22), 1], [1, 1],
                ],
                colors: [
                    .black, .black, .black,
                    .black, Color(red: 0.03, green: 0.015, blue: 0.01), .black,
                    Color(red: 0.12, green: 0.035, blue: 0.01), Color.botan.opacity(glow), Color(red: 0.1, green: 0.03, blue: 0.01),
                ]
            )
        }
        .background(Color.black)
        .onAppear { visible = true }
        .onDisappear { visible = false }
    }

    private static func wave(_ t: Double, _ phase: Double, _ amount: Double) -> Float {
        Float(sin(t + phase) * amount)
    }
}

private extension View {
    /// Your bubbles: the same see-through glass as Botan's, in Botan's orange. The background
    /// shows through (darker over the black, warmer over the glow), with a faint orange edge.
    func yourBubble() -> some View {
        let shape = RoundedRectangle(cornerRadius: 19, style: .continuous)
        return self
            .background(Color.botan.opacity(0.26), in: shape)
            .overlay(shape.strokeBorder(Color.botan.opacity(0.35), lineWidth: 0.5))
    }
}
