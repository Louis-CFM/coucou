// Settings window — the place where anything that writes to disk is confirmed.
// Stage 2 covers the Claude Code hooks and the general preferences; API keys and
// integrations land here too in a later stage.

import "./settings.css";
import { Bridge, onEvent, type HookStatus } from "../core/bridge";
import { DEFAULT_SETTINGS, type Settings } from "../core/state";
import { formatEdgeRate, formatEdgeVolume } from "../core/voice";
import { h, clear } from "../views/dom";

let settings: Settings = { ...DEFAULT_SETTINGS };
let version = "";

const root = document.getElementById("settings-root")!;

async function save() {
  await Bridge.saveSettings(settings);
}

// ── Reusable bits ─────────────────────────────────────────────────────────────

function toggle(on: boolean, onChange: (v: boolean) => void): HTMLElement {
  const el = h("button", { class: on ? "switch on" : "switch", "aria-pressed": on });
  el.addEventListener("click", () => {
    const next = !el.classList.contains("on");
    el.classList.toggle("on", next);
    onChange(next);
  });
  return el;
}

function statusDot(ok: boolean): HTMLElement {
  return h("i", { class: "dot", style: `background:${ok ? "#22c55e" : "#f4505e"}` });
}

function renderDiff(text: string): HTMLElement {
  const box = h("div", { class: "diff" });
  for (const line of text.split("\n")) {
    const cls = line.startsWith("+") ? "add" : line.startsWith("-") ? "del" : "ctx";
    box.append(h("div", { class: cls, text: line }));
  }
  return box;
}

// ── Claude Code section ───────────────────────────────────────────────────────

function claudeSection(status: HookStatus): HTMLElement {
  const body = h("div", { style: "display:flex;flex-direction:column;gap:12px" });
  const section = h(
    "section",
    {},
    h("h2", {}, statusDot(status.installed), h("span", { text: "Claude Code" })),
    body,
  );

  const rebuild = async () => {
    const fresh = await Bridge.hooksStatus();
    if (fresh) Object.assign(status, fresh);
    clear(body);
    draw();
    const head = section.querySelector("h2")!;
    clear(head);
    head.append(statusDot(status.installed), h("span", { text: "Claude Code" }));
  };

  function draw() {
    body.append(
      h("div", {
        class: "hint",
        text: status.installed
          ? "Coucou is hooked into your Claude Code sessions. Tool calls, questions and permission requests show up in the island, and you can answer them there."
          : "Install the hooks to see your Claude Code sessions in the island and approve permissions without leaving what you are doing.",
      }),
      h("div", { class: "row" },
        h("label", { text: "settings.json" }),
        h("span", { class: "path", text: status.settingsPath }),
      ),
      h("div", { class: "row" },
        h("label", { text: "Relay" }),
        h("span", { class: "path", text: status.hookPath }),
        statusDot(status.hookReady),
      ),
    );

    if (!status.hookReady) {
      body.append(h("div", {
        class: "notice warn",
        text: "coucou-hook.exe is not in place yet. Restart Coucou; if it still fails, build it with `cargo build -p coucou-hook`.",
      }));
    }

    const actions = h("div", { class: "row" });
    const install = h("button", {
      class: "primary",
      text: status.installed ? "Reinstall hooks…" : "Install hooks…",
      onclick: () => showPreview(true),
    });
    // Writing hook commands that point at a relay which isn't there would give
    // every Claude Code session a broken hook and nothing to show for it.
    if (!status.hookReady) {
      install.disabled = true;
      install.title = "The relay isn't installed yet.";
    }
    actions.append(install);
    if (status.installed) {
      actions.append(h("button", {
        class: "danger",
        text: "Uninstall hooks…",
        onclick: () => showPreview(false),
      }));
    }
    body.append(actions);
  }

  async function showPreview(install: boolean) {
    let preview;
    try {
      preview = await Bridge.hooksPreview(install);
    } catch (err) {
      // An unreadable or invalid settings.json stops here rather than being
      // treated as empty and written over.
      clear(body);
      body.append(
        h("div", { class: "notice err", text: String(err).replace(/^Error:\s*/, "") }),
        h("div", { class: "row" }, h("button", {
          text: "Back",
          onclick: () => { clear(body); draw(); },
        })),
      );
      return;
    }
    if (!preview) return;
    clear(body);
    body.append(
      h("div", {
        class: "hint",
        text: install
          ? "This is exactly what will change in your settings.json. Your own hooks are left untouched."
          : "This removes Coucou's entries only. Your own hooks are left untouched.",
      }),
      renderDiff(preview.diff),
      h("div", { class: "row" },
        h("span", { class: "path", text: `Backup → ${preview.backup}` }),
      ),
    );
    const confirm = h("button", {
      class: install ? "primary" : "danger",
      text: install ? "Back up and write" : "Back up and remove",
    });
    confirm.addEventListener("click", async () => {
      confirm.disabled = true;
      try {
        const backup = await Bridge.hooksApply(install, preview.fingerprint);
        clear(body);
        body.append(h("div", {
          class: "notice ok",
          text: `Done. Previous settings saved as ${backup}. Open a new Claude Code session to pick the hooks up.`,
        }));
        window.setTimeout(() => void rebuild(), 2600);
      } catch (err) {
        confirm.disabled = false;
        body.append(h("div", { class: "notice err", text: `Could not write: ${String(err)}` }));
      }
    });
    body.append(h("div", { class: "row" }, confirm, h("button", {
      text: "Cancel",
      onclick: () => { clear(body); draw(); },
    })));
  }

  draw();
  return section;
}

// ── Claude API section ────────────────────────────────────────────────────────

const MODELS: [string, string][] = [
  ["claude-opus-5", "Claude Opus 5"],
  ["claude-sonnet-5", "Claude Sonnet 5"],
  ["claude-haiku-4-5", "Claude Haiku 4.5"],
];

function apiSection(hasKey: boolean): HTMLElement {
  const dot = statusDot(hasKey);
  const state = h("span", { class: "hint", text: hasKey ? "Key saved in the Windows Credential Manager." : "No key yet — the chat needs one." });

  const field = h("input", {
    type: "password",
    placeholder: hasKey ? "••••••••••••  (stored)" : "sk-ant-...",
    style: "flex:1 1 auto;min-width:0",
    autocomplete: "off",
    spellcheck: "false",
  }) as HTMLInputElement;

  const saveBtn = h("button", { class: "primary", text: "Save key" });
  const clearBtn = h("button", { class: "danger", text: "Remove" });
  const feedback = h("div", {});

  async function refresh() {
    const present = (await Bridge.secretPresent("anthropic-api-key")) ?? false;
    dot.style.background = present ? "#22c55e" : "#f4505e";
    state.textContent = present
      ? "Key saved in the Windows Credential Manager."
      : "No key yet — the chat needs one.";
    field.placeholder = present ? "••••••••••••  (stored)" : "sk-ant-...";
    clearBtn.style.display = present ? "" : "none";
  }

  saveBtn.addEventListener("click", async () => {
    const value = field.value.trim();
    if (!value) return;
    clear(feedback);
    try {
      await Bridge.secretSet("anthropic-api-key", value);
      field.value = "";
      feedback.append(h("div", { class: "notice ok", text: "Saved. It never touches disk." }));
      await refresh();
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: `Could not save: ${String(err)}` }));
    }
  });

  clearBtn.addEventListener("click", async () => {
    clear(feedback);
    try {
      await Bridge.secretClear("anthropic-api-key");
      feedback.append(h("div", { class: "notice ok", text: "Key removed." }));
      await refresh();
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: `Could not remove: ${String(err)}` }));
    }
  });

  const model = h("select", {}) as HTMLSelectElement;
  for (const [id, label] of MODELS) model.append(h("option", { value: id, text: label }));
  if (!MODELS.some(([id]) => id === settings.model)) {
    model.append(h("option", { value: settings.model, text: settings.model }));
  }
  model.value = settings.model;
  model.addEventListener("change", () => {
    settings.model = model.value;
    void save();
  });

  clearBtn.style.display = hasKey ? "" : "none";

  return h(
    "section",
    {},
    h("h2", {}, dot, h("span", { text: "Claude" })),
    state,
    h("div", { class: "row" }, h("label", { text: "API key" }), field, saveBtn, clearBtn),
    h("div", { class: "row" }, h("label", { text: "Model" }), model),
    feedback,
  );
}

// ── Integrations section ──────────────────────────────────────────────────────

interface IntegrationDef {
  id: string;
  name: string;
  color: string;
  /** Credential Manager keys, in the order they are shown. */
  fields: { key: string; label: string; placeholder: string; secret: boolean }[];
}

const INTEGRATIONS: IntegrationDef[] = [
  { id: "integration_stripe", name: "Stripe", color: "#0570DE",
    fields: [{ key: "stripe-api-key", label: "Secret key", placeholder: "sk_live_…", secret: true }] },
  { id: "integration_github", name: "GitHub", color: "#F4505E",
    fields: [{ key: "github-token", label: "Token", placeholder: "ghp_…", secret: true }] },
  { id: "integration_vercel", name: "Vercel", color: "#7C5CFF",
    fields: [{ key: "vercel-token", label: "Token", placeholder: "…", secret: true }] },
  { id: "integration_n8n", name: "n8n", color: "#F29B38",
    fields: [
      { key: "n8n-url", label: "Instance URL", placeholder: "https://n8n.example.com", secret: false },
      { key: "n8n-api-key", label: "API key", placeholder: "…", secret: true },
    ] },
  { id: "integration_resend", name: "Resend", color: "#22C55E",
    fields: [{ key: "resend-api-key", label: "API key", placeholder: "re_…", secret: true }] },
  { id: "integration_notion", name: "Notion", color: "#8C8C8C",
    fields: [{ key: "notion-api-key", label: "Integration token", placeholder: "ntn_…", secret: true }] },
  { id: "integration_calcom", name: "Cal.com", color: "#C9956A",
    fields: [{ key: "calcom-api-key", label: "API key", placeholder: "cal_…", secret: true }] },
];

const MAX_ACTIVE = 4;

function integrationsSection(present: Record<string, boolean>): HTMLElement {
  const note = h("div", { class: "hint" });
  const list = h("div", { style: "display:flex;flex-direction:column;gap:14px" });

  function updateNote() {
    const used = settings.activeIntegrations.length;
    note.textContent = `Pick up to ${MAX_ACTIVE} pills to show next to Mochi — ${used}/${MAX_ACTIVE} in use. Keys are stored in the Windows Credential Manager, never on disk.`;
  }

  for (const def of INTEGRATIONS) {
    const active = settings.activeIntegrations.includes(def.id);
    const sw = h("button", { class: active ? "switch on" : "switch" });
    sw.addEventListener("click", () => {
      const on = settings.activeIntegrations.includes(def.id);
      if (on) {
        settings.activeIntegrations = settings.activeIntegrations.filter((x) => x !== def.id);
      } else {
        if (settings.activeIntegrations.length >= MAX_ACTIVE) return;
        settings.activeIntegrations = [...settings.activeIntegrations, def.id];
      }
      sw.classList.toggle("on", !on);
      updateNote();
      void save();
    });

    const rows = h("div", { style: "display:flex;flex-direction:column;gap:6px;flex:1 1 auto;min-width:0" });
    for (const field of def.fields) {
      const input = h("input", {
        type: field.secret ? "password" : "text",
        placeholder: present[field.key] ? "••••••••  (stored)" : field.placeholder,
        autocomplete: "off",
        spellcheck: "false",
        style: "flex:1 1 auto;min-width:0",
      }) as HTMLInputElement;
      const saveBtn = h("button", { text: "Save" });
      const dotEl = statusDot(present[field.key] ?? false);
      saveBtn.addEventListener("click", async () => {
        const value = input.value.trim();
        try {
          await Bridge.secretSet(field.key, value);
          present[field.key] = value.length > 0;
          input.value = "";
          input.placeholder = value ? "••••••••  (stored)" : field.placeholder;
          dotEl.style.background = value ? "#22c55e" : "#f4505e";
        } catch {
          dotEl.style.background = "#f5a524";
        }
      });
      rows.append(
        h("div", { class: "row" },
          h("label", { style: "min-width:104px", text: field.label }),
          input, saveBtn, dotEl,
        ),
      );
    }

    list.append(
      h("div", { style: "display:flex;gap:12px;align-items:flex-start" },
        h("div", { style: "display:flex;align-items:center;gap:8px;min-width:132px;padding-top:4px" },
          sw,
          h("i", { class: "dot", style: `background:${def.color}` }),
          h("span", { style: "font-size:12.5px", text: def.name }),
        ),
        rows,
      ),
    );
  }

  updateNote();
  return h("section", {}, h("h2", {}, h("span", { text: "Integrations" })), note, list);
}

// ── Local LLM section ─────────────────────────────────────────────────────────

const LOCAL_PROVIDERS: { id: "ollama" | "lmstudio" | "unsloth" | "custom"; name: string; url: string }[] = [
  { id: "ollama", name: "Ollama", url: "http://localhost:11434" },
  { id: "lmstudio", name: "LM Studio", url: "http://localhost:1234" },
  { id: "unsloth", name: "Unsloth", url: "http://localhost:8000" },
  { id: "custom", name: "Custom (OpenAI-compatible)", url: "" },
];

function localLlmSection(): HTMLElement {
  const dot = statusDot(false);

  const providerSelect = h("select", {}) as HTMLSelectElement;
  for (const p of LOCAL_PROVIDERS) {
    providerSelect.append(h("option", { value: p.id, text: p.name }));
  }
  providerSelect.value = settings.localProvider;

  const urlInput = h("input", {
    type: "text",
    placeholder: "http://localhost:11434",
    style: "flex:1 1 auto;min-width:0",
    value: settings.localServerUrl || "http://localhost:11434",
    autocomplete: "off",
    spellcheck: "false",
  }) as HTMLInputElement;

  providerSelect.addEventListener("change", () => {
    const chosen = providerSelect.value as "ollama" | "lmstudio" | "unsloth" | "custom";
    settings.localProvider = chosen;
    const match = LOCAL_PROVIDERS.find((p) => p.id === chosen);
    if (match && match.url) {
      urlInput.value = match.url;
      settings.localServerUrl = match.url;
    }
    void save();
  });

  urlInput.addEventListener("input", () => {
    settings.localServerUrl = urlInput.value.trim();
    void save();
  });

  const modelSelect = h("select", { style: "flex:1 1 auto;min-width:0" }) as HTMLSelectElement;
  if (settings.localModel) {
    modelSelect.append(h("option", { value: settings.localModel, text: settings.localModel }));
    modelSelect.value = settings.localModel;
  }
  modelSelect.addEventListener("change", () => {
    settings.localModel = modelSelect.value;
    void save();
  });

  const connectBtn = h("button", { class: "primary", text: "Fetch models" });
  const feedback = h("div", {});

  async function fetchModels() {
    clear(feedback);
    connectBtn.disabled = true;
    const url = urlInput.value.trim() || settings.localServerUrl;
    settings.localServerUrl = url;
    void save();
    try {
      const list = await Bridge.localChatModels(url);
      clear(modelSelect);
      if (list.length === 0) {
        dot.style.background = "#f5a524";
        feedback.append(h("div", { class: "notice warn", text: "Connected, but no models found on server." }));
      } else {
        dot.style.background = "#22c55e";
        for (const m of list) {
          modelSelect.append(h("option", { value: m, text: m }));
        }
        if (list.includes(settings.localModel)) {
          modelSelect.value = settings.localModel;
        } else {
          modelSelect.value = list[0];
          settings.localModel = list[0];
          void save();
        }
        feedback.append(h("div", { class: "notice ok", text: `Found ${list.length} model(s).` }));
      }
    } catch (err) {
      dot.style.background = "#f4505e";
      feedback.append(h("div", { class: "notice err", text: `Connection failed: ${String(err)}` }));
    } finally {
      connectBtn.disabled = false;
    }
  }

  connectBtn.addEventListener("click", () => void fetchModels());

  const chatProviderSelect = h("select", {}) as HTMLSelectElement;
  chatProviderSelect.append(
    h("option", { value: "local", text: "Local LLM" }),
    h("option", { value: "claude", text: "Claude (Anthropic API)" }),
  );
  chatProviderSelect.value = settings.chatProvider;
  chatProviderSelect.addEventListener("change", () => {
    settings.chatProvider = chatProviderSelect.value as "local" | "claude";
    void save();
  });

  return h(
    "section",
    {},
    h("h2", {}, dot, h("span", { text: "Local LLM" })),
    h("div", { class: "hint", text: "Run models locally via Ollama, LM Studio, Unsloth, or any OpenAI-compatible server." }),
    h("div", { class: "row" },
      h("label", { text: "Chat Provider" }),
      chatProviderSelect,
    ),
    h("div", { class: "row" },
      h("label", { text: "Preset" }),
      providerSelect,
    ),
    h("div", { class: "row" },
      h("label", { text: "Server URL" }),
      urlInput,
      connectBtn,
    ),
    h("div", { class: "row" },
      h("label", { text: "Model" }),
      modelSelect,
    ),
    feedback,
  );
}

// ── Voice section ─────────────────────────────────────────────────────────────

const TTS_VOICES = [
  { id: "id-ID-GadisNeural", label: "Indonesian - Gadis (Google Assistant style)" },
  { id: "id-ID-ArdiNeural", label: "Indonesian Male - Ardi" },
  { id: "en-US-JennyNeural", label: "US English Female - Jenny" },
  { id: "en-US-GuyNeural", label: "US English Male - Guy" },
  { id: "", label: "System Default (Offline)" },
];

function voiceSection(): HTMLElement {
  const dot = statusDot(settings.voiceEnabled);

  const enableToggle = toggle(settings.voiceEnabled, (v) => {
    settings.voiceEnabled = v;
    dot.style.background = v ? "#22c55e" : "#f4505e";
    void save();
  });

  const wakeWordInput = h("input", {
    type: "text",
    value: settings.voiceWakeWord || "Hey Coucou",
    placeholder: "Hey Coucou",
    style: "flex:1 1 auto;min-width:0",
    autocomplete: "off",
    spellcheck: "false",
  }) as HTMLInputElement;
  wakeWordInput.addEventListener("change", () => {
    settings.voiceWakeWord = wakeWordInput.value.trim() || "Hey Coucou";
    void save();
  });

  const langSelect = h("select", {}) as HTMLSelectElement;
  langSelect.append(
    h("option", { value: "id-ID", text: "Indonesian (id-ID)" }),
    h("option", { value: "en-US", text: "English (en-US)" }),
  );
  langSelect.value = settings.voiceLanguage;
  langSelect.addEventListener("change", () => {
    settings.voiceLanguage = langSelect.value as "id-ID" | "en-US";
    void save();
  });

  const voiceSelect = h("select", { style: "flex:1 1 auto;min-width:0" }) as HTMLSelectElement;
  for (const v of TTS_VOICES) {
    voiceSelect.append(h("option", { value: v.id, text: v.label }));
  }
  voiceSelect.value = settings.voiceTtsVoice;
  voiceSelect.addEventListener("change", () => {
    settings.voiceTtsVoice = voiceSelect.value;
    void save();
  });

  const responseModeSelect = h("select", {}) as HTMLSelectElement;
  responseModeSelect.append(
    h("option", { value: "concise", text: "Concise (Fast, ~1s summary)" }),
    h("option", { value: "full", text: "Full Response" }),
  );
  responseModeSelect.value = settings.voiceResponseMode || "concise";
  responseModeSelect.addEventListener("change", () => {
    settings.voiceResponseMode = responseModeSelect.value as "concise" | "full";
    void save();
  });

  const deviceSelect = h("select", { style: "flex:1 1 auto;min-width:0" }) as HTMLSelectElement;

  async function refreshInputDevices() {
    try {
      const devices = await navigator.mediaDevices.enumerateDevices();
      const audioInputs = devices.filter((d) => d.kind === "audioinput");
      clear(deviceSelect);

      const defaultOption = h("option", { value: "", text: "Default Microphone" }) as HTMLOptionElement;
      deviceSelect.append(defaultOption);

      audioInputs.forEach((device, idx) => {
        const label = device.label || `Microphone ${idx + 1}`;
        const opt = h("option", { value: device.deviceId, text: label }) as HTMLOptionElement;
        deviceSelect.append(opt);
      });

      deviceSelect.value = settings.voiceInputDevice || "";
    } catch (err) {
      console.error("Failed to enumerate audio devices", err);
    }
  }

  deviceSelect.addEventListener("change", () => {
    settings.voiceInputDevice = deviceSelect.value;
    void save();
  });

  navigator.mediaDevices?.addEventListener("devicechange", () => void refreshInputDevices());
  void refreshInputDevices();

  const boostLabel = h("span", { class: "hint", text: `${(settings.voiceMicGain ?? 2.0).toFixed(1)}x Boost` });
  const boostSlider = h("input", {
    type: "range",
    min: "1.0",
    max: "10.0",
    step: "0.5",
    value: String(settings.voiceMicGain ?? 2.0),
  }) as HTMLInputElement;
  boostSlider.addEventListener("input", () => {
    const val = Number(boostSlider.value) || 2.0;
    settings.voiceMicGain = val;
    boostLabel.textContent = `${val.toFixed(1)}x Boost`;
    void save();
  });

  const testMicBtn = h("button", { text: "Test Mic" }) as HTMLButtonElement;
  const micMeterBar = h("div", { class: "mic-meter-bar" }) as HTMLElement;
  const micMeter = h("div", { class: "mic-meter" }, micMeterBar) as HTMLElement;
  const micStatusLabel = h("span", { class: "hint", text: "Ready to test" }) as HTMLElement;

  let testMicStream: MediaStream | null = null;
  let testAudioCtx: AudioContext | null = null;
  let testAnimFrame: number | null = null;
  let testTimeout: number | null = null;
  let testStartTime = 0;
  let hasHeardSpeech = false;

  function stopMicTest() {
    if (testAnimFrame !== null) {
      cancelAnimationFrame(testAnimFrame);
      testAnimFrame = null;
    }
    if (testTimeout !== null) {
      window.clearTimeout(testTimeout);
      testTimeout = null;
    }
    if (testMicStream) {
      testMicStream.getTracks().forEach((track) => track.stop());
      testMicStream = null;
    }
    if (testAudioCtx) {
      void testAudioCtx.close();
      testAudioCtx = null;
    }
    testMicBtn.textContent = "Test Mic";
    testMicBtn.classList.remove("danger");
    micMeterBar.style.width = "0%";
  }

  async function startMicTest() {
    stopMicTest();
    testMicBtn.textContent = "Stop Test";
    testMicBtn.classList.add("danger");
    micStatusLabel.textContent = "Listening...";
    testStartTime = Date.now();
    hasHeardSpeech = false;

    try {
      const constraints: MediaTrackConstraints = {
        echoCancellation: true,
        noiseSuppression: false,
        autoGainControl: false,
      };
      if (settings.voiceInputDevice && settings.voiceInputDevice !== "default") {
        constraints.deviceId = { exact: settings.voiceInputDevice };
      }
      const stream = await navigator.mediaDevices.getUserMedia({ audio: constraints });
      testMicStream = stream;

      void refreshInputDevices();

      const audioCtx = new AudioContext();
      testAudioCtx = audioCtx;
      const source = audioCtx.createMediaStreamSource(stream);
      const gainNode = audioCtx.createGain();
      gainNode.gain.value = settings.voiceMicGain || 2.0;
      const analyser = audioCtx.createAnalyser();
      analyser.fftSize = 1024;
      source.connect(gainNode);
      gainNode.connect(analyser);

      const dataArray = new Uint8Array(analyser.fftSize);

      const tick = () => {
        if (!testMicStream || !testAudioCtx) return;
        // The slider can move while the test runs: follow it live.
        gainNode.gain.value = settings.voiceMicGain || 2.0;
        analyser.getByteTimeDomainData(dataArray);
        let sq = 0;
        for (let i = 0; i < dataArray.length; i++) {
          const v = (dataArray[i] - 128) / 128;
          sq += v * v;
        }
        const rms = Math.sqrt(sq / dataArray.length);
        const pct = Math.min(100, Math.round(rms * 400));
        micMeterBar.style.width = `${pct}%`;


        if (pct > 10) {
          hasHeardSpeech = true;
          micStatusLabel.textContent = `Volume: ${pct}% (Clear)`;
        } else if (!hasHeardSpeech && Date.now() - testStartTime > 2000) {
          micStatusLabel.textContent = `Volume: ${pct}% (Signal very low, check mute)`;
        } else if (hasHeardSpeech) {
          micStatusLabel.textContent = `Volume: ${pct}%`;
        }

        testAnimFrame = requestAnimationFrame(tick);
      };

      testAnimFrame = requestAnimationFrame(tick);

      testTimeout = window.setTimeout(() => {
        stopMicTest();
        micStatusLabel.textContent = "Test complete";
      }, 8000);
    } catch (err) {
      stopMicTest();
      micStatusLabel.textContent = `Mic error: ${String(err)}`;
    }
  }

  testMicBtn.addEventListener("click", () => {
    if (testMicStream) {
      stopMicTest();
      micStatusLabel.textContent = "Stopped";
    } else {
      void startMicTest();
    }
  });

  window.addEventListener("beforeunload", () => stopMicTest());

  const speedLabel = h("span", { class: "hint", text: `${(settings.voiceSpeed ?? 1.0).toFixed(2)}x` });
  const speedSlider = h("input", {
    type: "range",
    min: "0.8",
    max: "1.5",
    step: "0.05",
    value: String(settings.voiceSpeed ?? 1.0),
  }) as HTMLInputElement;
  speedSlider.addEventListener("input", () => {
    const val = Number(speedSlider.value) || 1.0;
    settings.voiceSpeed = val;
    speedLabel.textContent = `${val.toFixed(2)}x`;
    void save();
  });

  const volumeLabel = h("span", { class: "hint", text: `${Math.round((settings.voiceVolume ?? 1.0) * 100)}%` });
  const volumeSlider = h("input", {
    type: "range",
    min: "0.1",
    max: "1.0",
    step: "0.05",
    value: String(settings.voiceVolume ?? 1.0),
  }) as HTMLInputElement;
  volumeSlider.addEventListener("input", () => {
    const val = Number(volumeSlider.value) || 1.0;
    settings.voiceVolume = val;
    volumeLabel.textContent = `${Math.round(val * 100)}%`;
    void save();
  });

  const sttSelect = h("select", {}) as HTMLSelectElement;
  sttSelect.append(
    h("option", { value: "native", text: "Windows Native (Free, offline)" }),
    h("option", { value: "whisper", text: "Whisper Server (OpenAI-compatible)" }),
  );
  sttSelect.value = settings.voiceSttProvider;

  const whisperUrlInput = h("input", {
    type: "text",
    value: settings.voiceWhisperUrl || "http://localhost:11434",
    placeholder: "http://localhost:11434",
    style: "flex:1 1 auto;min-width:0",
    autocomplete: "off",
    spellcheck: "false",
  }) as HTMLInputElement;
  whisperUrlInput.addEventListener("change", () => {
    settings.voiceWhisperUrl = whisperUrlInput.value.trim();
    void save();
  });

  const whisperRow = h("div", { class: "row" },
    h("label", { text: "Whisper URL" }),
    whisperUrlInput,
  );
  whisperRow.style.display = settings.voiceSttProvider === "whisper" ? "" : "none";

  sttSelect.addEventListener("change", () => {
    settings.voiceSttProvider = sttSelect.value as "native" | "whisper";
    whisperRow.style.display = settings.voiceSttProvider === "whisper" ? "" : "none";
    void save();
  });

  const silenceInput = h("input", {
    type: "number",
    min: "0.5",
    max: "5.0",
    step: "0.1",
    value: String(settings.voiceSilenceTimeout || 1.5),
    style: "width:72px",
  }) as HTMLInputElement;
  silenceInput.addEventListener("change", () => {
    settings.voiceSilenceTimeout = Math.max(0.5, Math.min(5.0, Number(silenceInput.value) || 1.5));
    silenceInput.value = String(settings.voiceSilenceTimeout);
    void save();
  });

  const testBtn = h("button", { class: "primary", text: "Test Voice" });
  const feedback = h("div", {});

  let testAudio: HTMLAudioElement | null = null;
  testBtn.addEventListener("click", async () => {
    clear(feedback);
    if (testAudio) {
      testAudio.pause();
      testAudio = null;
    }
    testBtn.disabled = true;
    try {
      const sampleText = settings.voiceLanguage.startsWith("id")
        ? "Halo! Mochi siap membantu kamu."
        : "Hello! Mochi is ready to assist you.";
      const bytes = await Bridge.ttsSpeak(
        sampleText,
        settings.voiceTtsVoice,
        settings.voiceLanguage,
        formatEdgeRate(settings.voiceSpeed),
        formatEdgeVolume(settings.voiceVolume),
        settings.voicePitch || "+0Hz",
      );
      const uint8 = new Uint8Array(bytes);
      const isWav =
        uint8.length >= 4 &&
        uint8[0] === 0x52 &&
        uint8[1] === 0x49 &&
        uint8[2] === 0x46 &&
        uint8[3] === 0x46;
      const blob = new Blob([uint8], { type: isWav ? "audio/wav" : "audio/mpeg" });
      const url = URL.createObjectURL(blob);
      testAudio = new Audio(url);
      testAudio.onended = () => { URL.revokeObjectURL(url); };
      testAudio.onerror = (e) => {
        URL.revokeObjectURL(url);
        feedback.append(h("div", { class: "notice err", text: `Audio decode error: ${String(e)}` }));
      };
      await testAudio.play();
      feedback.append(h("div", { class: "notice ok", text: "Voice audio played." }));
    } catch (err) {
      feedback.append(h("div", { class: "notice err", text: `Voice test failed: ${String(err)}` }));
    } finally {
      testBtn.disabled = false;
    }
  });

  return h(
    "section",
    {},
    h("h2", {}, dot, h("span", { text: "Voice & Speech" })),
    h("div", { class: "hint", text: "Hands-free wake word detection, native or Whisper STT, and natural Edge TTS speech." }),
    h("div", { class: "row" },
      h("label", { text: "Voice mode" }),
      enableToggle,
    ),
    h("div", { class: "row" },
      h("label", { text: "Wake word" }),
      wakeWordInput,
      h("span", { class: "hint", text: "e.g. 'Hey Coucou' or 'Mochi'" }),
    ),
    h("div", { class: "row" },
      h("label", { text: "Language" }),
      langSelect,
    ),
    h("div", { class: "row" },
      h("label", { text: "TTS Voice" }),
      voiceSelect,
      testBtn,
    ),
    h("div", { class: "row" },
      h("label", { text: "Response Mode" }),
      responseModeSelect,
    ),
    h("div", { class: "row" },
      h("label", { text: "Microphone input" }),
      deviceSelect,
    ),
    h("div", { class: "row" },
      h("label", { text: "Microphone boost" }),
      boostSlider,
      boostLabel,
    ),
    h("div", { class: "row" },
      h("label", { text: "Test microphone" }),
      testMicBtn,
      micMeter,
      micStatusLabel,
    ),
    h("div", { class: "row" },
      h("label", { text: "Voice Speed" }),
      speedSlider,
      speedLabel,
    ),
    h("div", { class: "row" },
      h("label", { text: "Voice Volume" }),
      volumeSlider,
      volumeLabel,
    ),
    h("div", { class: "row" },
      h("label", { text: "STT Engine" }),
      sttSelect,
    ),
    whisperRow,
    h("div", { class: "row" },
      h("label", { text: "Silence timeout" }),
      silenceInput,
      h("span", { class: "hint", text: "seconds of silence before sending audio" }),
    ),
    feedback,
  );
}

// ── General section ───────────────────────────────────────────────────────────

function generalSection(): HTMLElement {
  const volume = h("input", {
    type: "range", min: "0", max: "0.2", step: "0.005",
    value: String(settings.soundVolume),
  }) as HTMLInputElement;
  volume.addEventListener("input", () => {
    settings.soundVolume = Number(volume.value);
    void save();
  });

  const autoClose = h("input", {
    type: "number", min: "5", max: "120", step: "1",
    value: String(Math.round(settings.autoCloseInterval)),
    style: "width:72px",
  }) as HTMLInputElement;
  autoClose.addEventListener("change", () => {
    settings.autoCloseInterval = Math.max(5, Math.min(120, Number(autoClose.value) || 15));
    autoClose.value = String(settings.autoCloseInterval);
    void save();
  });

  const screen = h("select", {}) as HTMLSelectElement;
  screen.append(
    h("option", { value: "primary", text: "Main display" }),
    h("option", { value: "cursor", text: "Display under the cursor" }),
  );
  screen.value = settings.screen;
  screen.addEventListener("change", () => {
    settings.screen = screen.value as Settings["screen"];
    void save();
  });

  return h(
    "section",
    {},
    h("h2", {}, h("span", { text: "General" })),
    h("div", { class: "row" },
      h("label", { text: "Always compact" }),
      toggle(settings.alwaysShowCompact, (v) => { settings.alwaysShowCompact = v; void save(); }),
      h("span", { class: "hint", text: "Always visible in compact mode when idle" }),
    ),
    h("div", { class: "row" },
      h("label", { text: "Web access" }),
      toggle(settings.webAccessEnabled, (v) => { settings.webAccessEnabled = v; void save(); }),
      h("span", { class: "hint", text: "Allow Coucou to search the web and read pages" }),
    ),
    h("div", { class: "row" },
      h("label", { text: "Sound" }),
      toggle(settings.soundEnabled, (v) => { settings.soundEnabled = v; void save(); }),
      volume,
    ),
    h("div", { class: "row" },
      h("label", { text: "Auto-close" }),
      autoClose,
      h("span", { class: "hint", text: "seconds after you leave the island" }),
    ),
    h("div", { class: "row" },
      h("label", { text: "Island lives on" }),
      screen,
    ),
    h("div", { class: "row" },
      h("label", { text: "Launch at startup" }),
      toggle(settings.autostart, (v) => { settings.autostart = v; void save(); }),
    ),
  );
}

// ── Boot ──────────────────────────────────────────────────────────────────────

async function main() {
  const boot = await Bridge.boot();
  if (boot) {
    settings = { ...settings, ...boot.settings };
    version = boot.version;
  }
  const status = (await Bridge.hooksStatus()) ?? {
    installed: false, settingsPath: "", hookPath: "", hookReady: false,
  };

  const hasKey = (await Bridge.secretPresent("anthropic-api-key")) ?? false;

  const keys = [
    "stripe-api-key", "github-token", "vercel-token",
    "n8n-url", "n8n-api-key", "resend-api-key", "notion-api-key", "calcom-api-key",
  ];
  const present: Record<string, boolean> = {};
  for (const k of keys) present[k] = (await Bridge.secretPresent(k)) ?? false;

  clear(root);
  root.append(
    h("h1", {}, h("span", { text: "Coucou" }), h("span", { class: "version", text: version })),
    claudeSection(status),
    localLlmSection(),
    voiceSection(),
    apiSection(hasKey),
    integrationsSection(present),
    generalSection(),
    h("div", {
      class: "hint",
      text: "No telemetry. Network requests only go to the services you configure yourself.",
    }),
  );

  void onEvent<Settings>("settings-changed", (s) => {
    settings = { ...settings, ...s };
  });
}

void main();
