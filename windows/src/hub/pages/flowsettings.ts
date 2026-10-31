// Flow → Settings: the key, where the pill is, the microphone, the voice
// model, the Notetaker's summaries, the window and the history. Port of
// FlowHubSettings.swift.

import { h, clear } from "../../views/dom";
import { t } from "../../i18n/i18n";
import { onEvent } from "../../core/bridge";
import { FlowBridge, type Edge, type FlowKey, type ModelsStatus } from "../../core/flow";
import type { HubContext } from "../shell";
import { anchor, button, card, divider, keyKeycap, keycap, label, number, row, segmented, select, toggle } from "../ui";
import { pageSave } from "../save";

/** Download / progress / installed, for the voice model. Redraws itself. */
export function modelsControl(ctx: HubContext, onReady?: () => void): HTMLElement {
  const el = h("div", { style: "display:flex;align-items:center;gap:8px" });
  let confirming = false;
  const draw = (models: ModelsStatus) => {
    clear(el);
    const m = models.parakeet;
    if (m.state === "missing") {
      el.append(button(t("Download"), () => void FlowBridge.download(), "primary"));
    } else if (m.state === "downloading") {
      const bar = h("div", { class: "hub-progress" }, h("i", { style: `width:${Math.round(m.fraction * 100)}%` }));
      el.append(bar, h("span", { class: "hub-note", text: `${Math.round(m.fraction * 100)} %` }));
    } else if (m.state === "failed") {
      el.append(h("span", { class: "hub-note", text: m.error, title: m.error, style: "max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap" }));
      el.append(button(t("Retry"), () => void FlowBridge.download()));
    } else if (confirming) {
      el.append(
        button(t("Remove the models"), () => {
          confirming = false;
          void FlowBridge.removeModels();
        }, "danger", true),
        button(t("Cancel"), () => {
          confirming = false;
          draw(ctx.status.models);
        }, "", true),
      );
    } else {
      const ok = h("button", { class: "hub-link", style: "color:var(--hub-green)", text: `✓ ${t("Installed")}`, title: t("Remove the models") });
      ok.addEventListener("click", () => {
        confirming = true;
        draw(ctx.status.models);
      });
      el.append(ok);
    }
  };
  draw(ctx.status.models);
  void onEvent<ModelsStatus>("speech-models", (models) => {
    if (!el.isConnected) return;
    const wasReady = ctx.status.models.parakeet.state === "ready";
    ctx.status.models = models;
    draw(models);
    if (!wasReady && models.parakeet.state === "ready") onReady?.();
  });
  return el;
}

export async function flowSettingsPage(page: HTMLElement, ctx: HubContext) {
  const status = await ctx.refresh();
  const prefs = status.prefs;
  page.append(ctx.hero("flowsettings", t("Settings"), null));

  // ── Keys ──
  const keys: [FlowKey, string][] = [
    ...(status.platform === "windows" ? [["copilot", "Copilot"] as [FlowKey, string]] : []),
    ["right_ctrl", t("Right {0}", { 0: "Ctrl" })],
    ["right_alt", t("Right {0}", { 0: "Alt" })],
    ["right_shift", t("Right {0}", { 0: "Shift" })],
    ["left_ctrl_super", status.platform === "windows" ? "Ctrl + Win" : "Ctrl + Super"],
  ];
  const edges: [Edge, string][] = [["bottom", t("Bottom")], ["bottom-left", t("Bottom-left")], ["bottom-right", t("Bottom-right")], ["left", t("Left")], ["right", t("Right")]];
  page.append(label(t("Keys")));
  const keysCard = card(
    row(t("Hold a key to dictate anywhere"), null, toggle(prefs.enabled, (on) => void ctx.setPrefs((p) => (p.enabled = on)))),
    divider(),
    status.keys === "wayland"
      ? row(t("Hold to dictate"), null, keyKeycap("wayland", status.platform))
      : row(t("Hold to dictate"), prefs.key === "right_alt" ? t("On a keyboard with AltGr, the right Alt types characters: pick another key.") : null,
        select(keys, prefs.key, (key) => void ctx.setPrefs((p) => (p.key = key)).then(() => ctx.navigate("flowsettings")))),
    divider(),
    row(t("Where the pill is"), null, segmented(edges, prefs.edge, (edge) => void ctx.setPrefs((p) => (p.edge = edge)))),
    divider(),
    row(t("Hands-free"), t("Tap twice, speak as long as you like, tap once to paste."), keyKeycap(status.keys === "wayland" ? "wayland" : prefs.key, status.platform, true)),
    divider(),
    row(t("Paste the last dictation again"), t("When the words went to the wrong place."), button(t("Paste again"), () => void FlowBridge.pasteAgain(), "", true)),
    divider(),
    row(t("Cancel a dictation"), null, keycap(t("Esc"))),
  );
  if (status.keys === "wayland") {
    keysCard.append(h("div", {
      class: "hub-warn",
      text: t("On Wayland, the desktop holds the dictation key for Coucou: Ctrl+Alt+V, or the keys you picked when it asked. The first paste asks once to let Coucou type for you."),
    }));
  } else if (status.keys !== "ok") {
    keysCard.append(h("div", { class: "hub-warn", text: t("Coucou can't watch the keyboard here: use the pill's microphone to dictate.") }));
  }
  page.append(anchor("flow.keys", keysCard));

  // ── Microphone ──
  page.append(label(t("Microphone")));
  const mics: [string, string][] = [["", t("System default")], ...status.mics.map((m): [string, string] => [m.name, m.name])];
  if (prefs.mic && !mics.some(([id]) => id === prefs.mic)) mics.push([prefs.mic, prefs.mic]);
  page.append(anchor("flow.permission", card(row(t("Microphone"), t("The one Coucou listens to for dictation and calls."), select(mics, prefs.mic, (mic) => void ctx.setPrefs((p) => (p.mic = mic)))))));

  // ── Recognition ──
  page.append(label(t("Recognition")));
  page.append(anchor("flow.recognition", card(
    row(t("Parakeet, on your computer"), t("The most accurate, offline, 25 languages. Downloaded once (about {0} MB).", { 0: number(status.models.downloadMb) }), modelsControl(ctx)),
    h("div", { class: "hub-note", text: t("Your voice never leaves this computer: Parakeet turns it into text here, and the recording is dropped as soon as it is pasted.") }),
  )));

  const performance = status.performance ?? { availableThreads: 4, threads: 4, automatic: true, tuning: false, measured: false, error: null };
  const choices: [string, string][] = [["0", t("Automatic (measured on this computer)")]];
  for (let n = 1; n <= performance.availableThreads; n++) choices.push([String(n), t("CPU · {0} threads", { 0: n })]);
  const performanceText = h("div", { class: "hub-note" });
  const updatePerformance = (p: typeof performance) => {
    performanceText.textContent = p.error ?? (!p.automatic ? t("CPU · {0} threads", { 0: p.threads }) : p.tuning ? t("Measuring speech performance…")
      : p.measured ? t("Measured choice: CPU · {0} threads", { 0: p.threads })
      : t("Automatic tuning starts after a dictation of at least three seconds. Audio stays in memory and is never saved for tuning."));
  };
  updatePerformance(performance);
  const threadChoice = select(choices, String(prefs.speechThreads), value => {
    threadChoice.disabled = true;
    const restore = () => {
      threadChoice.value = String(ctx.status.prefs.speechThreads);
      threadChoice.disabled = false;
    };
    // The Hub reports the write error; this control reflects the durable choice.
    void ctx.setPrefs(p => (p.speechThreads = Number(value))).then(restore, restore);
  });

  page.append(card(
    row(t("Speech performance"), t("This build uses the CPU. Automatic mode measures supported thread counts and remembers the fastest result."),
      threadChoice),
    performanceText,
    button(t("Measure again"), () => void FlowBridge.retuneSpeech().then(() => ctx.refresh()).then(s => updatePerformance(s.performance)), "", true),
  ));
  const performanceTimer = window.setInterval(() => {
    if (document.visibilityState !== "visible" || !page.isConnected) return;
    void FlowBridge.status().then(s => { if (s && page.isConnected) updatePerformance(s.performance); });
  }, 2000);
  const previousLeave = ctx.onLeave;
  ctx.onLeave = () => { window.clearInterval(performanceTimer); previousLeave?.(); };

  // ── Notetaker ──
  page.append(label(t("Notetaker")));
page.append(anchor("flow.summary", card(
    row(t("Summaries"), null, select([["claude", t("Claude (your key)")], ["ollama", "Ollama"], ["lmstudio", "LM Studio"], ["custom", t("OpenAI-compatible server")], ["off", t("No summary")]], prefs.summaryEngine, (engine) => void ctx.setPrefs((p) => (p.summaryEngine = engine)))),
    h("div", { class: "hub-note", text: t("Summaries use the selected provider and its model from Chat. Only the transcript is sent; chat history is not included.") }),
    divider(),
    h("div", { class: "hub-note", text: t("Audio and transcripts are stored on this computer. Summaries send text to the provider selected in Flow Settings. Tell the people in the call that you are recording.") }),
  )));

  // ── App ──
  page.append(label(t("App")));
  page.append(anchor("flow.app", card(
    row(t("Open this window when you open Coucou"), t("Not when Coucou starts with the computer."), toggle(prefs.openAtLaunch, (on) => void ctx.setPrefs((p) => (p.openAtLaunch = on)))),
  )));

  // ── Privacy ──
  page.append(label(t("Privacy")));
  const keep: [string, string][] = [["0", t("Don't keep")], ["7", t("7 days")], ["30", t("30 days")], ["365", t("1 year")], ["-1", t("Forever")]];
  const confirmRow = h("div", { class: "hub-row" });
  const privacy = card(
    row(t("Keep the history"), null, select(keep, String(prefs.keepDays), (v) => void ctx.setPrefs((p) => (p.keepDays = Number(v))))),
    divider(),
    confirmRow,
    h("div", { class: "hub-note", text: t("The history, the statistics and your notes stay on this computer, in Coucou's folder. Dictations are never saved as audio; a call's audio is deleted as soon as its transcript is written.") }),
  );
  const saveErase = pageSave(privacy);
  const erase = () => {
    clear(confirmRow);
    confirmRow.append(
      button(t("Erase the history"), () => void saveErase(() => FlowBridge.clear(false)), "", true),
      button(t("Erase everything"), () => {
        clear(confirmRow);
        confirmRow.append(
          h("span", { class: "hub-note", style: "flex:1", text: t("Erase the history and the statistics?") }),
          button(t("Erase everything"), () => {
            void saveErase(async () => {
              await FlowBridge.clear(true);
              erase();
            });
          }, "danger", true),
          button(t("Cancel"), erase, "", true),
        );
      }, "", true),
    );
  };
  erase();
  page.append(anchor("flow.privacy", privacy));
}
