#!/usr/bin/env python3
"""Rebuild NotchBuddy/Resources/providers.json from the models.dev catalog (MIT).

Run by a maintainer when the list should be refreshed; the app never downloads it:
    python3 scripts/update-providers.py
Keeps providers that speak the OpenAI chat API and have a fixed https (or local http) URL, and skips the
providers Coucou already ships (Anthropic, Google, OpenAI, Ollama, LM Studio).
"""
import json
import sys
import urllib.request
from pathlib import Path

OUT = Path(__file__).resolve().parent.parent / "NotchBuddy/Resources/providers.json"
SOURCE = "https://models.dev/api.json"

# Providers models.dev lists without an `api` URL, and where they answer.
KNOWN_URLS = {
    "groq": "https://api.groq.com/openai/v1",
    "deepinfra": "https://api.deepinfra.com/v1/openai",
    "cerebras": "https://api.cerebras.ai/v1",
    "openrouter": "https://openrouter.ai/api/v1",
    "mistral": "https://api.mistral.ai/v1",
    "xai": "https://api.x.ai/v1",
    "deepseek": "https://api.deepseek.com/v1",
    "togetherai": "https://api.together.xyz/v1",
    "perplexity": "https://api.perplexity.ai",
    "fireworks-ai": "https://api.fireworks.ai/inference/v1",
}
# https, or plain http on this Mac only: the app never sends a key over http to anywhere else.
SAFE_SCHEMES = ("https://", "http://127.0.0.1", "http://localhost")
POPULAR = ["openrouter", "groq", "mistral", "xai", "deepseek", "togetherai", "fireworks-ai", "perplexity", "cerebras", "deepinfra"]
BUILT_IN = {"anthropic", "google", "openai", "ollama", "lmstudio", "google-vertex", "azure", "amazon-bedrock", "github-copilot", "gitlab"}
OPENAI_STYLE = {
    "@ai-sdk/openai-compatible", "@ai-sdk/openai", "@openrouter/ai-sdk-provider", "@ai-sdk/groq",
    "@ai-sdk/cerebras", "@ai-sdk/deepinfra", "@ai-sdk/perplexity", "@ai-sdk/xai", "@ai-sdk/mistral",
    "@ai-sdk/deepseek", "@ai-sdk/togetherai",
}


def main() -> None:
    request = urllib.request.Request(SOURCE, headers={"User-Agent": "coucou-update-providers"})  # the default one gets a 403
    with urllib.request.urlopen(request, timeout=60) as response:
        catalog = json.load(response)
    providers = []
    for pid, entry in catalog.items():
        url = entry.get("api") or KNOWN_URLS.get(pid)
        if pid in BUILT_IN or not url or "${" in url or not url.startswith(SAFE_SCHEMES):
            continue
        if entry.get("npm") not in OPENAI_STYLE and pid not in KNOWN_URLS:
            continue
        item = {"id": pid, "name": entry["name"], "baseURL": url.rstrip("/")}
        if entry.get("env"):
            item["keyEnv"] = entry["env"][0]
        if entry.get("doc"):
            item["doc"] = entry["doc"]
        if pid in POPULAR:
            item["popular"] = True
        providers.append(item)
    providers.sort(key=lambda p: (not p.get("popular", False),
                                  POPULAR.index(p["id"]) if p.get("popular") else 0, p["name"].lower()))
    OUT.write_text(json.dumps({"source": "https://models.dev (snapshot, MIT)", "providers": providers},
                              ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    print(f"{len(providers)} providers written to {OUT}", file=sys.stderr)


if __name__ == "__main__":
    main()
