// « OK Coucou »: say it, then ask anything. Turning it on, how Coucou answers
// out loud, and what leaves the computer. Port of the Mac's Settings → Voice.

import { h, clear } from "../../views/dom";
import { t } from "../../i18n/i18n";
import { Bridge } from "../../core/bridge";
import { FlowBridge } from "../../core/flow";
import type { VoiceOutput } from "../../core/flow";
import type { HubContext } from "../shell";
import { button, card, divider, label, row, segmented, toggle } from "../ui";
import { modelsControl } from "./flowsettings";

const ELEVEN = "elevenlabs-api-key";
/** Where secrets.rs keeps the keys on this OS (same words as Notch → Chat). */
const KEY_STORE = navigator.userAgent.includes("Windows") ? "Windows Credential Manager" : "Secret Service (GNOME Keyring, KWallet)";

function elevenKey(): HTMLElement {
  const box = h("div", { style: "display:flex;align-items:center;gap:8px" });
  const draw = async () => {
    const present = (await Bridge.secretPresent(ELEVEN)) ?? false;
    clear(box);
    if (present) {
      box.append(
        h("span", { class: "hub-note", style: "color:var(--hub-green)", text: `✓ ${t("Key saved in the {store}.", { store: KEY_STORE })}` }),
        button(t("Remove"), () => void Bridge.secretClear(ELEVEN).then(draw), "", true),
      );
      return;
    }
    const input = h("input", { class: "hub-input", type: "password", placeholder: t("ElevenLabs key"), autocomplete: "off", spellcheck: "false", style: "width:220px" }) as HTMLInputElement;
    const save = button(t("Save key"), () => {
      const value = input.value.trim();
      if (!value) return;
      void Bridge.secretSet(ELEVEN, value).then(draw, () => input.classList.add("err"));
    }, "primary", true);
    input.addEventListener("keydown", (e) => {
      if (e.key === "Enter") save.click();
    });
    box.append(input, save);
  };
  void draw();
  return box;
}

export async function voicePage(page: HTMLElement, ctx: HubContext) {
  const status = await ctx.refresh();
  const prefs = status.prefs;
  page.append(ctx.hero("voice", "OK Coucou", t("Talk to Mochi using the selected voice provider.")));

  const ready = status.models.parakeet.state === "ready";
  page.append(card(
    row(t("Talk to Mochi"), t("Ctrl+Alt+C starts a turn. Pause to send; Ctrl+Alt+Enter sends now; Ctrl+Alt+Esc cancels. The microphone closes before the answer."),
      button(t("Talk to Mochi"), () => void FlowBridge.pillAction("voice"), "primary")),
  ));
  page.append(label(t("Listening")));
  const main = card(
    row(t("Listen for « OK Coucou »"), t("The microphone stays open; only what follows « OK Coucou » goes further."),
      toggle(prefs.voice, (on) => void ctx.setPrefs((p) => (p.voice = on)).then(() => ctx.navigate("voice")))),
    divider(),
    row(t("Parakeet, on your computer"), t("Hears « OK Coucou » here, without the internet."), modelsControl(ctx, () => ctx.navigate("voice"))),
  );
  if (!status.voiceProviderReady) {
    main.append(h("div", { class: "hub-warn", text: t("Choose a local Ollama model or configure Claude, and download the voice model first.") }));
  } else if (!ready) {
    main.append(h("div", { class: "hub-warn", text: t("Download the voice model so Coucou can hear you.") }));
  }
  main.append(h("div", { class: "hub-note", text: t("Continuous listening keeps Bluetooth headphones in call mode. Turn it off to keep stereo between conversations.") }));
  page.append(main);

  page.append(label(t("Answers")));
  const outputs: [VoiceOutput, string][] = [["system", t("System voice")], ["elevenlabs", "ElevenLabs"], ["off", t("Text only")]];
  const answers = card(
    row(t("Coucou answers out loud"), null, segmented(outputs, prefs.voiceOutput, (v) => void ctx.setPrefs((p) => (p.voiceOutput = v)).then(() => ctx.navigate("voice")))),
  );
  if (prefs.voiceOutput === "elevenlabs") {
    answers.append(
      divider(),
      row(t("Voice"), null, segmented([["female", t("Female")], ["male", t("Male")]], prefs.voiceGender, (g) => void ctx.setPrefs((p) => (p.voiceGender = g)))),
      divider(),
      row(t("ElevenLabs key"), null, elevenKey()),
    );
  }
  page.append(answers);

  page.append(label(t("Privacy")));
  page.append(card(
    h("div", { class: "hub-note", text: t("Voice recognition stays on this computer. Ollama voice uses your local model; Claude sends the question text to Anthropic. ElevenLabs is used only if selected.") }),
    divider(),
    h("div", { class: "hub-note", text: t("An email is never sent by Coucou: your mail app opens with it written, and you send it.") }),
  ));
}
