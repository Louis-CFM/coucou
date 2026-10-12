// A Maki conversation through the user's ElevenLabs agent (src-tauri/src/eleven.rs).
//
// The wake word is heard on the device (voice.rs); then this opens the agent's
// WebSocket with a signed URL, streams the microphone as 16 kHz PCM, plays the
// agent's voice back, shows both sides in the island, and runs the agent's
// client tools: `coucou` here, `ask_hermes` through Rust. The conversation
// ends when the agent hangs up (it does on "bye" and after 20 s of silence),
// or on a click on the card; the wake word listener then takes the mic back.

import { Bridge } from "../core/bridge";
import { Sound } from "../core/sound";
import { Spotify } from "../core/spotify";
import { Todos } from "../core/extras";
import { openTarget } from "../core/intents";
import { endLive, showLive, Live, type LiveHost } from "../island/live";
import { startFocus, stopFocus } from "../views/extras";
import { agentsText, planText } from "./voice";
import { t } from "../i18n/i18n";

let ws: WebSocket | null = null;
let host: LiveHost | null = null;

/** One line in the island: who spoke last and what. */
function caption(text: string) {
  if (!host) return;
  showLive(host, { kind: "voice", level: null, muted: false, charging: false, text }, 25_000);
}

// ── Audio ─────────────────────────────────────────────────────────────────────

function toBase64(bytes: Uint8Array): string {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

function floatToPcm16(f: Float32Array): Uint8Array {
  const out = new Int16Array(f.length);
  for (let i = 0; i < f.length; i++) out[i] = Math.max(-1, Math.min(1, f[i])) * 0x7fff;
  return new Uint8Array(out.buffer);
}

function pcm16ToFloat(b64: string): Float32Array<ArrayBuffer> {
  const bin = atob(b64);
  const n = bin.length >> 1;
  const out = new Float32Array(new ArrayBuffer(n * 4));
  for (let i = 0; i < n; i++) {
    const v = bin.charCodeAt(2 * i) | (bin.charCodeAt(2 * i + 1) << 8);
    out[i] = (v >= 0x8000 ? v - 0x10000 : v) / 0x8000;
  }
  return out;
}

// ── Tools ─────────────────────────────────────────────────────────────────────

interface CoucouParams {
  action: string;
  value?: number;
  label?: string;
}

/** The agent's `coucou` tool: what it did, in a few words for the agent to say. */
async function coucouTool(p: CoucouParams): Promise<string> {
  const playing = Spotify.state.playing;
  switch (p.action) {
    case "play_pause":
      if (!Spotify.state.track) return "Nothing is loaded in a music player.";
      await Bridge.spotifyControl("playPause");
      return playing ? "Paused." : "Playing.";
    case "next_track":
      await Bridge.spotifyControl("next");
      return "Skipped to the next track.";
    case "previous_track":
      await Bridge.spotifyControl("previous");
      return "Back to the previous track.";
    case "now_playing": {
      const tr = Spotify.state.track;
      return tr ? `${playing ? "Playing" : "Paused"}: ${tr.title} by ${tr.artist}.` : "Nothing is playing.";
    }
    case "volume_up":
    case "volume_down":
    case "mute":
      await Bridge.volumeKey(p.action === "volume_up" ? "up" : p.action === "volume_down" ? "down" : "mute");
      return "Done.";
    case "set_volume":
      await Bridge.spotifyControl("volume", Math.max(0, Math.min(100, Math.round(p.value ?? 50))));
      return `Volume set to ${Math.round(p.value ?? 50)}%.`;
    case "start_focus": {
      const m = Math.max(1, Math.min(600, Math.round(p.value ?? 25)));
      startFocus(m);
      return `Focus started for ${m} minutes; notifications are held.`;
    }
    case "stop_focus":
      stopFocus();
      return "Focus stopped.";
    case "timer": {
      const m = Math.max(1, Math.min(600, Math.round(p.value ?? 5)));
      const label = p.label?.trim() || "Timer";
      window.setTimeout(() => {
        Sound.play("finish");
        if (host) showLive(host, { kind: "focus", level: 1, muted: false, charging: false, text: label }, 8000);
        void Bridge.phonePush(t("Reminder"), label, false, false);
      }, m * 60_000);
      return `Timer set for ${m} minutes${p.label ? ` to ${p.label}` : ""}.`;
    }
    case "add_todo":
      if (!p.label?.trim()) return "Tell me what to add.";
      Todos.add(p.label);
      return `Added "${p.label.trim()}" to the to-do list.`;
    case "list_todos": {
      const open = Todos.items.filter((x) => !x.done).map((x) => x.text);
      return open.length ? `Open to-dos: ${open.join("; ")}.` : "The to-do list is empty.";
    }
    case "claude_usage":
      return planText();
    case "agents_status":
      return agentsText();
    case "open": {
      if (!p.label?.trim()) return "Tell me what to open.";
      const where = openTarget(p.label);
      if ("url" in where) void Bridge.openUrl(where.url);
      else if (where.app === "phoneLink") void Bridge.openPhoneLink();
      else if (where.app === "settings") void Bridge.openSettingsWindow();
      else void Bridge.spotifyOpen();
      return `Opened ${p.label}.`;
    }
    default:
      return `I can't do "${p.action}".`;
  }
}

async function runTool(name: string, params: Record<string, unknown>): Promise<{ result: string; error: boolean }> {
  try {
    if (name === "ask_hermes") {
      caption(t("Asking Hermes…"));
      const answer = await Bridge.askHermes(String(params.request ?? ""));
      return { result: answer ?? "", error: false };
    }
    if (name === "coucou") return { result: await coucouTool(params as unknown as CoucouParams), error: false };
    return { result: `Unknown tool ${name}.`, error: true };
  } catch (e) {
    return { result: String(e).replace(/^Error:\s*/, ""), error: true };
  }
}

// ── The conversation ──────────────────────────────────────────────────────────

export function talking(): boolean {
  return ws != null;
}

export function endConversation() {
  ws?.close();
}

export async function startConversation(liveHost: LiveHost, agentId: string) {
  if (ws) return;
  host = liveHost;
  caption(t("Connecting…"));
  const ended = () => {
    void Bridge.voiceConversationEnded();
    if (Live.current?.kind === "voice") endLive(liveHost);
  };
  let url: string | null;
  try {
    url = await Bridge.elevenSignedUrl(agentId || null);
  } catch (e) {
    caption(String(e).replace(/^Error:\s*/, ""));
    window.setTimeout(ended, 4000);
    return;
  }
  let stream: MediaStream;
  try {
    stream = await navigator.mediaDevices.getUserMedia({
      audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true, channelCount: 1 },
    });
  } catch (e) {
    void Bridge.log(`eleven: no microphone (${String(e)})`);
    caption(t("Coucou can't use the microphone."));
    window.setTimeout(ended, 4000);
    return;
  }
  const socket = new WebSocket(url ?? "");
  ws = socket;
  const ctx = new AudioContext({ sampleRate: 16000 });
  let outRate = 16000;
  let playAt = 0;
  const playing = new Set<AudioBufferSourceNode>();
  const source = ctx.createMediaStreamSource(stream);
  // ponytail: ScriptProcessor (deprecated, main thread) — an AudioWorklet needs a module URL the CSP doesn't allow.
  const proc = ctx.createScriptProcessor(2048, 1, 1);
  const mute = ctx.createGain();
  mute.gain.value = 0;
  proc.onaudioprocess = (e) => {
    if (socket.readyState === WebSocket.OPEN) {
      socket.send(JSON.stringify({ user_audio_chunk: toBase64(floatToPcm16(e.inputBuffer.getChannelData(0))) }));
    }
  };
  source.connect(proc);
  proc.connect(mute);
  mute.connect(ctx.destination);

  const stopPlayback = () => {
    for (const s of playing) {
      try {
        s.stop();
      } catch {
        /* already done */
      }
    }
    playing.clear();
    playAt = ctx.currentTime;
  };

  socket.onopen = () => {
    void Bridge.log("eleven: conversation open");
    socket.send(JSON.stringify({ type: "conversation_initiation_client_data" }));
    caption(t("Listening…"));
  };
  socket.onmessage = (ev) => {
    let msg: Record<string, any>;
    try {
      msg = JSON.parse(String(ev.data));
    } catch {
      return;
    }
    switch (msg.type) {
      case "conversation_initiation_metadata": {
        const fmt = String(msg.conversation_initiation_metadata_event?.agent_output_audio_format ?? "pcm_16000");
        const rate = Number(/pcm_(\d+)/.exec(fmt)?.[1]);
        if (rate) outRate = rate;
        break;
      }
      case "ping":
        socket.send(JSON.stringify({ type: "pong", event_id: msg.ping_event?.event_id }));
        break;
      case "audio": {
        const b64 = msg.audio_event?.audio_base_64;
        if (!b64) break;
        const data = pcm16ToFloat(b64);
        const buf = ctx.createBuffer(1, data.length, outRate);
        buf.copyToChannel(data, 0);
        const node = ctx.createBufferSource();
        node.buffer = buf;
        node.connect(ctx.destination);
        playAt = Math.max(playAt, ctx.currentTime + 0.02);
        node.start(playAt);
        playAt += buf.duration;
        playing.add(node);
        node.onended = () => playing.delete(node);
        break;
      }
      case "interruption":
        stopPlayback();
        break;
      case "user_transcript": {
        const text = msg.user_transcription_event?.user_transcript;
        if (text) caption(`${t("You")}: ${text}`);
        break;
      }
      case "agent_response": {
        const text = msg.agent_response_event?.agent_response;
        if (text) caption(`Maki: ${text}`);
        break;
      }
      case "client_tool_call": {
        const call = msg.client_tool_call ?? {};
        void runTool(String(call.tool_name ?? ""), call.parameters ?? {}).then(({ result, error }) => {
          if (socket.readyState === WebSocket.OPEN) {
            socket.send(JSON.stringify({ type: "client_tool_result", tool_call_id: call.tool_call_id, result, is_error: error }));
          }
        });
        break;
      }
    }
  };
  socket.onclose = (ev) => {
    void Bridge.log(`eleven: conversation closed (${ev.code})`);
    stopPlayback();
    proc.disconnect();
    source.disconnect();
    for (const tr of stream.getTracks()) tr.stop();
    void ctx.close();
    ws = null;
    Sound.play("close");
    ended();
  };
  socket.onerror = () => void Bridge.log("eleven: socket error");
}
