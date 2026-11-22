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
        "Is anything waiting for me?",
        "Did a deploy fail this week?",
        "What did I earn today?",
    ]

    var body: some View {
        NavigationStack {
            Group {
                if let reason = chat.unavailableReason, chat.messages.isEmpty {
                    unavailable(reason)
                } else if chat.messages.isEmpty {
                    welcome
                } else {
                    conversation
                }
            }
            .background(Color.black)
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !chat.messages.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            withAnimation(.spring(duration: 0.35)) { chat.reset() }
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
                if chat.unavailableReason == nil { composer }
            }
            .onChange(of: dictation.transcript) { _, words in
                if dictation.isRecording { text = dictation.prefix + words }
            }
        }
    }

    // MARK: Empty states

    private var welcome: some View {
        ScrollView {
            VStack(spacing: 14) {
                MochiStill(state: .idle, showBadge: false)
                    .frame(width: 96)
                    .padding(.top, 70)
                Text("Ask Botan")
                    .font(.title2.weight(.semibold))
                Text("About your agents, your services and what you allowed. Apple's model answers on your iPhone: nothing leaves it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
                VStack(spacing: 8) {
                    ForEach(Self.suggestions, id: \.self) { suggestion in
                        Button {
                            Task { await chat.send(suggestion) }
                            Haptics.impact()
                        } label: {
                            Text(suggestion)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .glassPill(Capsule(), interactive: true)
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
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

    // MARK: Conversation

    private var conversation: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(chat.messages) { message in
                    bubble(message)
                        .id(message.id)
                        .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .animation(.spring(duration: 0.35), value: chat.messages.count)
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
                    .background(Color.botan, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
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
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 40, height: 20)
                    } else {
                        Text(Self.styled(message.text))
                            .font(.body)
                            .foregroundStyle(message.failed ? .secondary : .primary)
                            .textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.09), in: RoundedRectangle(cornerRadius: 19, style: .continuous))
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
                send()
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
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private func send() {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !chat.answering else { return }
        dictation.stop()
        text = ""
        Haptics.impact()
        Task { await chat.send(question) }
    }
}
