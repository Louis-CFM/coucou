// Maki: the island's voice side. src-tauri/src/voice.rs listens for the wake
// word on the device, then sends the command's words as they come and the
// final text; this file shows them, does what was asked (core/intents.ts)
// or asks Claude, and answers in the island and out loud.
//
// Never: approve a permission, send anything for the user, or keep what was
// said. Declining a permission by voice is allowed (CLAUDE.md, docs/VOICE.md).

import { Bridge, onEvent } from "../core/bridge";
import { State } from "../core/state";
import { Sound } from "../core/sound";
import { Spotify } from "../core/spotify";
import { Todos } from "../core/extras";
import { parseIntent, openTarget, voicePhrases, type Intent } from "../core/intents";
import { availablePills } from "../core/pills";
import { Live, endLive, showLive, type LiveHost } from "../island/live";
import { startFocus, stopFocus } from "../views/extras";
import { t } from "../i18n/i18n";

export interface VoiceHost extends LiveHost {
  /** Opens the island on a view (the answer: "note"). */
  alert(view: "note"): void;
}

let host: VoiceHost | null = null;
/** The last few exchanges, so a follow-up question makes sense to Claude. */
const recent: { q: string; a: string; at: number }[] = [];

// ── Speaking ──────────────────────────────────────────────────────────────────

/** Says it with the Windows voice picked in Settings (WebView2 has them all). */
export function speak(text: string) {
  const plus = State.settings.plus;
  if (!plus?.speakAnswers || typeof speechSynthesis === "undefined") return;
  speechSynthesis.cancel();
  const u = new SpeechSynthesisUtterance(text);
  const voice = speechSynthesis.getVoices().find((v) => v.name === plus.voiceName)
    ?? speechSynthesis.getVoices().find((v) => v.lang === (plus.voiceLanguage || navigator.language));
  if (voice) u.voice = voice;
  u.rate = 1.05;
  speechSynthesis.speak(u);
}

/** The answer: in the open island, and out loud. */
function answer(text: string) {
  State.noteMessage = text;
  host?.alert("note");
  speak(text);
  State.notify();
}

// ── Doing ─────────────────────────────────────────────────────────────────────

function findPill(name: string): string | null {
  const n = name.toLowerCase().replace(/[^a-z0-9]+/g, "");
  if (!n) return null;
  const all = availablePills();
  const exact = all.find((p) => p.name.toLowerCase().replace(/[^a-z0-9]+/g, "") === n);
  return (exact ?? all.find((p) => p.name.toLowerCase().replace(/[^a-z0-9]+/g, "").includes(n)))?.id ?? null;
}

function planText(): string {
  const u = State.planUsage;
  if (!u?.fiveHour && !u?.sevenDay) return t("I don't have your Claude plan numbers yet. Open the plan card and tap refresh.");
  const mins = (at: number) => Math.max(0, Math.round((at - Date.now()) / 60000));
  const parts: string[] = [];
  if (u.fiveHour) parts.push(t("{p}% of your 5-hour window is used, it resets in {m} minutes.", { p: Math.round(u.fiveHour.usedPct), m: mins(u.fiveHour.resetsAt) }));
  if (u.sevenDay) parts.push(t("{p}% of the week.", { p: Math.round(u.sevenDay.usedPct) }));
  return parts.join(" ");
}

function agentsText(): string {
  const busy = State.tasks.filter((x) => !x.isIntegration && x.state !== "idle");
  if (busy.length === 0) return t("No agent is working right now.");
  return busy.map((x) => `${x.name}: ${x.steps.at(-1) ?? x.state}`).join(". ");
}

/** What Coucou knows right now, for Claude to answer with. */
function context(): string {
  const now = new Date();
  const s = Spotify.state;
  const lines = [
    `Time: ${now.toLocaleString()}`,
    s.track ? `Music: ${s.playing ? "playing" : "paused"} "${s.track.title}" by ${s.track.artist} (${s.app || "player"})` : "Music: nothing loaded",
    `Claude plan: ${planText()}`,
    `Agents: ${agentsText()}`,
    `To-dos open: ${Todos.items.filter((x) => !x.done).map((x) => x.text).join("; ") || "none"}`,
  ];
  for (const r of recent.filter((x) => Date.now() - x.at < 120_000)) lines.push(`Earlier — user: ${r.q} / Maki: ${r.a}`);
  return lines.join("\n");
}

async function run(intent: Intent, heard: string) {
  switch (intent.kind) {
    case "cancel":
      endLive(host!);
      return;
    case "music": {
      if (!Spotify.state.track) return answer(t("Nothing is playing."));
      const playing = Spotify.state.playing;
      const action = intent.action === "play" ? (playing ? null : "playPause")
        : intent.action === "pause" ? (playing ? "playPause" : null)
        : intent.action;
      if (action) await Bridge.spotifyControl(action as "playPause" | "next" | "previous");
      Sound.play("blip");
      return;
    }
    case "volume":
      if (intent.action === "set") await Bridge.spotifyControl("volume", intent.value ?? 50);
      else await Bridge.volumeKey(intent.action);
      return;
    case "pill": {
      const id = findPill(intent.name);
      if (!id) return answer(t("I couldn't find a pill called {0}.", { 0: intent.name }));
      const on = State.settings.activeIntegrations.includes(id);
      if (on === (intent.action === "add")) return answer(on ? t("It's already there.") : t("It wasn't there."));
      State.toggleIntegration(id);
      void Bridge.saveSettings(State.settings);
      Sound.play("pop");
      return;
    }
    case "focus":
      startFocus(intent.minutes);
      return answer(t("Focus for {n} minutes. I'll hold your notifications.", { n: intent.minutes }));
    case "focusStop":
      stopFocus();
      return;
    case "timer": {
      const label = intent.label || t("Timer");
      window.setTimeout(() => {
        Sound.play("finish");
        if (host) showLive(host, { kind: "focus", level: 1, muted: false, charging: false, text: label }, 8000);
        speak(intent.label ? t("Reminder: {0}", { 0: intent.label }) : t("Your timer is done."));
        void Bridge.phonePush(t("Reminder"), label, false, false);
      }, intent.minutes * 60_000);
      return answer(intent.label ? t("I'll remind you in {n} minutes.", { n: intent.minutes }) : t("Timer set for {n} minutes.", { n: intent.minutes }));
    }
    case "todoAdd":
      Todos.add(intent.text);
      return answer(t("Added to your to-do list."));
    case "todoList": {
      const open = Todos.items.filter((x) => !x.done).map((x) => x.text);
      return answer(open.length ? open.join(", ") : t("Your to-do list is empty."));
    }
    case "open": {
      const where = openTarget(intent.target);
      if ("url" in where) void Bridge.openUrl(where.url);
      else if (where.app === "phoneLink") void Bridge.openPhoneLink();
      else if (where.app === "settings") void Bridge.openSettingsWindow();
      else void Bridge.spotifyOpen();
      return;
    }
    case "planUsage":
      return answer(planText());
    case "agents":
      return answer(agentsText());
    case "time":
      return answer(new Date().toLocaleTimeString([], { hour: "numeric", minute: "2-digit" }));
    case "deny": {
      const req = State.pendingApproval;
      if (!req) return answer(t("There's nothing waiting for an answer."));
      void Bridge.approvalDecision(req.requestId, "deny");
      State.endApproval();
      return answer(t("Declined."));
    }
    case "approve":
      return answer(t("I can't approve by voice. Click Allow in the island."));
    case "ask": {
      if (host) showLive(host, { kind: "voice", level: null, muted: false, charging: false, text: t("Thinking…") }, 60_000);
      try {
        const reply = (await Bridge.voiceAsk(heard, context())) ?? "";
        recent.push({ q: heard, a: reply, at: Date.now() });
        if (recent.length > 4) recent.shift();
        if (Live.current?.kind === "voice") endLive(host!);
        return answer(reply);
      } catch (e) {
        if (Live.current?.kind === "voice") endLive(host!);
        return answer(String(e).replace(/^Error:\s*/, ""));
      }
    }
  }
}

// ── Events from voice.rs ──────────────────────────────────────────────────────

export function registerVoice(h: VoiceHost) {
  host = h;
  // The on-device recogniser only hears these; pills come and go with the build.
  void Bridge.voiceSetPhrases(voicePhrases(availablePills().map((p) => p.name)));
  void onEvent<string>("voice-state", (s) => {
    if (s === "listening") {
      Sound.play("peek");
      showLive(h, { kind: "voice", level: null, muted: false, charging: false, text: t("Listening…") }, 20_000);
    } else if (s === "needs-online") {
      answer(t("I need Windows' online speech recognition: Settings → Privacy & security → Speech."));
    }
  });
  void onEvent<string>("voice-partial", (text) => {
    showLive(h, { kind: "voice", level: null, muted: false, charging: false, text }, 20_000);
  });
  void onEvent<string>("voice-command", (text) => {
    const heard = text.trim();
    if (!heard) {
      if (Live.current?.kind === "voice") endLive(h);
      return;
    }
    if (heard === "?") {
      if (Live.current?.kind === "voice") endLive(h);
      answer(t("Sorry, I didn't catch that. Try “Maki, pause the music” or “Maki, what time is it”."));
      return;
    }
    const intent = parseIntent(heard);
    if (Live.current?.kind === "voice") endLive(h);
    if (intent) void run(intent, heard);
  });
}
