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

    var body: some View {
        NavigationStack {
            ZStack {
                ChatBackdrop(active: chat.answering)
                    .ignoresSafeArea()
                Group {
                    if let reason = chat.unavailableReason, chat.messages.isEmpty {
                        unavailable(reason)
                            .transition(.opacity)
                    } else if chat.messages.isEmpty {
                        welcome
                            .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    } else {
                        conversation
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                .animation(.spring(duration: 0.5, bounce: 0.15), value: chat.messages.isEmpty)
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
                            withAnimation(.spring(duration: 0.45)) { chat.reset() }
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
                    VStack(spacing: 10) {
                        if chat.messages.isEmpty {
                            suggestionsRow
                                .transition(.opacity.combined(with: .move(edge: .bottom)))
                        }
                        composer
                    }
                    .animation(.spring(duration: 0.45), value: chat.messages.isEmpty)
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
            ZStack {
                // Mochi glows a little, in Botan's orange.
                Circle()
                    .fill(Color.botan.opacity(0.35))
                    .frame(width: 150, height: 150)
                    .blur(radius: 50)
                MochiStill(state: .idle, showBadge: false)
                    .frame(width: 92)
            }
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
                MochiStill(state: .idle, eye: .closed, showBadge: false)
                    .frame(width: 80)
                Text("Botan can't talk here")
            }
        } description: {
            Text(reason)
        }
    }

    /// Small chips just above the field, scrolling sideways.
    private var suggestionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Self.suggestions, id: \.self) { suggestion in
                    Button {
                        ask(suggestion)
                    } label: {
                        Text(suggestion)
                            .font(.footnote.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 8)
                            .glassPill(Capsule(), interactive: true)
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
            LazyVStack(alignment: .leading, spacing: 12) {
                header
                ForEach(chat.messages) { message in
                    bubble(message)
                        .id(message.id)
                        .transition(.asymmetric(
                            insertion: .opacity
                                .combined(with: .offset(y: 18))
                                .combined(with: .scale(scale: 0.96, anchor: message.role == .you ? .bottomTrailing : .bottomLeading)),
                            removal: .opacity))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
    }

    /// Who you're talking to, at the top of the conversation.
    private var header: some View {
        VStack(spacing: 6) {
            MochiStill(state: chat.answering ? .thinking : .idle, showBadge: false)
                .frame(width: 44)
            Text("Botan")
                .font(.subheadline.weight(.semibold))
            Text("Apple's model, on your iPhone")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.bottom, 18)
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
                    .background(
                        LinearGradient(colors: [Color.botan, Color.botan.opacity(0.82)], startPoint: .top, endPoint: .bottom),
                        in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                    .textSelection(.enabled)
            }
        case .botan:
            let thinking = message.text.isEmpty && chat.answering && message.id == chat.messages.last?.id
            HStack(alignment: .bottom, spacing: 8) {
                MochiStill(state: thinking ? .thinking : .idle,
                           eye: message.failed ? .closed : nil, showBadge: false)
                    .frame(width: 28)
                Group {
                    if thinking {
                        // Botan is thinking: three dots, like Messages.
                        Image(systemName: "ellipsis")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(.secondary)
                            .symbolEffect(.variableColor.iterative.dimInactiveLayers, options: .repeating)
                            .frame(width: 44, height: 22)
                    } else {
                        Text(Self.styled(message.text))
                            .font(.body)
                            .foregroundStyle(message.failed ? .secondary : .primary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassPill(RoundedRectangle(cornerRadius: 19, style: .continuous))
                .animation(.easeOut(duration: 0.2), value: message.text.isEmpty)
                Spacer(minLength: 32)
            }
        }
    }

    /// Bold, italics and code from the model's answer; plain text when it isn't Markdown.
    private static func styled(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    // MARK: Composer

    /// One glass capsule with the field and the mic, the send button next to it, like Messages.
    private var composer: some View {
        let empty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .bottom, spacing: 2) {
                TextField("Ask Botan…", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($focused)
                    .padding(.leading, 16)
                    .padding(.vertical, 11)
                Button {
                    Task { await dictation.toggle(startingFrom: text) }
                } label: {
                    Image(systemName: dictation.isRecording ? "waveform" : "mic.fill")
                        .foregroundStyle(dictation.isRecording ? Color.red : Color.secondary)
                        .symbolEffect(.variableColor.iterative, isActive: dictation.isRecording)
                        .frame(width: 40, height: 42)
                }
                .padding(.trailing, 4)
            }
            .glassPill(RoundedRectangle(cornerRadius: 22, style: .continuous))
            Button {
                ask(text)
            } label: {
                Image(systemName: "arrow.up")
                    .font(.body.weight(.bold))
                    .foregroundStyle(empty ? Color.secondary : Color.white)
                    .frame(width: 44, height: 44)
                    .background(empty ? Color.white.opacity(0.12) : Color.botan, in: Circle())
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(empty || chat.answering)
            .animation(.spring(duration: 0.3), value: empty)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private func ask(_ question: String) {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !chat.answering else { return }
        dictation.stop()
        text = ""
        focused = false
        Haptics.impact()
        Task { await chat.send(question) }
    }
}

/// The chat's background: deep night with a slow Botan-orange glow from below and a cool
/// light from above, drifting gently (a little more while Botan answers).
struct ChatBackdrop: View {
    var active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 24)) { context in
            let t = context.date.timeIntervalSinceReferenceDate * (active ? 0.5 : 0.18)
            MeshGradient(
                width: 3, height: 3,
                points: [
                    [0, 0], [0.5 + Self.drift(t, 0, 0.08), 0], [1, 0],
                    [0, 0.5 + Self.drift(t, 1.3, 0.06)],
                    [0.5 + Self.drift(t, 2.1, 0.1), 0.48 + Self.drift(t, 0.7, 0.08)],
                    [1, 0.5 + Self.drift(t, 2.9, 0.06)],
                    [0, 1], [0.5 + Self.drift(t, 1.9, 0.1), 1], [1, 1],
                ],
                colors: [
                    Color(red: 0.03, green: 0.03, blue: 0.05), Color(red: 0.06, green: 0.05, blue: 0.13), Color(red: 0.09, green: 0.06, blue: 0.2),
                    Color(red: 0.02, green: 0.02, blue: 0.03), Color(red: 0.05, green: 0.03, blue: 0.05), Color(red: 0.04, green: 0.03, blue: 0.07),
                    Color(red: 0.2, green: 0.06, blue: 0.02), Color.botan.opacity(active ? 0.55 : 0.38), Color(red: 0.12, green: 0.04, blue: 0.03),
                ]
            )
        }
        .background(Color.black)
        .animation(.easeInOut(duration: 1.2), value: active)
    }

    private static func drift(_ t: Double, _ phase: Double, _ amount: Double) -> Float {
        Float(sin(t + phase) * amount)
    }
}
