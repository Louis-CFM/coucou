// Chat providers — the gateway list.
//
// Modelled on omp's provider catalog (`packages/catalog/src/compat/rules/providers/*.kdl`)
// but only as far as Coucou can actually drive it. Coucou speaks two wire shapes and
// has no OAuth, so the table is the honest subset of omp's 80 providers: everything
// answerable with a base URL plus a bearer/`x-api-key` header. The ones Coucou cannot
// reach are still listed, carrying the reason, so Settings can show them greyed out
// instead of pretending they do not exist.
//
// A provider is picked by id; the id is the keychain key (`provider-<id>`) and the
// settings key. Ids are contract values — renaming one orphans the stored key.


/// The per-provider chat model roster, generated from omp's bundled catalog
/// (`packages/catalog/src/models.json`) — id and display name only, chat models only,
/// ~5.400 rows. It is a JSON resource rather than a Rust table because a table would
/// be half a megabyte of source; the file's own `_comment` says it is generated.
const MODELS_JSON: &str = include_str!("../resources/chat_models.json");

/// `[id, display name]`, sorted case-insensitively by id.
pub type ModelDef = [String; 2];

/// Parsed once per process, then only read. `LazyLock` because the initializer is
/// known at declaration and never takes runtime input.
static CATALOG: std::sync::LazyLock<serde_json::Map<String, serde_json::Value>> =
    std::sync::LazyLock::new(|| {
        let parsed: serde_json::Value = serde_json::from_str(MODELS_JSON)
            .unwrap_or_else(|e| panic!("chat_models.json is corrupt: {e}"));
        // A panic here is deliberate and matches the precedent in claude.rs: this file
        // is compiled in, so it cannot be missing or stale at runtime, and a silent
        // empty catalog would leave the model picker blank with no explanation.
        parsed["providers"]
            .as_object()
            .expect("chat_models.json has no \"providers\" object")
            .clone()
    });

fn catalog() -> &'static serde_json::Map<String, serde_json::Value> {
    &CATALOG
}

/// The models a provider offers, for the picker in Settings.
///
/// Returns an empty list for a provider omp's catalog does not carry — `ollama`,
/// `lm-studio` and `llama-cpp` are the expected ones, since their models come from
/// whatever the user has pulled locally rather than from a hosted roster.
pub fn models(id: &str) -> Vec<ModelDef> {
    let Some(entry) = catalog().get(id) else { return Vec::new() };
    let Some(rows) = entry.as_array() else { return Vec::new() };
    rows.iter()
        .filter_map(|row| {
            let pair = row.as_array()?;
            let id = pair.first()?.as_str()?;
            let name = pair.get(1).and_then(|n| n.as_str()).unwrap_or(id);
            Some([id.to_string(), name.to_string()])
        })
        .collect()
}

/// A provider's roster, or its catalog default when the roster is empty — so the
/// picker always shows something for a local engine whose models are unknown.
pub fn models_or_default(id: &str) -> Vec<ModelDef> {
    let found = models(id);
    if !found.is_empty() {
        return found;
    }
    find(id)
        .filter(|p| !p.default_model.is_empty())
        .map(|p| vec![[p.default_model.to_string(), p.default_model.to_string()]])
        .unwrap_or_default()
}
use serde::{Deserialize, Serialize};

/// The two request shapes Coucou speaks. omp has sixteen `KnownApi` transports; these
/// are the two it implements natively (`ClaudeService.swift` already does both).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Dialect {
    /// `POST {base}/v1/messages`, `x-api-key` header — Anthropic Messages.
    Anthropic,
    /// `POST {base}/chat/completions`, `Authorization: Bearer` — OpenAI Chat Completions.
    #[default]
    OpenAI,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Provider {
    pub id: &'static str,
    pub label: &'static str,
    pub dialect: Dialect,
    /// Base URL without a trailing slash. `{base}/v1/messages` for Anthropic,
    /// `{base}/chat/completions` for OpenAI.
    pub base_url: &'static str,
    pub default_model: &'static str,
    /// omp's environment variable for this provider, shown in Settings as a hint so a
    /// key pasted here matches one pasted there. Coucou does not read the environment.
    pub env_var: Option<&'static str>,
    /// Pill/accent colour, matching how integrations are coloured elsewhere.
    pub accent: &'static str,
    /// Local engines answer without a key. Keyless is omp's own availability rule
    /// (`docs/providers.md:43`): a model is selectable when the provider is keyless
    /// OR has a credential — it is a config check, never a validation request.
    pub keyless: bool,
    /// `Some(reason)` when Coucou cannot drive this provider. Present so Settings can
    /// show it disabled with an explanation instead of hiding it.
    pub unavailable: Option<&'static str>,
}

/// The id a custom gateway gets. It is not in the table; its base URL, dialect and
/// model come from settings, and its key from the keyring under `provider-custom`.
pub const CUSTOM_ID: &str = "custom";

const OAUTH_ONLY: &str = "Reached through an omp /login flow; Coucou has no OAuth";
const BESPOKE: &str = "Non-standard wire protocol; omp ships a dedicated transport for it";

pub const PROVIDERS: &[Provider] = &[
    // ── First-party ─────────────────────────────────────────────────────────────
    Provider {
        id: "anthropic",
        label: "Anthropic",
        dialect: Dialect::Anthropic,
        base_url: "https://api.anthropic.com",
        default_model: "claude-opus-5",
        env_var: Some("ANTHROPIC_API_KEY"),
        accent: "#E07950",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "openai",
        label: "OpenAI",
        dialect: Dialect::OpenAI,
        base_url: "https://api.openai.com/v1",
        default_model: "gpt-4o",
        env_var: Some("OPENAI_API_KEY"),
        accent: "#10A37F",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "google",
        label: "Google AI",
        dialect: Dialect::OpenAI,
        base_url: "https://generativelanguage.googleapis.com/v1beta/openai",
        default_model: "gemini-2.0-flash",
        env_var: Some("GEMINI_API_KEY"),
        accent: "#4285F4",
        keyless: false,
        unavailable: None,
    },
    // ── Gateways — one key, many vendors behind it ──────────────────────────────
    Provider {
        id: "openrouter",
        label: "OpenRouter",
        dialect: Dialect::OpenAI,
        base_url: "https://openrouter.ai/api/v1",
        default_model: "openai/gpt-5.5",
        env_var: Some("OPENROUTER_API_KEY"),
        accent: "#6467F2",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "vercel-ai-gateway",
        label: "Vercel AI Gateway",
        dialect: Dialect::OpenAI,
        base_url: "https://ai-gateway.vercel.sh/v1",
        default_model: "openai/gpt-5.5",
        env_var: Some("AI_GATEWAY_API_KEY"),
        accent: "#7C5CFF",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "cloudflare-ai-gateway",
        label: "Cloudflare AI Gateway",
        dialect: Dialect::OpenAI,
        base_url: "https://gateway.ai.cloudflare.com/v1",
        default_model: "openai/gpt-5.5",
        env_var: Some("CLOUDFLARE_AI_GATEWAY_API_KEY"),
        accent: "#F38020",
        keyless: false,
        // omp additionally needs CLOUDFLARE_ACCOUNT_ID and CLOUDFLARE_GATEWAY_ID to
        // build the routed URL (`docs/providers.md:198`). The account/gateway pair has
        // no home in a single-key settings row; use the custom gateway instead.
        unavailable: Some("Needs an account id and a gateway id on top of the key — set it as a custom gateway"),
    },
    Provider {
        id: "singularityapi-dev",
        label: "SingularityAPI",
        dialect: Dialect::OpenAI,
        base_url: "https://api.singularityapi.dev/v1",
        default_model: "deepseek/deepseek-v4-pro",
        env_var: Some("SINGULARITYAPI_DEV_API_KEY"),
        accent: "#8B5CF6",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "aimlapi",
        label: "AIMLAPI",
        dialect: Dialect::OpenAI,
        base_url: "https://api.aimlapi.com/v1",
        default_model: "gpt-5.5",
        env_var: Some("AIMLAPI_API_KEY"),
        accent: "#22D3EE",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "commandcode",
        label: "Command Code",
        dialect: Dialect::OpenAI,
        base_url: "https://api.commandcode.ai/provider",
        default_model: "claude-sonnet-5.5",
        env_var: Some("COMMAND_CODE_API_KEY"),
        accent: "#0EA5E9",
        keyless: false,
        unavailable: None,
    },
    // ── Hosted inference ────────────────────────────────────────────────────────
    Provider {
        id: "groq",
        label: "Groq",
        dialect: Dialect::OpenAI,
        base_url: "https://api.groq.com/openai/v1",
        default_model: "llama-3.3-70b-versatile",
        env_var: Some("GROQ_API_KEY"),
        accent: "#F55036",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "mistral",
        label: "Mistral",
        dialect: Dialect::OpenAI,
        base_url: "https://api.mistral.ai/v1",
        default_model: "mistral-large-latest",
        env_var: Some("MISTRAL_API_KEY"),
        accent: "#FA520F",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "xai",
        label: "xAI",
        dialect: Dialect::OpenAI,
        base_url: "https://api.x.ai/v1",
        default_model: "grok-4.6",
        env_var: Some("XAI_API_KEY"),
        accent: "#000000",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "deepseek",
        label: "DeepSeek",
        dialect: Dialect::OpenAI,
        base_url: "https://api.deepseek.com",
        default_model: "deepseek-chat",
        env_var: Some("DEEPSEEK_API_KEY"),
        accent: "#4D6BFE",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "cerebras",
        label: "Cerebras",
        dialect: Dialect::OpenAI,
        base_url: "https://api.cerebras.ai/v1",
        default_model: "llama-3.3-70b",
        env_var: Some("CEREBRAS_API_KEY"),
        accent: "#F26722",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "together",
        label: "Together AI",
        dialect: Dialect::OpenAI,
        base_url: "https://api.together.xyz/v1",
        default_model: "meta-llama/Llama-3.3-70B-Instruct-Turbo",
        env_var: Some("TOGETHER_API_KEY"),
        accent: "#0F6FFF",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "fireworks",
        label: "Fireworks AI",
        dialect: Dialect::OpenAI,
        base_url: "https://api.fireworks.ai/inference/v1",
        default_model: "accounts/fireworks/models/kimi-k2-instruct",
        env_var: Some("FIREWORKS_API_KEY"),
        accent: "#5019C5",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "deepinfra",
        label: "DeepInfra",
        dialect: Dialect::OpenAI,
        base_url: "https://api.deepinfra.com/v1/openai",
        default_model: "meta-llama/Llama-3.3-70B-Instruct",
        env_var: Some("DEEPINFRA_API_KEY"),
        accent: "#5B6CFF",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "huggingface",
        label: "Hugging Face",
        dialect: Dialect::OpenAI,
        base_url: "https://router.huggingface.co/v1",
        default_model: "meta-llama/Llama-3.3-70B-Instruct",
        env_var: Some("HUGGINGFACE_HUB_TOKEN"),
        accent: "#FFD21E",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "nvidia",
        label: "NVIDIA",
        dialect: Dialect::OpenAI,
        base_url: "https://integrate.api.nvidia.com/v1",
        default_model: "meta/llama-3.3-70b-instruct",
        env_var: Some("NVIDIA_API_KEY"),
        accent: "#76B900",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "novita",
        label: "Novita AI",
        dialect: Dialect::OpenAI,
        base_url: "https://api.novita.ai/openai/v1",
        default_model: "deepseek/deepseek-v3.1",
        env_var: Some("NOVITA_API_KEY"),
        accent: "#16A34A",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "venice",
        label: "Venice AI",
        dialect: Dialect::OpenAI,
        base_url: "https://api.venice.ai/api/v1",
        default_model: "venice-3",
        env_var: Some("VENICE_API_KEY"),
        accent: "#FF4D6D",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "stepfun",
        label: "StepFun",
        dialect: Dialect::OpenAI,
        base_url: "https://api.stepfun.ai/v1",
        default_model: "step-3.5-flash",
        env_var: Some("STEPFUN_API_KEY"),
        accent: "#6D28D9",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "baseten",
        label: "Baseten",
        dialect: Dialect::OpenAI,
        base_url: "https://inference.baseten.co/v1",
        default_model: "deepseek-ai/DeepSeek-V3",
        env_var: Some("BASETEN_API_KEY"),
        accent: "#111827",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "coreweave",
        label: "CoreWeave",
        dialect: Dialect::OpenAI,
        base_url: "https://api.inference.wandb.ai/v1",
        default_model: "meta-llama/llama-3.3-70b-instruct",
        env_var: Some("COREWEAVE_API_KEY"),
        accent: "#7F56D9",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "helmcode",
        label: "HelmCode",
        dialect: Dialect::OpenAI,
        base_url: "https://api.helmcode.com/v1",
        default_model: "kimi-k2.6",
        env_var: Some("HELMCODE_API_KEY"),
        accent: "#D0BCFF",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "aiand",
        label: "AI&",
        dialect: Dialect::OpenAI,
        base_url: "https://api.aiand.com/v1",
        default_model: "gpt-5.5",
        env_var: Some("AIAND_API_KEY"),
        accent: "#12B76A",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "gmi-cloud",
        label: "GMI Cloud",
        dialect: Dialect::OpenAI,
        base_url: "https://api.gmi-serving.com/v1",
        default_model: "deepseek-v4-pro",
        env_var: Some("GMI_API_KEY"),
        accent: "#2563EB",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "meta",
        label: "Meta AI",
        dialect: Dialect::OpenAI,
        base_url: "https://api.meta.ai/v1",
        default_model: "gpt-5.5",
        env_var: Some("MODEL_API_KEY"),
        accent: "#0081FB",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "sakana",
        label: "Sakana AI",
        dialect: Dialect::OpenAI,
        base_url: "https://api.sakana.ai/v1",
        default_model: "sakana-ai-scientist",
        env_var: Some("SAKANA_API_KEY"),
        accent: "#7E22CE",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "abliteration",
        label: "Abliteration",
        dialect: Dialect::OpenAI,
        base_url: "https://api.abliteration.ai/v1",
        default_model: "gpt-5.5",
        env_var: Some("ABLITERATION_API_KEY"),
        accent: "#EF4444",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "alibaba-coding-plan",
        label: "Alibaba Coding Plan",
        dialect: Dialect::OpenAI,
        base_url: "https://coding-intl.dashscope.aliyuncs.com/v1",
        default_model: "qwen3-coder-plus",
        env_var: Some("ALIBABA_CODING_PLAN_API_KEY"),
        accent: "#FF6A00",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "alibaba-token-plan",
        label: "Alibaba Token Plan",
        dialect: Dialect::OpenAI,
        base_url: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1",
        default_model: "qwen3-coder-plus",
        env_var: Some("ALIBABA_TOKEN_PLAN_API_KEY"),
        accent: "#F97316",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "charm-hyper",
        label: "Charm Hyper",
        dialect: Dialect::OpenAI,
        base_url: "https://hyper.charm.land/v1",
        default_model: "glm-5.1",
        env_var: Some("CHARM_HYPER_API_KEY"),
        accent: "#A3E635",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "yolo-auto",
        label: "Yolo Auto",
        dialect: Dialect::OpenAI,
        base_url: "https://yolo-auto.com/v1",
        default_model: "claude-opus-5",
        env_var: Some("YOLO_AUTO_API_KEY"),
        accent: "#FACC15",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "xiaomi-token-plan-cn",
        label: "Xiaomi Token Plan",
        dialect: Dialect::OpenAI,
        base_url: "https://token-plan-cn.xiaomimimo.com/v1",
        default_model: "mimo-v2-pro",
        env_var: Some("XIAOMI_TOKEN_PLAN_CN_API_KEY"),
        accent: "#FF6900",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "qianfan",
        label: "Baidu Qianfan",
        dialect: Dialect::OpenAI,
        base_url: "https://qianfan.baidubce.com/v2",
        default_model: "ernie-4.5-turbo-128k",
        env_var: Some("QIANFAN_API_KEY"),
        accent: "#2932E1",
        keyless: false,
        unavailable: None,
    },
    Provider {
        id: "zai",
        label: "Z.ai",
        dialect: Dialect::Anthropic,
        base_url: "https://api.z.ai/api/anthropic",
        default_model: "glm-4.7",
        env_var: Some("ZAI_API_KEY"),
        accent: "#2C6FF3",
        keyless: false,
        unavailable: None,
    },
    // ── Local engines — keyless by default (omp's own rule, providers.md:238) ───
    Provider {
        id: "ollama",
        label: "Ollama",
        dialect: Dialect::OpenAI,
        base_url: "http://127.0.0.1:11434/v1",
        default_model: "llama3.2",
        env_var: Some("OLLAMA_API_KEY"),
        accent: "#111111",
        keyless: true,
        unavailable: None,
    },
    Provider {
        id: "lm-studio",
        label: "LM Studio",
        dialect: Dialect::OpenAI,
        base_url: "http://127.0.0.1:1234/v1",
        default_model: "local-model",
        env_var: Some("LM_STUDIO_API_KEY"),
        accent: "#8B5CF6",
        keyless: true,
        unavailable: None,
    },
    Provider {
        // omp calls this `llama.cpp`; the id is kebab-case here because it becomes a
        // keyring suffix (`provider-llama-cpp`) and every other id obeys that shape.
        // The label keeps the product's real spelling.
        id: "llama-cpp",
        label: "llama.cpp",
        dialect: Dialect::OpenAI,
        base_url: "http://127.0.0.1:8080/v1",
        default_model: "local-model",
        env_var: Some("LLAMA_CPP_API_KEY"),
        accent: "#374151",
        keyless: true,
        unavailable: None,
    },

    // ── Second wave: the rest of omp's routable catalog ─────────────────────────
    // Added after auditing this table against every `provider "…"` block in omp's
    // `rules/providers/*.kdl` — the first pass silently dropped 24 of them. Base URLs
    // come from omp's `openAiCompletionsDescriptor` / `anthropicMessagesDescriptor`
    // calls and its discovery helpers; none of these were written from memory.
    Provider { id: "opencode-zen", label: "OpenCode Zen", dialect: Dialect::OpenAI, base_url: "https://opencode.ai/zen/v1", default_model: "claude-opus-5", env_var: Some("OPENCODE_API_KEY"), accent: "#E5E5E5", keyless: false, unavailable: None },
    Provider { id: "opencode-go", label: "OpenCode Go", dialect: Dialect::OpenAI, base_url: "https://opencode.ai/zen/go/v1", default_model: "kimi-k2.7-code", env_var: Some("OPENCODE_API_KEY"), accent: "#10B981", keyless: false, unavailable: None },
    Provider { id: "moonshot", label: "Moonshot", dialect: Dialect::OpenAI, base_url: "https://api.moonshot.ai/v1", default_model: "kimi-k2.7-code", env_var: Some("MOONSHOT_API_KEY"), accent: "#6D28D9", keyless: false, unavailable: None },
    // omp points this at the Kimi China platform when MOONSHOT_BASE_URL says so;
    // Coucou does not read the environment, so use the custom gateway for that.
    Provider { id: "siliconflow", label: "SiliconFlow", dialect: Dialect::OpenAI, base_url: "https://api.siliconflow.com/v1", default_model: "zai-org/GLM-5.1", env_var: Some("SILICONFLOW_API_KEY"), accent: "#7C3AED", keyless: false, unavailable: None },
    Provider { id: "siliconflow-cn", label: "SiliconFlow CN", dialect: Dialect::OpenAI, base_url: "https://api.siliconflow.cn/v1", default_model: "deepseek-ai/DeepSeek-V4-Pro", env_var: Some("SILICONFLOW_CN_API_KEY"), accent: "#A855F7", keyless: false, unavailable: None },
    // omp serves plain MiniMax over Anthropic Messages.
    Provider { id: "minimax", label: "MiniMax", dialect: Dialect::Anthropic, base_url: "https://api.minimax.io/anthropic", default_model: "MiniMax-M3", env_var: Some("MINIMAX_API_KEY"), accent: "#FF4D4D", keyless: false, unavailable: None },
    Provider { id: "minimax-code", label: "MiniMax Coding Plan", dialect: Dialect::OpenAI, base_url: "https://api.minimax.io/v1", default_model: "MiniMax-M3", env_var: Some("MINIMAX_CODE_API_KEY"), accent: "#F97316", keyless: false, unavailable: None },
    Provider { id: "minimax-code-cn", label: "MiniMax Coding Plan CN", dialect: Dialect::OpenAI, base_url: "https://api.minimaxi.com/v1", default_model: "MiniMax-M3", env_var: Some("MINIMAX_CODE_CN_API_KEY"), accent: "#FB923C", keyless: false, unavailable: None },
    Provider { id: "kilo", label: "Kilo Gateway", dialect: Dialect::OpenAI, base_url: "https://api.kilo.ai/api/gateway", default_model: "anthropic/claude-opus-5", env_var: Some("KILO_API_KEY"), accent: "#22D3EE", keyless: false, unavailable: None },
    Provider { id: "zenmux", label: "ZenMux", dialect: Dialect::OpenAI, base_url: "https://zenmux.ai/api/v1", default_model: "anthropic/claude-opus-5", env_var: Some("ZENMUX_API_KEY"), accent: "#8B5CF6", keyless: false, unavailable: None },
    Provider { id: "umans", label: "Umans", dialect: Dialect::OpenAI, base_url: "https://api.code.umans.ai", default_model: "umans-coder", env_var: Some("UMANS_AI_CODING_PLAN_API_KEY"), accent: "#0EA5E9", keyless: false, unavailable: None },
    Provider { id: "synthetic", label: "Synthetic", dialect: Dialect::OpenAI, base_url: "https://api.synthetic.new/openai/v1", default_model: "hf:zai-org/GLM-5.3-Flash", env_var: Some("SYNTHETIC_API_KEY"), accent: "#3B82F6", keyless: false, unavailable: None },
    Provider { id: "nanogpt", label: "NanoGPT", dialect: Dialect::OpenAI, base_url: "https://nano-gpt.com/api/v1", default_model: "openai/gpt-5.5", env_var: Some("NANO_GPT_API_KEY"), accent: "#14B8A6", keyless: false, unavailable: None },
    Provider { id: "xiaomi", label: "Xiaomi MiMo", dialect: Dialect::OpenAI, base_url: "https://api.xiaomimimo.com/v1", default_model: "mimo-v2.5", env_var: Some("XIAOMI_API_KEY"), accent: "#FF6900", keyless: false, unavailable: None },
    Provider { id: "xiaomi-token-plan-ams", label: "Xiaomi Token Plan (AMS)", dialect: Dialect::OpenAI, base_url: "https://token-plan-ams.xiaomimimo.com/v1", default_model: "mimo-v2.5", env_var: Some("XIAOMI_TOKEN_PLAN_AMS_API_KEY"), accent: "#F97316", keyless: false, unavailable: None },
    Provider { id: "xiaomi-token-plan-sgp", label: "Xiaomi Token Plan (SGP)", dialect: Dialect::OpenAI, base_url: "https://token-plan-sgp.xiaomimimo.com/v1", default_model: "mimo-v2.5", env_var: Some("XIAOMI_TOKEN_PLAN_SGP_API_KEY"), accent: "#FB923C", keyless: false, unavailable: None },
    Provider { id: "zhipu-coding-plan", label: "Zhipu Coding Plan", dialect: Dialect::OpenAI, base_url: "https://open.bigmodel.cn/api/coding/paas/v4", default_model: "glm-5.1", env_var: Some("ZHIPU_API_KEY"), accent: "#2C6FF3", keyless: false, unavailable: None },
    Provider { id: "cline-pass", label: "ClinePass", dialect: Dialect::OpenAI, base_url: "https://api.cline.bot/api/v1", default_model: "kimi-k3", env_var: Some("CLINE_API_KEY"), accent: "#D946EF", keyless: false, unavailable: None },
    Provider { id: "firepass", label: "FirePass", dialect: Dialect::OpenAI, base_url: "https://api.fireworks.ai/inference/v1", default_model: "glm-5.2-fast", env_var: Some("FIREPASS_API_KEY"), accent: "#7C3AED", keyless: false, unavailable: None },
    // omp sells this as a booked reservation slot, not prepaid credit; the roster is
    // discovered from its /v1/models.
    Provider { id: "singularityapi-tech", label: "SingularityAPI Tech", dialect: Dialect::OpenAI, base_url: "https://api.singularityapi.tech/v1", default_model: "deepseek-ai/DeepSeek-V4.1-Flash", env_var: Some("SINGULARITYAPI_TECH_API_KEY"), accent: "#6366F1", keyless: false, unavailable: None },
    // omp publishes these two localhost defaults in getDefaultModelDiscoveryBaseUrl.
    Provider { id: "litellm", label: "LiteLLM", dialect: Dialect::OpenAI, base_url: "http://localhost:4000/v1", default_model: "claude-opus-5-5", env_var: Some("LITELLM_API_KEY"), accent: "#22C55E", keyless: true, unavailable: None },
    Provider { id: "vllm", label: "vLLM", dialect: Dialect::OpenAI, base_url: "http://127.0.0.1:8000/v1", default_model: "gpt-oss-20b", env_var: Some("VLLM_API_KEY"), accent: "#646CFF", keyless: true, unavailable: None },
    Provider { id: "bedrock-mantle", label: "Bedrock Mantle", dialect: Dialect::OpenAI, base_url: "", default_model: "", env_var: Some("AWS_BEARER_TOKEN_BEDROCK"), accent: "#FF9900", keyless: false, unavailable: Some("The host is region-templated (bedrock-mantle.{region}.api.aws) and the request needs SigV4 — set the full URL as a custom gateway") },
    Provider { id: "local", label: "Local inference", dialect: Dialect::OpenAI, base_url: "", default_model: "", env_var: None, accent: "#71717A", keyless: false, unavailable: Some("omp reaches it over its own local:// scheme, in-process — there is no HTTP endpoint to point at") },
    Provider { id: "web", label: "Web search", dialect: Dialect::OpenAI, base_url: "", default_model: "", env_var: None, accent: "#71717A", keyless: false, unavailable: Some("omp's built-in search tool, served over its own web:// scheme — not a model provider") },
    // ── In omp's catalog, unreachable from Coucou — listed so Settings can say why ─
    Provider { id: "cursor", label: "Cursor", dialect: Dialect::OpenAI, base_url: "", default_model: "", env_var: Some("CURSOR_ACCESS_TOKEN"), accent: "#000000", keyless: false, unavailable: Some(BESPOKE) },
    Provider { id: "openai-codex", label: "OpenAI Codex", dialect: Dialect::OpenAI, base_url: "https://chatgpt.com/backend-api", default_model: "gpt-5.5", env_var: Some("OPENAI_CODEX_OAUTH_TOKEN"), accent: "#10A37F", keyless: false, unavailable: Some(OAUTH_ONLY) },
    Provider { id: "github-copilot", label: "GitHub Copilot", dialect: Dialect::OpenAI, base_url: "", default_model: "gpt-5.5", env_var: Some("COPILOT_GITHUB_TOKEN"), accent: "#6E40C9", keyless: false, unavailable: Some(OAUTH_ONLY) },
    Provider { id: "devin", label: "Devin", dialect: Dialect::OpenAI, base_url: "https://server.codeium.com", default_model: "swe-1-6", env_var: Some("DEVIN_API_KEY"), accent: "#4A4A4A", keyless: false, unavailable: Some(BESPOKE) },
    Provider { id: "factory-droid", label: "Factory Droid", dialect: Dialect::OpenAI, base_url: "https://api.factory.ai", default_model: "kimi-k3", env_var: None, accent: "#111111", keyless: false, unavailable: Some(BESPOKE) },
    Provider { id: "gitlab-duo", label: "GitLab Duo", dialect: Dialect::OpenAI, base_url: "https://gitlab.com", default_model: "duo-chat-opus-4-6", env_var: Some("GITLAB_TOKEN"), accent: "#FC6D26", keyless: false, unavailable: Some(BESPOKE) },
    Provider { id: "gitlab-duo-agent", label: "GitLab Duo Agent", dialect: Dialect::OpenAI, base_url: "https://gitlab.com", default_model: "claude_sonnet_4_6_vertex", env_var: Some("GITLAB_TOKEN"), accent: "#FC6D26", keyless: false, unavailable: Some(BESPOKE) },
    Provider { id: "google-gemini-cli", label: "Gemini CLI", dialect: Dialect::OpenAI, base_url: "", default_model: "gemini-3.1-pro-preview", env_var: None, accent: "#4285F4", keyless: false, unavailable: Some(OAUTH_ONLY) },
    Provider { id: "google-antigravity", label: "Google Antigravity", dialect: Dialect::OpenAI, base_url: "https://daily-cloudcode-pa.googleapis.com", default_model: "gemini-3.1-pro", env_var: None, accent: "#EA4335", keyless: false, unavailable: Some(OAUTH_ONLY) },
    Provider { id: "muse-code", label: "Muse Code", dialect: Dialect::OpenAI, base_url: "https://api.meta.ai/v1", default_model: "muse-spark-1.3", env_var: None, accent: "#0081FB", keyless: false, unavailable: Some(OAUTH_ONLY) },
    Provider { id: "xai-oauth", label: "xAI (SuperGrok)", dialect: Dialect::OpenAI, base_url: "https://api.x.ai/v1", default_model: "grok-4.6", env_var: Some("XAI_OAUTH_TOKEN"), accent: "#000000", keyless: false, unavailable: Some(OAUTH_ONLY) },
    Provider { id: "kimi-code", label: "Kimi Code", dialect: Dialect::OpenAI, base_url: "", default_model: "kimi-for-coding", env_var: None, accent: "#1F1F1F", keyless: false, unavailable: Some(OAUTH_ONLY) },
    Provider { id: "qwen-portal", label: "Qwen Portal", dialect: Dialect::OpenAI, base_url: "https://portal.qwen.ai/v1", default_model: "coder-model", env_var: Some("QWEN_OAUTH_TOKEN"), accent: "#615CED", keyless: false, unavailable: Some(OAUTH_ONLY) },
    Provider { id: "ollama-cloud", label: "Ollama Cloud", dialect: Dialect::OpenAI, base_url: "", default_model: "gpt-oss:120b", env_var: None, accent: "#111111", keyless: false, unavailable: Some(OAUTH_ONLY) },
    Provider { id: "wafer-serverless", label: "Wafer", dialect: Dialect::OpenAI, base_url: "", default_model: "GLM-5.1", env_var: Some("WAFER_SERVERLESS_API_KEY"), accent: "#0F766E", keyless: false, unavailable: Some(OAUTH_ONLY) },
    Provider { id: "typesafe", label: "TypeSafe", dialect: Dialect::OpenAI, base_url: "https://api.typesafe.ai", default_model: "jev-latest", env_var: Some("TYPESAFE_API_KEY"), accent: "#DC2626", keyless: false, unavailable: Some(BESPOKE) },
    Provider { id: "amazon-bedrock", label: "Amazon Bedrock", dialect: Dialect::OpenAI, base_url: "", default_model: "", env_var: None, accent: "#FF9900", keyless: false, unavailable: Some("Needs AWS SigV4 signing — set it as a custom gateway behind a signing proxy") },
    Provider { id: "azure", label: "Azure OpenAI", dialect: Dialect::OpenAI, base_url: "", default_model: "", env_var: Some("AZURE_OPENAI_API_KEY"), accent: "#0078D4", keyless: false, unavailable: Some("The endpoint is deployment-specific — set it as a custom gateway") },
    Provider { id: "google-vertex", label: "Google Vertex AI", dialect: Dialect::OpenAI, base_url: "", default_model: "", env_var: Some("GOOGLE_CLOUD_API_KEY"), accent: "#4285F4", keyless: false, unavailable: Some("Needs Application Default Credentials — set it as a custom gateway") },
    Provider { id: "apple", label: "Apple Foundation Models", dialect: Dialect::OpenAI, base_url: "", default_model: "apple/on-device", env_var: None, accent: "#000000", keyless: false, unavailable: Some("In-process bridge on Apple Silicon, not an HTTP endpoint") },
];

pub fn find(id: &str) -> Option<&'static Provider> {
    PROVIDERS.iter().find(|p| p.id == id)
}

/// True when the id names a provider Coucou can actually call — table entry that is
/// not marked unavailable, or the custom gateway.
pub fn is_routable(id: &str) -> bool {
    id == CUSTOM_ID || find(id).is_some_and(|p| p.unavailable.is_none())
}

/// Keyring key for a provider's credential. Provider ids and the custom id are the
/// only accepted prefix, so the settings UI still cannot write an arbitrary key.
pub fn key_for(id: &str) -> String {
    format!("provider-{id}")
}

/// Resolves everything needed to build a request for `id`, falling back to the
/// custom gateway's settings when the id is `custom` or unknown.
pub struct Route {
    pub label: String,
    pub dialect: Dialect,
    pub base_url: String,
    pub key_name: String,
    pub model: String,
}

/// Anthropic's model override, honouring the legacy `model` field so a settings.json
/// written before providers existed keeps the model the user had already picked.
fn anthropic_model(settings: &crate::settings::Settings) -> String {
    if let Some(m) = settings.provider_models.get("anthropic") {
        if !m.is_empty() {
            return m.clone();
        }
    }
    let legacy = &settings.model;
    if !legacy.is_empty() && legacy != crate::claude::DEFAULT_MODEL {
        return legacy.clone();
    }
    crate::claude::DEFAULT_MODEL.to_string()
}

pub fn route(id: &str, settings: &crate::settings::Settings) -> Result<Route, String> {
    if id == CUSTOM_ID {
        let base = settings.custom_base_url.trim();
        if base.is_empty() {
            return Err("Set a base URL for the custom gateway in Settings.".into());
        }
        // Same rule as open_url: only http/https ever reach the network layer, so a
        // pasted `file://` or a custom scheme cannot be dialled.
        if !(base.starts_with("https://") || base.starts_with("http://")) {
            return Err("The custom gateway URL must start with http:// or https://.".into());
        }
        let model = settings.custom_model.trim();
        if model.is_empty() {
            return Err("Set a model for the custom gateway in Settings.".into());
        }
        return Ok(Route {
            label: "Custom gateway".to_string(),
            dialect: settings.custom_dialect,
            base_url: base.to_string(),
            key_name: key_for(CUSTOM_ID),
            model: model.to_string(),
        });
    }
    let Some(p) = find(id) else {
        return Err(format!("Unknown provider '{id}'."));
    };
    if let Some(why) = p.unavailable {
        return Err(format!("{}: {why}.", p.label));
    }
    let model = if p.id == "anthropic" {
        anthropic_model(settings)
    } else {
        settings
            .provider_models
            .get(p.id)
            .filter(|m| !m.is_empty())
            .cloned()
            .unwrap_or_else(|| p.default_model.to_string())
    };
    Ok(Route {
        label: p.label.to_string(),
        dialect: p.dialect,
        base_url: p.base_url.to_string(),
        key_name: key_for(p.id),
        model,
    })
}

/// URL for a route. Anthropic appends `/v1/messages`; OpenAI appends
/// `/chat/completions` to a base that already ends in the version.
pub fn endpoint(dialect: Dialect, base_url: &str) -> String {
    let base = base_url.trim_end_matches('/');
    match dialect {
        Dialect::Anthropic => format!("{base}/v1/messages"),
        Dialect::OpenAI => format!("{base}/chat/completions"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_id_is_unique_and_kebab_or_custom() {
        let mut seen: Vec<&str> = Vec::new();
        for p in PROVIDERS {
            assert!(!seen.contains(&p.id), "duplicate provider id {}", p.id);
            seen.push(p.id);
            assert!(
                p.id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-'),
                "provider id must stay a safe keyring suffix: {}",
                p.id
            );
        }
    }

    #[test]
    fn a_routable_provider_always_has_an_endpoint_and_a_model() {
        for p in PROVIDERS.iter().filter(|p| p.unavailable.is_none()) {
            assert!(!p.base_url.is_empty(), "{} has no base url", p.id);
            assert!(!p.default_model.is_empty(), "{} has no default model", p.id);
            assert!(
                p.base_url.starts_with("https://") || p.base_url.starts_with("http://"),
                "{} base url must be absolute",
                p.id
            );
        }
    }

    #[test]
    fn an_unavailable_provider_never_claims_to_be_routable() {
        for p in PROVIDERS.iter().filter(|p| p.unavailable.is_some()) {
            assert!(!is_routable(p.id), "{} is marked unavailable", p.id);
        }
    }

    #[test]
    fn the_anthropic_dialect_appends_messages_and_openai_appends_chat_completions() {
        assert_eq!(
            endpoint(Dialect::Anthropic, "https://api.anthropic.com/"),
            "https://api.anthropic.com/v1/messages"
        );
        assert_eq!(
            endpoint(Dialect::OpenAI, "https://api.openai.com/v1"),
            "https://api.openai.com/v1/chat/completions"
        );
    }

    #[test]
    fn the_custom_gateway_is_routable_without_being_in_the_table() {
        assert!(!PROVIDERS.iter().any(|p| p.id == CUSTOM_ID));
        assert!(is_routable(CUSTOM_ID));
        assert_eq!(key_for(CUSTOM_ID), "provider-custom");
    }

    /// The field names below are the wire contract with `ChatProvider` in
    /// `windows/src/core/bridge.ts`. Renaming a field here would leave the settings
    /// list silently blank rather than failing to compile, so the names are pinned.
    #[test]
    fn a_provider_serialises_with_the_field_names_the_front_end_reads() {
        let json = serde_json::to_value(find("openrouter").unwrap()).unwrap();
        for key in [
            "id", "label", "dialect", "baseUrl", "defaultModel",
            "envVar", "accent", "keyless", "unavailable",
        ] {
            assert!(json.get(key).is_some(), "missing '{key}' in {json}");
        }
        assert!(json.get("default_model").is_none(), "snake_case leaked to the UI");
        assert_eq!(json["dialect"], "openAI");
        assert_eq!(
            serde_json::to_value(Dialect::Anthropic).unwrap(),
            "anthropic"
        );
    }

    /// Every provider omp's catalog declares, so a new entry upstream shows up as a
    /// failing test rather than a silently missing row in Settings.
    ///
    /// The earlier version of this test asserted `PROVIDERS.len() == 62` — the number
    /// that happened to be in the table — so it passed while 24 providers were missing.
    /// A count that pins nothing is worse than no test. This pins the membership.
    const OMP_CATALOG: &[&str] = &[
        "abliteration", "aiand", "aimlapi", "alibaba-coding-plan", "alibaba-token-plan",
        "amazon-bedrock", "anthropic", "apple", "azure", "baseten", "bedrock-mantle",
        "cerebras", "charm-hyper", "cline-pass", "cloudflare-ai-gateway", "commandcode",
        "coreweave", "cursor", "deepinfra", "deepseek", "devin", "factory-droid",
        "firepass", "fireworks", "github-copilot", "gitlab-duo", "gitlab-duo-agent",
        "gmi-cloud", "google", "google-antigravity", "google-gemini-cli", "google-vertex",
        "groq", "helmcode", "huggingface", "kilo", "kimi-code", "litellm", "llama-cpp",
        "lm-studio", "local", "minimax", "minimax-code", "minimax-code-cn", "mistral",
        "moonshot", "meta", "muse-code", "nanogpt", "nvidia", "novita", "ollama-cloud",
        "ollama", "openai-codex", "openai", "opencode-go", "opencode-zen", "openrouter",
        "qianfan", "qwen-portal", "sakana", "siliconflow", "siliconflow-cn",
        "singularityapi-dev", "singularityapi-tech", "stepfun", "synthetic", "together",
        "typesafe", "umans", "venice", "vercel-ai-gateway", "vllm", "wafer-serverless",
        "web", "xai-oauth", "xai", "xiaomi-token-plan-ams", "xiaomi-token-plan-cn",
        "xiaomi-token-plan-sgp", "xiaomi", "yolo-auto", "zai", "zenmux",
        "zhipu-coding-plan",
    ];

    #[test]
    fn every_provider_in_omp_catalog_is_listed_here() {
        // `llama-cpp` is the one deliberate rename: omp's id has a dot, and an id
        // becomes a keyring suffix.
        assert_eq!(OMP_CATALOG.len(), PROVIDERS.len(), "table drifted from omp's catalog");
        for id in OMP_CATALOG {
            assert!(find(id).is_some(), "omp lists {id} and Coucou does not");
        }
        for p in PROVIDERS {
            assert!(OMP_CATALOG.contains(&p.id), "{} is in Coucou but not in omp", p.id);
        }
    }

    #[test]
    fn a_provider_with_a_key_env_var_names_that_var() {
        // omp documents the variable per provider; showing a wrong one sends the user
        // to copy a key that will not work.
        assert_eq!(find("openrouter").unwrap().env_var, Some("OPENROUTER_API_KEY"));
        assert_eq!(find("groq").unwrap().env_var, Some("GROQ_API_KEY"));
        assert_eq!(find("llama-cpp").unwrap().env_var, Some("LLAMA_CPP_API_KEY"));
    }
}
