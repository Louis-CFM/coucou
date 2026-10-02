// Provider catalog — the mirror of `windows/src-tauri/src/providers.rs`.
//
// Same table, same ids, same dialects, same "unavailable" reasons. Keep the two in
// lockstep: an id is a contract value (it names the Keychain item and the settings
// key), so changing one side without the other orphans a stored credential on one
// platform. `every_provider_in_omp_catalog_is_listed_here` in providers.rs pins the
// Rust side; this file has no test of its own yet, which is exactly why it drifted once.
//
// Modelled on omp's provider catalog (`packages/catalog/src/compat/rules/providers/*.kdl`)
// but only as far as Coucou can drive it. Coucou speaks two wire shapes and has no
// OAuth, so this is the honest subset of omp's 85 providers — the rest are listed
// carrying the reason they are greyed out.

import Foundation

// MARK: - Dialect

/// The two request shapes Coucou speaks. omp has sixteen `KnownApi` transports; these
/// are the two this app implements natively (`ClaudeService` already does both).
enum ChatDialect: String, Codable, CaseIterable, Sendable {
    /// `POST {base}/v1/messages`, `x-api-key` header.
    case anthropic
    /// `POST {base}/chat/completions`, `Authorization: Bearer`.
    case openAI

    var endpointSuffix: String {
        switch self {
        case .anthropic: "/v1/messages"
        case .openAI: "/chat/completions"
        }
    }

    func endpoint(baseURL: String) -> String {
        let base = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return base + endpointSuffix
    }
}

// MARK: - Provider

struct ChatProviderDef: Identifiable, Sendable {
    let id: String
    let label: String
    let dialect: ChatDialect
    /// Base URL without a trailing slash.
    let baseURL: String
    let defaultModel: String
    /// omp's environment variable for this provider, shown in Settings as a hint. This
    /// app does not read the environment.
    let envVar: String?
    let accentHex: String
    /// Local engines answer without a key.
    let keyless: Bool
    /// `nil` when the app can drive it; otherwise the reason it is greyed out.
    let unavailable: String?
}

// MARK: - Catalog

enum ProviderCatalog {

    /// The id a custom gateway gets. Not in the table: its endpoint, dialect and model
    /// come from settings, its key from the Keychain under `provider-custom`.
    static let customID = "custom"

    static let all: [ChatProviderDef] =
        gateways + hosted + secondWave + localEngines + unreachable

    static func definition(for id: String) -> ChatProviderDef? {
        all.first { $0.id == id }
    }

    /// True when the id names a provider the app can actually call — a table entry
    /// that is not marked unavailable, or the custom gateway.
    static func isRoutable(_ id: String) -> Bool {
        if id == customID { return true }
        guard let def = definition(for: id) else { return false }
        return def.unavailable == nil
    }

    /// Keychain item name for a provider's credential. Provider ids and the custom id
    /// are the only accepted prefix, so the Settings UI still cannot write an
    /// arbitrary key name.
    static func keychainKey(for id: String) -> String {
        "provider-\(id)"
    }

    // MARK: Routing

    /// Everything needed to build one request. Mirrors `providers::Route` on the Rust
    /// side, field for field.
    struct Route {
        let label: String
        let dialect: ChatDialect
        let baseURL: String
        let keychainKey: String
        let model: String
    }

    /// The values a route is built from. Passed in rather than read from `AppState` so
    /// this type stays a pure function of its arguments — `AppState` calls it.
    struct RouteInput {
        let customBaseURL: String
        let customModel: String
        let customDialect: ChatDialect
        /// Model override per provider id.
        let providerModels: [String: String]
        /// The model Anthropic used before providers existed, so an existing default
        /// survives the move to `providerModels`.
        let legacyClaudeModel: String
        let legacyClaudeModelDefault: String
    }

    static func route(for id: String, input: RouteInput) -> Route? {
        if id == customID {
            let base = input.customBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base.isEmpty,
                  base.hasPrefix("https://") || base.hasPrefix("http://")
            else { return nil }
            let model = input.customModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !model.isEmpty else { return nil }
            return Route(label: "Custom gateway",
                         dialect: input.customDialect,
                         baseURL: base,
                         keychainKey: keychainKey(for: customID),
                         model: model)
        }
        guard let def = definition(for: id), def.unavailable == nil else { return nil }
        return Route(label: def.label,
                     dialect: def.dialect,
                     baseURL: def.baseURL,
                     keychainKey: keychainKey(for: def.id),
                     model: model(for: def, input: input))
    }

    static func model(for def: ChatProviderDef, input: RouteInput) -> String {
        if let m = input.providerModels[def.id], !m.isEmpty { return m }
        if def.id == "anthropic",
           !input.legacyClaudeModel.isEmpty,
           input.legacyClaudeModel != input.legacyClaudeModelDefault {
            return input.legacyClaudeModel
        }
        return def.defaultModel
    }

    // MARK: - First-party and gateways

    private static let gateways: [ChatProviderDef] = [
        ChatProviderDef(id: "anthropic", label: "Anthropic", dialect: .anthropic,
                        baseURL: "https://api.anthropic.com", defaultModel: "claude-opus-5",
                        envVar: "ANTHROPIC_API_KEY", accentHex: "#E07950",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "openai", label: "OpenAI", dialect: .openAI,
                        baseURL: "https://api.openai.com/v1", defaultModel: "gpt-4o",
                        envVar: "OPENAI_API_KEY", accentHex: "#10A37F",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "google", label: "Google AI", dialect: .openAI,
                        baseURL: "https://generativelanguage.googleapis.com/v1beta/openai",
                        defaultModel: "gemini-2.0-flash", envVar: "GEMINI_API_KEY",
                        accentHex: "#4285F4", keyless: false, unavailable: nil),
        ChatProviderDef(id: "openrouter", label: "OpenRouter", dialect: .openAI,
                        baseURL: "https://openrouter.ai/api/v1", defaultModel: "openai/gpt-5.5",
                        envVar: "OPENROUTER_API_KEY", accentHex: "#6467F2",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "vercel-ai-gateway", label: "Vercel AI Gateway", dialect: .openAI,
                        baseURL: "https://ai-gateway.vercel.sh/v1", defaultModel: "openai/gpt-5.5",
                        envVar: "AI_GATEWAY_API_KEY", accentHex: "#7C5CFF",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "singularityapi-dev", label: "SingularityAPI", dialect: .openAI,
                        baseURL: "https://api.singularityapi.dev/v1",
                        defaultModel: "deepseek/deepseek-v4-pro",
                        envVar: "SINGULARITYAPI_DEV_API_KEY", accentHex: "#8B5CF6",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "aimlapi", label: "AIMLAPI", dialect: .openAI,
                        baseURL: "https://api.aimlapi.com/v1", defaultModel: "gpt-5.5",
                        envVar: "AIMLAPI_API_KEY", accentHex: "#22D3EE",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "commandcode", label: "Command Code", dialect: .openAI,
                        baseURL: "https://api.commandcode.ai/provider",
                        defaultModel: "claude-sonnet-5.5", envVar: "COMMAND_CODE_API_KEY",
                        accentHex: "#0EA5E9", keyless: false, unavailable: nil),
    ]

    // MARK: - Hosted inference

    private static let hosted: [ChatProviderDef] = [
        ChatProviderDef(id: "groq", label: "Groq", dialect: .openAI,
                        baseURL: "https://api.groq.com/openai/v1",
                        defaultModel: "llama-3.3-70b-versatile", envVar: "GROQ_API_KEY",
                        accentHex: "#F55036", keyless: false, unavailable: nil),
        ChatProviderDef(id: "mistral", label: "Mistral", dialect: .openAI,
                        baseURL: "https://api.mistral.ai/v1", defaultModel: "mistral-large-latest",
                        envVar: "MISTRAL_API_KEY", accentHex: "#FA520F",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "xai", label: "xAI", dialect: .openAI,
                        baseURL: "https://api.x.ai/v1", defaultModel: "grok-4.6",
                        envVar: "XAI_API_KEY", accentHex: "#000000",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "deepseek", label: "DeepSeek", dialect: .openAI,
                        baseURL: "https://api.deepseek.com", defaultModel: "deepseek-chat",
                        envVar: "DEEPSEEK_API_KEY", accentHex: "#4D6BFE",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "cerebras", label: "Cerebras", dialect: .openAI,
                        baseURL: "https://api.cerebras.ai/v1", defaultModel: "llama-3.3-70b",
                        envVar: "CEREBRAS_API_KEY", accentHex: "#F26722",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "together", label: "Together AI", dialect: .openAI,
                        baseURL: "https://api.together.xyz/v1",
                        defaultModel: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
                        envVar: "TOGETHER_API_KEY", accentHex: "#0F6FFF",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "fireworks", label: "Fireworks AI", dialect: .openAI,
                        baseURL: "https://api.fireworks.ai/inference/v1",
                        defaultModel: "accounts/fireworks/models/kimi-k2-instruct",
                        envVar: "FIREWORKS_API_KEY", accentHex: "#5019C5",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "deepinfra", label: "DeepInfra", dialect: .openAI,
                        baseURL: "https://api.deepinfra.com/v1/openai",
                        defaultModel: "meta-llama/Llama-3.3-70B-Instruct",
                        envVar: "DEEPINFRA_API_KEY", accentHex: "#5B6CFF",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "huggingface", label: "Hugging Face", dialect: .openAI,
                        baseURL: "https://router.huggingface.co/v1",
                        defaultModel: "meta-llama/Llama-3.3-70B-Instruct",
                        envVar: "HUGGINGFACE_HUB_TOKEN", accentHex: "#FFD21E",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "nvidia", label: "NVIDIA", dialect: .openAI,
                        baseURL: "https://integrate.api.nvidia.com/v1",
                        defaultModel: "meta/llama-3.3-70b-instruct", envVar: "NVIDIA_API_KEY",
                        accentHex: "#76B900", keyless: false, unavailable: nil),
        ChatProviderDef(id: "novita", label: "Novita AI", dialect: .openAI,
                        baseURL: "https://api.novita.ai/openai/v1",
                        defaultModel: "deepseek/deepseek-v3.1", envVar: "NOVITA_API_KEY",
                        accentHex: "#16A34A", keyless: false, unavailable: nil),
        ChatProviderDef(id: "venice", label: "Venice AI", dialect: .openAI,
                        baseURL: "https://api.venice.ai/api/v1", defaultModel: "venice-3",
                        envVar: "VENICE_API_KEY", accentHex: "#FF4D6D",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "stepfun", label: "StepFun", dialect: .openAI,
                        baseURL: "https://api.stepfun.ai/v1", defaultModel: "step-3.5-flash",
                        envVar: "STEPFUN_API_KEY", accentHex: "#6D28D9",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "baseten", label: "Baseten", dialect: .openAI,
                        baseURL: "https://inference.baseten.co/v1",
                        defaultModel: "deepseek-ai/DeepSeek-V3", envVar: "BASETEN_API_KEY",
                        accentHex: "#111827", keyless: false, unavailable: nil),
        ChatProviderDef(id: "coreweave", label: "CoreWeave", dialect: .openAI,
                        baseURL: "https://api.inference.wandb.ai/v1",
                        defaultModel: "meta-llama/llama-3.3-70b-instruct",
                        envVar: "COREWEAVE_API_KEY", accentHex: "#7F56D9",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "helmcode", label: "HelmCode", dialect: .openAI,
                        baseURL: "https://api.helmcode.com/v1", defaultModel: "kimi-k2.6",
                        envVar: "HELMCODE_API_KEY", accentHex: "#D0BCFF",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "aiand", label: "AI&", dialect: .openAI,
                        baseURL: "https://api.aiand.com/v1", defaultModel: "gpt-5.5",
                        envVar: "AIAND_API_KEY", accentHex: "#12B76A",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "gmi-cloud", label: "GMI Cloud", dialect: .openAI,
                        baseURL: "https://api.gmi-serving.com/v1", defaultModel: "deepseek-v4-pro",
                        envVar: "GMI_API_KEY", accentHex: "#2563EB",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "meta", label: "Meta AI", dialect: .openAI,
                        baseURL: "https://api.meta.ai/v1", defaultModel: "gpt-5.5",
                        envVar: "MODEL_API_KEY", accentHex: "#0081FB",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "sakana", label: "Sakana AI", dialect: .openAI,
                        baseURL: "https://api.sakana.ai/v1", defaultModel: "sakana-ai-scientist",
                        envVar: "SAKANA_API_KEY", accentHex: "#7E22CE",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "abliteration", label: "Abliteration", dialect: .openAI,
                        baseURL: "https://api.abliteration.ai/v1", defaultModel: "gpt-5.5",
                        envVar: "ABLITERATION_API_KEY", accentHex: "#EF4444",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "alibaba-coding-plan", label: "Alibaba Coding Plan", dialect: .openAI,
                        baseURL: "https://coding-intl.dashscope.aliyuncs.com/v1",
                        defaultModel: "qwen3-coder-plus", envVar: "ALIBABA_CODING_PLAN_API_KEY",
                        accentHex: "#FF6A00", keyless: false, unavailable: nil),
        ChatProviderDef(id: "alibaba-token-plan", label: "Alibaba Token Plan", dialect: .openAI,
                        baseURL: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
                        defaultModel: "qwen3-coder-plus", envVar: "ALIBABA_TOKEN_PLAN_API_KEY",
                        accentHex: "#F97316", keyless: false, unavailable: nil),
        ChatProviderDef(id: "charm-hyper", label: "Charm Hyper", dialect: .openAI,
                        baseURL: "https://hyper.charm.land/v1", defaultModel: "glm-5.1",
                        envVar: "CHARM_HYPER_API_KEY", accentHex: "#A3E635",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "yolo-auto", label: "Yolo Auto", dialect: .openAI,
                        baseURL: "https://yolo-auto.com/v1", defaultModel: "claude-opus-5",
                        envVar: "YOLO_AUTO_API_KEY", accentHex: "#FACC15",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "xiaomi-token-plan-cn", label: "Xiaomi Token Plan (CN)",
                        dialect: .openAI, baseURL: "https://token-plan-cn.xiaomimimo.com/v1",
                        defaultModel: "mimo-v2.5", envVar: "XIAOMI_TOKEN_PLAN_CN_API_KEY",
                        accentHex: "#FF6900", keyless: false, unavailable: nil),
        ChatProviderDef(id: "qianfan", label: "Baidu Qianfan", dialect: .openAI,
                        baseURL: "https://qianfan.baidubce.com/v2",
                        defaultModel: "ernie-4.5-turbo-128k", envVar: "QIANFAN_API_KEY",
                        accentHex: "#2932E1", keyless: false, unavailable: nil),
        ChatProviderDef(id: "zai", label: "Z.ai", dialect: .anthropic,
                        baseURL: "https://api.z.ai/api/anthropic", defaultModel: "glm-4.7",
                        envVar: "ZAI_API_KEY", accentHex: "#2C6FF3",
                        keyless: false, unavailable: nil),
    ]

    // MARK: - Second wave
    //
    // Added after auditing this table against every `provider "…"` block in omp's
    // `rules/providers/*.kdl`, the way providers.rs was. Base URLs come from omp's
    // `openAiCompletionsDescriptor` / `anthropicMessagesDescriptor` calls and its
    // `getDefaultModelDiscoveryBaseUrl` helper; none of these were written from memory.

    private static let secondWave: [ChatProviderDef] = [
        ChatProviderDef(id: "opencode-zen", label: "OpenCode Zen", dialect: .openAI,
                        baseURL: "https://opencode.ai/zen/v1", defaultModel: "claude-opus-5",
                        envVar: "OPENCODE_API_KEY", accentHex: "#E5E5E5",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "opencode-go", label: "OpenCode Go", dialect: .openAI,
                        baseURL: "https://opencode.ai/zen/go/v1", defaultModel: "kimi-k2.7-code",
                        envVar: "OPENCODE_API_KEY", accentHex: "#10B981",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "moonshot", label: "Moonshot", dialect: .openAI,
                        baseURL: "https://api.moonshot.ai/v1", defaultModel: "kimi-k2.7-code",
                        envVar: "MOONSHOT_API_KEY", accentHex: "#6D28D9",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "siliconflow", label: "SiliconFlow", dialect: .openAI,
                        baseURL: "https://api.siliconflow.com/v1",
                        defaultModel: "zai-org/GLM-5.1", envVar: "SILICONFLOW_API_KEY",
                        accentHex: "#7C3AED", keyless: false, unavailable: nil),
        ChatProviderDef(id: "siliconflow-cn", label: "SiliconFlow CN", dialect: .openAI,
                        baseURL: "https://api.siliconflow.cn/v1",
                        defaultModel: "deepseek-ai/DeepSeek-V4-Pro",
                        envVar: "SILICONFLOW_CN_API_KEY", accentHex: "#A855F7",
                        keyless: false, unavailable: nil),
        // omp serves plain MiniMax over Anthropic Messages.
        ChatProviderDef(id: "minimax", label: "MiniMax", dialect: .anthropic,
                        baseURL: "https://api.minimax.io/anthropic", defaultModel: "MiniMax-M3",
                        envVar: "MINIMAX_API_KEY", accentHex: "#FF4D4D",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "minimax-code", label: "MiniMax Coding Plan", dialect: .openAI,
                        baseURL: "https://api.minimax.io/v1", defaultModel: "MiniMax-M3",
                        envVar: "MINIMAX_CODE_API_KEY", accentHex: "#F97316",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "minimax-code-cn", label: "MiniMax Coding Plan CN", dialect: .openAI,
                        baseURL: "https://api.minimaxi.com/v1", defaultModel: "MiniMax-M3",
                        envVar: "MINIMAX_CODE_CN_API_KEY", accentHex: "#FB923C",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "kilo", label: "Kilo Gateway", dialect: .openAI,
                        baseURL: "https://api.kilo.ai/api/gateway",
                        defaultModel: "anthropic/claude-opus-5", envVar: "KILO_API_KEY",
                        accentHex: "#22D3EE", keyless: false, unavailable: nil),
        ChatProviderDef(id: "zenmux", label: "ZenMux", dialect: .openAI,
                        baseURL: "https://zenmux.ai/api/v1",
                        defaultModel: "anthropic/claude-opus-5", envVar: "ZENMUX_API_KEY",
                        accentHex: "#8B5CF6", keyless: false, unavailable: nil),
        ChatProviderDef(id: "umans", label: "Umans", dialect: .openAI,
                        baseURL: "https://api.code.umans.ai", defaultModel: "umans-coder",
                        envVar: "UMANS_AI_CODING_PLAN_API_KEY", accentHex: "#0EA5E9",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "synthetic", label: "Synthetic", dialect: .openAI,
                        baseURL: "https://api.synthetic.new/openai/v1",
                        defaultModel: "hf:zai-org/GLM-5.3-Flash", envVar: "SYNTHETIC_API_KEY",
                        accentHex: "#3B82F6", keyless: false, unavailable: nil),
        ChatProviderDef(id: "nanogpt", label: "NanoGPT", dialect: .openAI,
                        baseURL: "https://nano-gpt.com/api/v1", defaultModel: "openai/gpt-5.5",
                        envVar: "NANO_GPT_API_KEY", accentHex: "#14B8A6",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "xiaomi", label: "Xiaomi MiMo", dialect: .openAI,
                        baseURL: "https://api.xiaomimimo.com/v1", defaultModel: "mimo-v2.5",
                        envVar: "XIAOMI_API_KEY", accentHex: "#FF6900",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "xiaomi-token-plan-ams", label: "Xiaomi Token Plan (AMS)",
                        dialect: .openAI, baseURL: "https://token-plan-ams.xiaomimimo.com/v1",
                        defaultModel: "mimo-v2.5", envVar: "XIAOMI_TOKEN_PLAN_AMS_API_KEY",
                        accentHex: "#F97316", keyless: false, unavailable: nil),
        ChatProviderDef(id: "xiaomi-token-plan-sgp", label: "Xiaomi Token Plan (SGP)",
                        dialect: .openAI, baseURL: "https://token-plan-sgp.xiaomimimo.com/v1",
                        defaultModel: "mimo-v2.5", envVar: "XIAOMI_TOKEN_PLAN_SGP_API_KEY",
                        accentHex: "#FB923C", keyless: false, unavailable: nil),
        ChatProviderDef(id: "zhipu-coding-plan", label: "Zhipu Coding Plan", dialect: .openAI,
                        baseURL: "https://open.bigmodel.cn/api/coding/paas/v4",
                        defaultModel: "glm-5.1", envVar: "ZHIPU_API_KEY",
                        accentHex: "#2C6FF3", keyless: false, unavailable: nil),
        ChatProviderDef(id: "cline-pass", label: "ClinePass", dialect: .openAI,
                        baseURL: "https://api.cline.bot/api/v1", defaultModel: "kimi-k3",
                        envVar: "CLINE_API_KEY", accentHex: "#D946EF",
                        keyless: false, unavailable: nil),
        ChatProviderDef(id: "firepass", label: "FirePass", dialect: .openAI,
                        baseURL: "https://api.fireworks.ai/inference/v1",
                        defaultModel: "glm-5.2-fast", envVar: "FIREPASS_API_KEY",
                        accentHex: "#7C3AED", keyless: false, unavailable: nil),
        ChatProviderDef(id: "singularityapi-tech", label: "SingularityAPI Tech", dialect: .openAI,
                        baseURL: "https://api.singularityapi.tech/v1",
                        defaultModel: "deepseek-ai/DeepSeek-V4.1-Flash",
                        envVar: "SINGULARITYAPI_TECH_API_KEY", accentHex: "#6366F1",
                        keyless: false, unavailable: nil),
    ]

    // MARK: - Local engines, keyless by default (omp's own rule)

    private static let localEngines: [ChatProviderDef] = [
        ChatProviderDef(id: "ollama", label: "Ollama", dialect: .openAI,
                        baseURL: "http://127.0.0.1:11434/v1", defaultModel: "llama3.2",
                        envVar: "OLLAMA_API_KEY", accentHex: "#111111",
                        keyless: true, unavailable: nil),
        ChatProviderDef(id: "lm-studio", label: "LM Studio", dialect: .openAI,
                        baseURL: "http://127.0.0.1:1234/v1", defaultModel: "local-model",
                        envVar: "LM_STUDIO_API_KEY", accentHex: "#8B5CF6",
                        keyless: true, unavailable: nil),
        // omp calls this `llama.cpp`; the id is kebab-case here because it becomes a
        // Keychain item name (`provider-llama-cpp`) and every other id obeys that shape.
        ChatProviderDef(id: "llama-cpp", label: "llama.cpp", dialect: .openAI,
                        baseURL: "http://127.0.0.1:8080/v1", defaultModel: "local-model",
                        envVar: "LLAMA_CPP_API_KEY", accentHex: "#374151",
                        keyless: true, unavailable: nil),
        // omp publishes these two localhost defaults in getDefaultModelDiscoveryBaseUrl.
        ChatProviderDef(id: "litellm", label: "LiteLLM", dialect: .openAI,
                        baseURL: "http://localhost:4000/v1", defaultModel: "claude-opus-5-5",
                        envVar: "LITELLM_API_KEY", accentHex: "#22C55E",
                        keyless: true, unavailable: nil),
        ChatProviderDef(id: "vllm", label: "vLLM", dialect: .openAI,
                        baseURL: "http://127.0.0.1:8000/v1", defaultModel: "gpt-oss-20b",
                        envVar: "VLLM_API_KEY", accentHex: "#646CFF",
                        keyless: true, unavailable: nil),
    ]

    // MARK: - In omp's catalog, unreachable from this app

    private static let oauthOnly = "Reached through an omp /login flow; Coucou has no OAuth"
    private static let bespoke = "Non-standard wire protocol; omp ships a dedicated transport for it"

    private static let unreachable: [ChatProviderDef] = [
        ChatProviderDef(id: "cursor", label: "Cursor", dialect: .openAI, baseURL: "",
                        defaultModel: "", envVar: "CURSOR_ACCESS_TOKEN", accentHex: "#000000",
                        keyless: false, unavailable: bespoke),
        ChatProviderDef(id: "openai-codex", label: "OpenAI Codex", dialect: .openAI,
                        baseURL: "https://chatgpt.com/backend-api", defaultModel: "gpt-5.5",
                        envVar: "OPENAI_CODEX_OAUTH_TOKEN", accentHex: "#10A37F",
                        keyless: false, unavailable: oauthOnly),
        ChatProviderDef(id: "github-copilot", label: "GitHub Copilot", dialect: .openAI,
                        baseURL: "", defaultModel: "gpt-5.5", envVar: "COPILOT_GITHUB_TOKEN",
                        accentHex: "#6E40C9", keyless: false, unavailable: oauthOnly),
        ChatProviderDef(id: "devin", label: "Devin", dialect: .openAI,
                        baseURL: "https://server.codeium.com", defaultModel: "swe-1-6",
                        envVar: "DEVIN_API_KEY", accentHex: "#4A4A4A",
                        keyless: false, unavailable: bespoke),
        ChatProviderDef(id: "factory-droid", label: "Factory Droid", dialect: .openAI,
                        baseURL: "https://api.factory.ai", defaultModel: "kimi-k3", envVar: nil,
                        accentHex: "#111111", keyless: false, unavailable: bespoke),
        ChatProviderDef(id: "gitlab-duo", label: "GitLab Duo", dialect: .openAI,
                        baseURL: "https://gitlab.com", defaultModel: "duo-chat-opus-4-6",
                        envVar: "GITLAB_TOKEN", accentHex: "#FC6D26",
                        keyless: false, unavailable: bespoke),
        ChatProviderDef(id: "gitlab-duo-agent", label: "GitLab Duo Agent", dialect: .openAI,
                        baseURL: "https://gitlab.com", defaultModel: "claude_sonnet_4_6_vertex",
                        envVar: "GITLAB_TOKEN", accentHex: "#FC6D26",
                        keyless: false, unavailable: bespoke),
        ChatProviderDef(id: "google-gemini-cli", label: "Gemini CLI", dialect: .openAI,
                        baseURL: "", defaultModel: "gemini-3.1-pro-preview", envVar: nil,
                        accentHex: "#4285F4", keyless: false, unavailable: oauthOnly),
        ChatProviderDef(id: "google-antigravity", label: "Google Antigravity", dialect: .openAI,
                        baseURL: "https://daily-cloudcode-pa.googleapis.com",
                        defaultModel: "gemini-3.1-pro", envVar: nil, accentHex: "#EA4335",
                        keyless: false, unavailable: oauthOnly),
        ChatProviderDef(id: "muse-code", label: "Muse Code", dialect: .openAI,
                        baseURL: "https://api.meta.ai/v1", defaultModel: "muse-spark-1.3",
                        envVar: nil, accentHex: "#0081FB", keyless: false, unavailable: oauthOnly),
        ChatProviderDef(id: "xai-oauth", label: "xAI (SuperGrok)", dialect: .openAI,
                        baseURL: "https://api.x.ai/v1", defaultModel: "grok-4.6",
                        envVar: "XAI_OAUTH_TOKEN", accentHex: "#000000",
                        keyless: false, unavailable: oauthOnly),
        ChatProviderDef(id: "kimi-code", label: "Kimi Code", dialect: .openAI, baseURL: "",
                        defaultModel: "kimi-for-coding", envVar: nil, accentHex: "#1F1F1F",
                        keyless: false, unavailable: oauthOnly),
        ChatProviderDef(id: "qwen-portal", label: "Qwen Portal", dialect: .openAI,
                        baseURL: "https://portal.qwen.ai/v1", defaultModel: "coder-model",
                        envVar: "QWEN_OAUTH_TOKEN", accentHex: "#615CED",
                        keyless: false, unavailable: oauthOnly),
        ChatProviderDef(id: "ollama-cloud", label: "Ollama Cloud", dialect: .openAI,
                        baseURL: "", defaultModel: "gpt-oss:120b", envVar: nil,
                        accentHex: "#111111", keyless: false, unavailable: oauthOnly),
        ChatProviderDef(id: "wafer-serverless", label: "Wafer", dialect: .openAI, baseURL: "",
                        defaultModel: "GLM-5.1", envVar: "WAFER_SERVERLESS_API_KEY",
                        accentHex: "#0F766E", keyless: false, unavailable: oauthOnly),
        ChatProviderDef(id: "typesafe", label: "TypeSafe", dialect: .openAI,
                        baseURL: "https://api.typesafe.ai", defaultModel: "jev-latest",
                        envVar: "TYPESAFE_API_KEY", accentHex: "#DC2626",
                        keyless: false, unavailable: bespoke),
        ChatProviderDef(id: "bedrock-mantle", label: "Bedrock Mantle", dialect: .openAI,
                        baseURL: "", defaultModel: "", envVar: "AWS_BEARER_TOKEN_BEDROCK",
                        accentHex: "#FF9900", keyless: false,
                        unavailable: "The host is region-templated (bedrock-mantle.{region}.api.aws) and the request needs SigV4 — set the full URL as a custom gateway"),
        ChatProviderDef(id: "local", label: "Local inference", dialect: .openAI, baseURL: "",
                        defaultModel: "", envVar: nil, accentHex: "#71717A",
                        keyless: false,
                        unavailable: "omp reaches it over its own local:// scheme, in-process — there is no HTTP endpoint to point at"),
        ChatProviderDef(id: "web", label: "Web search", dialect: .openAI, baseURL: "",
                        defaultModel: "", envVar: nil, accentHex: "#71717A",
                        keyless: false,
                        unavailable: "omp's built-in search tool, served over its own web:// scheme — not a model provider"),
        ChatProviderDef(id: "amazon-bedrock", label: "Amazon Bedrock", dialect: .openAI,
                        baseURL: "", defaultModel: "", envVar: nil, accentHex: "#FF9900",
                        keyless: false,
                        unavailable: "Needs AWS SigV4 signing — set it as a custom gateway behind a signing proxy"),
        ChatProviderDef(id: "azure", label: "Azure OpenAI", dialect: .openAI, baseURL: "",
                        defaultModel: "", envVar: "AZURE_OPENAI_API_KEY", accentHex: "#0078D4",
                        keyless: false,
                        unavailable: "The endpoint is deployment-specific — set it as a custom gateway"),
        ChatProviderDef(id: "google-vertex", label: "Google Vertex AI", dialect: .openAI,
                        baseURL: "", defaultModel: "", envVar: "GOOGLE_CLOUD_API_KEY",
                        accentHex: "#4285F4", keyless: false,
                        unavailable: "Needs Application Default Credentials — set it as a custom gateway"),
        ChatProviderDef(id: "apple", label: "Apple Foundation Models", dialect: .openAI,
                        baseURL: "", defaultModel: "apple/on-device", envVar: nil,
                        accentHex: "#000000", keyless: false,
                        unavailable: "In-process bridge on Apple Silicon, not an HTTP endpoint"),
        // omp additionally needs CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_GATEWAY_ID to
        // build the routed URL, and that pair has no home in a single-key settings row.
        ChatProviderDef(id: "cloudflare-ai-gateway", label: "Cloudflare AI Gateway",
                        dialect: .openAI, baseURL: "https://gateway.ai.cloudflare.com/v1",
                        defaultModel: "openai/gpt-5.5", envVar: "CLOUDFLARE_AI_GATEWAY_API_KEY",
                        accentHex: "#F38020", keyless: false,
                        unavailable: "Needs an account id and a gateway id on top of the key — set it as a custom gateway"),
    ]
}
