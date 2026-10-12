import SwiftUI

/// Settings → Chat → "More providers": add any OpenAI-compatible provider from the bundled
/// catalog or by URL, and find AI servers already running on this Mac.
struct CustomProvidersSettings: View {
    @ObservedObject private var state = AppState.shared

    @State private var catalog: [ProviderCatalogEntry] = []
    @State private var showForm = false
    @State private var search = ""
    @State private var name = ""
    @State private var urlText = ""
    @State private var apiKey = ""
    @State private var needsKey = true
    @State private var keyHint = ""
    @State private var busy = false
    @State private var pendingRemoval: CustomProvider?
    /// A leading "❌" marks an error, like the status line of the other Settings sections.
    @State private var message = ""

    private static let suggestionCount = 6

    var body: some View {
        GroupBox("More providers") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add any provider that speaks the OpenAI chat API: pick one from the list or enter its URL. Keys stay in your Keychain.")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)

                ForEach(state.customProviders) { provider in
                    providerRow(provider)
                }

                HStack(spacing: 8) {
                    Button(showForm ? "Cancel" : "Add provider") {
                        if showForm { resetForm() } else { showForm = true; message = "" }
                    }
                    .buttonStyle(.bordered)
                }

                if showForm { form }

                if !message.isEmpty {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundColor(message.hasPrefix("❌") ? .red : .secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.vertical, 4)
        }
        .onAppear { if catalog.isEmpty { catalog = CustomProviderClient.loadCatalog() } }
        .confirmationDialog(
            String(format: String(localized: "Remove %@?"), pendingRemoval?.name ?? ""),
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let provider = pendingRemoval { state.removeCustomProvider(id: provider.id) }
                pendingRemoval = nil
            }
        } message: {
            Text("Its API key is deleted from your Keychain.")
        }
    }

    // MARK: Rows

    private func providerRow(_ provider: CustomProvider) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color(hex: provider.colorHex)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).font(.system(size: 12, weight: .semibold))
                Text(provider.baseURL)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button("Remove") { pendingRemoval = provider }
                .buttonStyle(.bordered)
        }
    }

    // MARK: Add form

    private var suggestions: [ProviderCatalogEntry] {
        Array(CustomProviders.search(catalog, search).prefix(Self.suggestionCount))
    }

    @ViewBuilder private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search providers (Groq, OpenRouter, Mistral…)", text: $search)
                .textFieldStyle(.roundedBorder)
            if !catalog.isEmpty {
                ForEach(suggestions) { entry in
                    Button { pick(entry) } label: {
                        HStack {
                            Text(entry.name).font(.system(size: 12))
                            Spacer()
                            Text(URL(string: entry.baseURL)?.host ?? "")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            TextField("API URL  (https://…/v1)", text: $urlText)
                .textFieldStyle(.roundedBorder)
            Toggle("This server needs an API key", isOn: $needsKey)
            if needsKey {
                SecureField("API key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                if !keyHint.isEmpty {
                    Text(keyHint)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Button(busy ? "Testing…" : "Test and add") {
                Task { await add() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(busy)
        }
    }

    private func pick(_ entry: ProviderCatalogEntry) {
        name = entry.name
        urlText = entry.baseURL
        needsKey = true
        keyHint = entry.keyEnv.map { String(format: String(localized: "Usually called %@."), $0) } ?? ""
        search = ""
    }

    private func resetForm() {
        showForm = false
        search = ""; name = ""; urlText = ""; apiKey = ""; keyHint = ""
        needsKey = true
    }

    // MARK: Actions

    private func add() async {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { message = "❌ " + String(localized: "Enter a name."); return }
        guard let base = CustomProviders.normaliseBaseURL(urlText) else {
            message = "❌ " + String(localized: "Enter the full API URL, starting with https://"); return
        }
        guard CustomProviders.isTransportAllowed(base) else {
            message = "❌ " + String(localized: "Use https://. Plain http is only allowed for this Mac and your local network."); return
        }
        guard !state.customProviders.contains(where: { $0.baseURL == base }) else {
            message = "❌ " + String(localized: "This URL is already added."); return
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needsKey || !key.isEmpty else { message = "❌ " + String(localized: "Paste the API key."); return }

        busy = true
        defer { busy = false }
        switch await CustomProviderClient.fetchModels(baseURL: base, apiKey: needsKey ? key : nil) {
        case .success(let models):
            guard let first = models.first else {
                message = "❌ " + String(localized: "The server has no chat models."); return
            }
            let id = CustomProviders.slug(from: trimmedName, existing: state.customProviders.map(\.id))
            state.addCustomProvider(
                CustomProvider(id: id, name: trimmedName, baseURL: base, requiresKey: needsKey,
                               model: first.id, colorHex: CustomProviders.color(forID: id)),
                apiKey: needsKey ? key : "")
            message = String(format: String(localized: "Added %@ with %lld models. Pick it above the chat box."),
                             trimmedName, Int64(models.count))
            resetForm()
        case .failure(.unauthorized):
            message = "❌ " + String(localized: "The server rejected the API key.")
        case .failure(.notAModelList):
            message = "❌ " + String(localized: "That URL did not return a model list. Check it ends with the version path, like /v1.")
        case .failure(.unreachable):
            message = "❌ " + String(localized: "Cannot reach the server.")
        }
    }
}
