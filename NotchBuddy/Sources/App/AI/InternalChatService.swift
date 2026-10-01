import Foundation
import Combine

@MainActor
final class InternalChatService: ObservableObject {
    static let shared = InternalChatService()

    @Published private(set) var selectedProviderID: ProviderID
    @Published private(set) var selectedModelID: String
    @Published private(set) var selectedReasoningID: String?
    @Published private(set) var models: [ModelDescriptor] = []
    @Published private(set) var isLoadingModels = false
    @Published private(set) var selectionWarning: String?

    let availableProviders: [ProviderID] = [.anthropic, .openAI, .google]

    private let registry: ProviderRegistry
    private var conversations: [ProviderID: [AIChatMessage]] = [:]
    private var conversationAttachments: [ProviderID: [ChatAttachment]] = [:]
    private var catalogTask: Task<Void, Never>?

    private let systemPrompt = """
    You are Mochi, Louis's personal AI assistant embedded in the notch of his Mac. \
    You have web search access and can help with absolutely anything — research, coding, finding places, recommendations, tasks, questions. \
    Respond in the user's language. Be thorough and complete — use as much detail as the task requires. \
    No markdown formatting (no **, no ##, no bullet dashes). Use plain text with line breaks.
    """

    private init() {
        let providers: [any AIProvider] = [AnthropicProvider(), OpenAIProvider(), GeminiProvider()]
        registry = ProviderRegistry(providers: providers)

        let savedProvider = UserDefaults.standard.string(forKey: Self.providerKey)
            .flatMap(ProviderID.init(rawValue:))
        let initialProvider = savedProvider.flatMap {
            [ProviderID.anthropic, .openAI, .google].contains($0) ? $0 : nil
        } ?? .anthropic
        selectedProviderID = initialProvider
        selectedModelID = UserDefaults.standard.string(forKey: Self.modelKey(initialProvider))
            ?? Self.fallbackModelID(for: initialProvider)
        selectedReasoningID = UserDefaults.standard.string(
            forKey: Self.reasoningKey(initialProvider)
        )
    }

    deinit {
        catalogTask?.cancel()
    }

    func loadModels(forceRefresh: Bool = false) {
        let providerID = selectedProviderID
        catalogTask?.cancel()
        isLoadingModels = true
        catalogTask = Task { [weak self] in
            guard let self else { return }
            let discovered: [ModelDescriptor]
            if let provider = await registry.provider(for: providerID) {
                discovered = (try? await provider.listModels(forceRefresh: forceRefresh)) ?? []
            } else {
                discovered = []
            }
            guard !Task.isCancelled, selectedProviderID == providerID else { return }
            models = discovered
            isLoadingModels = false
            reconcileSelection()
        }
    }

    func selectProvider(_ providerID: ProviderID, state: AppState) {
        guard availableProviders.contains(providerID), selectedProviderID != providerID else { return }
        selectedProviderID = providerID
        UserDefaults.standard.set(providerID.rawValue, forKey: Self.providerKey)
        selectedModelID = UserDefaults.standard.string(forKey: Self.modelKey(providerID))
            ?? Self.fallbackModelID(for: providerID)
        selectedReasoningID = UserDefaults.standard.string(forKey: Self.reasoningKey(providerID))
        models = []
        state.chatHistory = []
        state.promptContext = nil
        loadModels()
    }

    func selectModel(_ modelID: String) {
        guard models.contains(where: { $0.id == modelID }) else { return }
        selectedModelID = modelID
        selectionWarning = nil
        UserDefaults.standard.set(modelID, forKey: Self.modelKey(selectedProviderID))
        reconcileReasoningSelection()
    }

    func selectReasoning(_ optionID: String?) {
        let option = selectedModel?.reasoningOptions.first(where: { $0.id == optionID })
        selectedReasoningID = option?.id
        if let option {
            UserDefaults.standard.set(option.id, forKey: Self.reasoningKey(selectedProviderID))
        } else {
            UserDefaults.standard.removeObject(forKey: Self.reasoningKey(selectedProviderID))
        }
    }

    func chat(query: String, context: PromptContext?, state: AppState) async {
        let providerID = selectedProviderID
        guard let provider = await registry.provider(for: providerID) else {
            showError("Selected AI provider is unavailable.", state: state)
            return
        }
        guard selectedModel != nil else {
            showError("The selected model is unavailable. Choose another model.", state: state)
            return
        }

        var messages = conversations[providerID] ?? []
        var attachments = conversationAttachments[providerID] ?? []
        var userText = ""

        if messages.isEmpty, let context {
            switch context {
            case .window(let app, let title, let url):
                var text = "Context — App: \(app), Window: \(title)"
                if let url { text += ", URL: \(url)" }
                userText += "\(text)\n\n"
            case .file(let name, let fileURL):
                if let fileURL { attachments.append(attachment(name: name, url: fileURL)) }
                userText += "File: \(name)\n\n"
            }
        }
        userText += query
        messages.append(AIChatMessage(id: UUID(), role: .user, content: userText))

        let modelID = selectedModelID
        let reasoning = selectedModel?.reasoningOptions
            .first(where: { $0.id == selectedReasoningID })
            .map { ReasoningSelection(optionID: $0.id, providerValue: $0.providerValue) }

        do {
            let response = try await provider.chat(
                ChatRequest(
                    modelID: modelID,
                    messages: messages,
                    systemPrompt: systemPrompt,
                    reasoning: reasoning,
                    attachments: attachments,
                    tools: [],
                    webSearch: provider.capabilities.webSearch,
                    maxOutputTokens: 4096
                )
            )
            guard selectedProviderID == providerID else { return }
            messages.append(response.message)
            conversations[providerID] = messages
            conversationAttachments[providerID] = attachments
            state.chatHistory.append(
                ChatMessage(role: .assistant, content: response.message.content)
            )
            state.stateOverride = nil
            state.view = .prompt
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        } catch {
            guard selectedProviderID == providerID else { return }
            showError(error.localizedDescription, state: state)
        }
    }

    var selectedModel: ModelDescriptor? {
        models.first(where: { $0.id == selectedModelID })
    }

    var providerDisplayName: String {
        switch selectedProviderID {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .google: "Google"
        }
    }

    private func reconcileSelection() {
        if models.contains(where: { $0.id == selectedModelID }) {
            selectionWarning = nil
            reconcileReasoningSelection()
            return
        }
        selectionWarning = models.isEmpty
            ? "No models are available for this provider."
            : "\(selectedModelID) is unavailable. Choose a replacement."
        selectedReasoningID = nil
    }

    private func reconcileReasoningSelection() {
        guard let model = selectedModel, !model.reasoningOptions.isEmpty else {
            selectReasoning(nil)
            return
        }
        if !model.reasoningOptions.contains(where: { $0.id == selectedReasoningID }) {
            selectReasoning(model.reasoningOptions.first(where: { $0.id == "medium" })?.id
                ?? model.reasoningOptions.first?.id)
        }
    }

    private func showError(_ message: String, state: AppState) {
        state.stateOverride = .error
        state.noteMessage = message
        state.view = .note
    }

    private func attachment(name: String, url: URL) -> ChatAttachment {
        let mediaType = switch url.pathExtension.lowercased() {
        case "pdf": "application/pdf"
        case "jpg", "jpeg": "image/jpeg"
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: "text/plain"
        }
        return ChatAttachment(id: UUID(), name: name, mediaType: mediaType, location: url)
    }

    private static let providerKey = "internalChat.provider"

    private static func modelKey(_ provider: ProviderID) -> String {
        "internalChat.model.\(provider.rawValue)"
    }

    private static func reasoningKey(_ provider: ProviderID) -> String {
        "internalChat.reasoning.\(provider.rawValue)"
    }

    private static func fallbackModelID(for provider: ProviderID) -> String {
        switch provider {
        case .anthropic: AnthropicProvider.defaultModelID
        case .openAI: OpenAIProvider.defaultModelID
        case .google: ""
        }
    }
}
