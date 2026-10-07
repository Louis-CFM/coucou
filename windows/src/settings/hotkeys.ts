// Settings → Hotkeys and Voice. A combo is recorded by pressing it; Rust
// checks it with the same rules it registers with and reports keys another
// app already holds.

import { Bridge, onEvent, type HotkeyStatus } from "../core/bridge";
import type { Hotkeys, Settings } from "../core/state";
import { comboFromEvent, isFnKey, standsAlone } from "../core/hotkeys";
import { h, clear } from "../views/dom";

const ROWS: { key: keyof Hotkeys; label: string; hint: string }[] = [
  { key: "chat", label: "Quick chat", hint: "Opens or hides the small chat window." },
  { key: "task", label: "New task", hint: "Opens or hides the small + Task window." },
  { key: "voice", label: "Voice", hint: "Opens the chat and records; press again to send." },
  { key: "robot", label: "Robot", hint: "Opens or hides the small Robot window: tell it a web task to do in the background." },
];

export function hotkeysSection(get: () => Settings, save: (s: Settings) => Promise<void>): HTMLElement {
  let draft: Hotkeys = { ...get().hotkeys };
  let recording: keyof Hotkeys | null = null;
  let statuses: HotkeyStatus[] = [];
  const fnNote = h("div", { class: "notice warn", style: "display:none" });
  const fields = new Map<keyof Hotkeys, HTMLButtonElement>();
  const errors = new Map<keyof Hotkeys, HTMLElement>();
  const feedback = h("div", {});

  const rows = ROWS.map((row) => {
    const field = h("button", { type: "button", class: "hotkey-field", "aria-label": `${row.label} hotkey` }) as HTMLButtonElement;
    field.addEventListener("click", () => void startRecording(row.key));
    field.addEventListener("keydown", (e) => onKey(row.key, e));
    field.addEventListener("blur", () => {
      if (recording === row.key) void stopRecording();
    });
    const clearBtn = h("button", { type: "button", text: "Off", title: "No hotkey for this", onclick: () => {
      draft = { ...draft, [row.key]: "" };
      draw();
    } });
    const reset = h("button", { type: "button", text: "Default", onclick: () => {
      draft = { ...draft, [row.key]: DEFAULTS[row.key] };
      draw();
    } });
    const err = h("div", { class: "hotkey-error" });
    fields.set(row.key, field);
    errors.set(row.key, err);
    return h("div", { style: "display:flex;flex-direction:column;gap:4px" },
      h("div", { class: "row" }, h("label", { text: row.label }), field, clearBtn, reset),
      h("div", { class: "hint", style: "margin-left:0", text: row.hint }),
      err);
  });

  const saveBtn = h("button", { class: "primary", text: "Save hotkeys", onclick: () => void commit() }) as HTMLButtonElement;

  async function startRecording(key: keyof Hotkeys) {
    if (recording && recording !== key) await stopRecording();
    recording = key;
    fnNote.style.display = "none";
    await Bridge.hotkeysSuspend(true);
    draw();
  }

  async function stopRecording() {
    recording = null;
    const back = await Bridge.hotkeysSuspend(false);
    if (back) statuses = back;
    draw();
  }

  function onKey(key: keyof Hotkeys, e: KeyboardEvent) {
    if (recording !== key) return;
    e.preventDefault();
    e.stopPropagation();
    if (e.key === "Escape") {
      void stopRecording();
      return;
    }
    if (isFnKey(e)) {
      fnNote.textContent = "Fn detected. Fn on its own never reaches Windows, so hold Fn and press the key you want with it (e.g. Fn+F5, Fn+PrtSc, a media key).";
      fnNote.style.display = "";
      return;
    }
    const combo = comboFromEvent(e);
    if (!combo) return;
    const main = combo.split("+").at(-1)!;
    const plain = !e.ctrlKey && !e.altKey && !e.metaKey;
    fnNote.style.display = "none";
    if (plain && !standsAlone(main)) {
      fnNote.textContent = `${combo} alone would block normal typing. Add Ctrl, Alt or Win.`;
      fnNote.style.display = "";
      return;
    }
    draft = { ...draft, [key]: combo };
    void stopRecording();
  }

  async function commit() {
    clear(feedback);
    const next: Hotkeys = { ...draft };
    for (const row of ROWS) {
      try {
        next[row.key] = await Bridge.hotkeyNormalize(draft[row.key]);
      } catch (err) {
        feedback.append(h("div", { class: "notice err", text: `${row.label}: ${String(err).replace(/^Error:\s*/, "")}` }));
        return;
      }
    }
    const used = ROWS.map((r) => next[r.key]).filter(Boolean);
    if (new Set(used).size !== used.length) {
      feedback.append(h("div", { class: "notice err", text: "Two actions use the same keys." }));
      return;
    }
    draft = next;
    saveBtn.disabled = true;
    await save({ ...get(), hotkeys: next });
    saveBtn.disabled = false;
    statuses = (await Bridge.hotkeysStatus()) ?? statuses;
    const failed = statuses.filter((s) => s.error);
    feedback.append(h("div", {
      class: failed.length ? "notice warn" : "notice ok",
      text: failed.length ? "Saved, but some hotkeys could not be registered (see above)." : "Saved. The new hotkeys work now.",
    }));
    draw();
  }

  function draw() {
    for (const row of ROWS) {
      const field = fields.get(row.key)!;
      const rec = recording === row.key;
      field.textContent = rec ? "Press the keys…" : draft[row.key] || "Off";
      field.classList.toggle("recording", rec);
      field.classList.toggle("off", !draft[row.key] && !rec);
      const err = errors.get(row.key)!;
      clear(err);
      const s = statuses.find((x) => x.action === row.key);
      if (s?.error && s.combo === draft[row.key]) err.append(h("div", { class: "notice err", text: `${s.combo}: ${s.error}` }));
    }
    const saved = get().hotkeys;
    saveBtn.disabled = ROWS.every((r) => saved[r.key] === draft[r.key]);
  }

  void (async () => {
    statuses = (await Bridge.hotkeysStatus()) ?? [];
    draw();
  })();
  void onEvent<HotkeyStatus[]>("hotkeys-status", (s) => {
    statuses = s;
    draw();
  });
  void onEvent<Settings>("settings-changed", (s) => {
    if (!recording) draft = { ...s.hotkeys };
    draw();
  });
  draw();

  return h("section", {},
    h("h2", {}, h("span", { text: "Hotkeys" })),
    h("div", { class: "hint", text: "Click a field and press the combination (Ctrl, Alt or Win plus a key). F-keys, media keys, PrtSc and Pause work alone, so Fn+key combinations are fine. Esc cancels. They work in every app." }),
    ...rows,
    fnNote,
    h("div", { class: "row" }, saveBtn),
    feedback);
}

const DEFAULTS: Hotkeys = { chat: "Ctrl+Alt+C", task: "Ctrl+Alt+N", voice: "Ctrl+Alt+V", robot: "Ctrl+Alt+R" };

export function voiceSection(get: () => Settings, save: (s: Settings) => Promise<void>): HTMLElement {
  const model = h("input", {
    type: "text",
    value: get().sttModel,
    placeholder: "groq/whisper-large-v3",
    spellcheck: "false",
    style: "flex:1 1 auto;min-width:0",
  }) as HTMLInputElement;
  const feedback = h("div", {});
  const saveBtn = h("button", { text: "Save", onclick: async () => {
    clear(feedback);
    const value = model.value.trim() || "groq/whisper-large-v3";
    await save({ ...get(), sttModel: value });
    model.value = value;
    feedback.append(h("div", { class: "notice ok", text: "Saved." }));
  } });
  const mic = h("div", {});
  void (async () => {
    const s = await Bridge.microphoneStatus();
    if (s?.blocked) {
      mic.append(h("div", { class: "notice warn" }, h("span", { text: s.message }), " ",
        h("button", { text: "Open microphone settings", onclick: () => void Bridge.openMicrophoneSettings() })));
    }
  })();
  void onEvent<Settings>("settings-changed", (s) => {
    if (document.activeElement !== model) model.value = s.sttModel;
  });

  return h("section", {},
    h("h2", {}, h("span", { text: "Voice" })),
    h("div", { class: "hint", text: "The mic button records and sends the sound to your 9router's /audio/transcriptions. That needs a speech-to-text provider (Groq or OpenAI key) set up in 9router. Without it, press Win+H to use Windows voice typing." }),
    h("div", { class: "row" }, h("label", { text: "Voice model" }), model, saveBtn),
    mic,
    feedback);
}
