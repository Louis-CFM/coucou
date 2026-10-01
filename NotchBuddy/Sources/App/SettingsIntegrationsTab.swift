import SwiftUI

struct SettingsIntegrationsTab: View {
    @ObservedObject private var state = AppState.shared
    @State private var status: SettingsStatus?

    @State private var resendKey: String    = KeychainStore.shared.get("resend-api-key")  ?? ""
    @State private var resendFrom: String   = KeychainStore.shared.get("resend-from")     ?? ""
    @State private var n8nUrl: String       = KeychainStore.shared.get("n8n-url")         ?? ""
    @State private var n8nKey: String       = KeychainStore.shared.get("n8n-api-key")     ?? ""
    @State private var vercelToken: String  = KeychainStore.shared.get("vercel-token")    ?? ""
    @State private var githubToken: String  = KeychainStore.shared.get("github-token")    ?? ""
    @State private var stripeKey: String    = KeychainStore.shared.get("stripe-api-key")  ?? ""
    @State private var calcomKey: String    = KeychainStore.shared.get("calcom-api-key")  ?? ""
    @State private var notionKey: String    = KeychainStore.shared.get("notion-api-key")  ?? ""

    @State private var vercelProjects: [String] = []
    @State private var loadingVercel: Bool = false
    @State private var n8nWorkflows: [String] = []
    @State private var loadingN8n: Bool = false

    var body: some View {
        SettingsPage(status: status) {
            Section {
                SecureField("API key", text: $resendKey, prompt: Text(verbatim: "re_…"))
                TextField("From address", text: $resendFrom, prompt: Text(verbatim: "you@yourdomain.com"))
            } header: {
                IntegrationHeader(name: "Resend", color: "#22C55E", configured: !resendKey.isEmpty)
            }

            Section {
                TextField("Instance URL", text: $n8nUrl, prompt: Text(verbatim: "https://…"))
                SecureField("API key", text: $n8nKey)
                IntegrationFilterRow(
                    label: "Workflows",
                    items: n8nWorkflows,
                    filter: $state.n8nWorkflowFilter,
                    loading: loadingN8n,
                    onLoad: loadN8nWorkflows
                )
            } header: {
                IntegrationHeader(name: "n8n", color: "#F29B38", configured: !n8nKey.isEmpty && !n8nUrl.isEmpty)
            }

            Section {
                SecureField("Token", text: $vercelToken)
                IntegrationFilterRow(
                    label: "Projects",
                    items: vercelProjects,
                    filter: $state.vercelProjectFilter,
                    loading: loadingVercel,
                    onLoad: loadVercelProjects
                )
            } header: {
                IntegrationHeader(name: "Vercel", color: "#7C5CFF", configured: !vercelToken.isEmpty)
            }

            Section {
                SecureField("Personal Access Token", text: $githubToken)
            } header: {
                IntegrationHeader(name: "GitHub", color: "#F4505E", configured: !githubToken.isEmpty)
            }

            Section {
                SecureField("Secret key", text: $stripeKey, prompt: Text(verbatim: "sk_live_… / sk_test_…"))
            } header: {
                IntegrationHeader(name: "Stripe", color: "#0570DE", configured: !stripeKey.isEmpty)
            }

            Section {
                SecureField("API key", text: $calcomKey, prompt: Text(verbatim: "cal_live_…"))
            } header: {
                IntegrationHeader(name: "Cal.com", color: "#C9956A", configured: !calcomKey.isEmpty)
            }

            Section {
                SecureField("Integration token", text: $notionKey, prompt: Text(verbatim: "secret_…"))
            } header: {
                IntegrationHeader(name: "Notion", color: "#E8E8E8", configured: !notionKey.isEmpty)
            }

            Section {
                TextField("Runtime JSON path", text: $state.orcaRuntimePath, prompt: Text("Auto-detect"))
            } header: {
                IntegrationHeader(name: "Orca", color: "#FF6B5B", configured: orcaDetected)
            } footer: {
                Group {
                    if orcaDetected {
                        Text("Runtime detected — polled every 5 s")
                    } else {
                        Text("Not found — launch Orca.app to receive alerts")
                    }
                }
                .font(.system(size: 11))
                .foregroundColor(.secondary)
            }

            Section {
                HStack {
                    Text("Keys are stored in the macOS Keychain.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Save integrations") { saveIntegrations() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var orcaDetected: Bool {
        FileManager.default.fileExists(atPath: state.orcaRuntimeFilePath)
    }

    // MARK: - Keychain

    private func saveIntegrations() {
        saveKey("resend-api-key",  value: resendKey)
        saveKey("resend-from",     value: resendFrom)
        saveKey("n8n-url",         value: n8nUrl)
        saveKey("n8n-api-key",     value: n8nKey)
        saveKey("vercel-token",    value: vercelToken)
        saveKey("github-token",    value: githubToken)
        saveKey("stripe-api-key",  value: stripeKey)
        saveKey("calcom-api-key",  value: calcomKey)
        saveKey("notion-api-key",  value: notionKey)
        status = .success(String(localized: "Integration keys saved."))
    }

    /// Saves non-empty value; removes only if key was previously set (explicit user clear).
    private func saveKey(_ key: String, value: String) {
        if value.isEmpty {
            KeychainStore.shared.remove(key)
        } else {
            KeychainStore.shared.set(key, value: value)
        }
    }

    // MARK: - Vercel project list

    private func loadVercelProjects() {
        guard let token = KeychainStore.shared.get("vercel-token") else {
            status = .failure(String(localized: "Save Vercel token first."))
            return
        }
        loadingVercel = true
        guard let url = URL(string: "https://api.vercel.com/v9/projects?limit=100") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let names: [String]
            if let data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let projects = json["projects"] as? [[String: Any]] {
                names = projects.compactMap { $0["name"] as? String }.sorted()
            } else {
                names = []
            }
            DispatchQueue.main.async {
                self.vercelProjects = names
                self.loadingVercel = false
                if names.isEmpty { self.status = .failure(String(localized: "No Vercel projects found.")) }
            }
        }.resume()
    }

    // MARK: - n8n workflow list

    private func loadN8nWorkflows() {
        guard let apiKey  = KeychainStore.shared.get("n8n-api-key"),
              let rawBase = KeychainStore.shared.get("n8n-url") else {
            status = .failure(String(localized: "Save n8n URL and API key first."))
            return
        }
        loadingN8n = true
        let base = rawBase.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let urls = ["\(base)/api/v1/workflows?limit=100", "\(base)/rest/workflows?limit=100"]
        fetchN8nWorkflows(urls: urls, apiKey: apiKey, idx: 0)
    }

    private func fetchN8nWorkflows(urls: [String], apiKey: String, idx: Int) {
        guard idx < urls.count, let url = URL(string: urls[idx]) else {
            DispatchQueue.main.async {
                self.loadingN8n = false
                self.status = .failure(String(localized: "No n8n workflows found."))
            }
            return
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue(apiKey, forHTTPHeaderField: "X-N8N-API-KEY")
        URLSession.shared.dataTask(with: req) { data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200 else {
                self.fetchN8nWorkflows(urls: urls, apiKey: apiKey, idx: idx + 1)
                return
            }
            let items: [[String: Any]]
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let arr = obj["data"] as? [[String: Any]] { items = arr }
            else if let arr = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] { items = arr }
            else { items = [] }
            let names = items.compactMap { $0["name"] as? String }.sorted()
            DispatchQueue.main.async {
                self.n8nWorkflows = names
                self.loadingN8n = false
                if names.isEmpty { self.status = .failure(String(localized: "No n8n workflows found.")) }
            }
        }.resume()
    }
}
