// Flow dictation, the voice models and the Notetaker, as the Coucou window and
// the pill see them (src-tauri/src/flow, speech, notes).

import { invoke } from "@tauri-apps/api/core";

const IS_TAURI = typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;

async function call<T>(cmd: string, args?: Record<string, unknown>): Promise<T | null> {
  if (!IS_TAURI) return null;
  try {
    return await invoke<T>(cmd, args);
  } catch (err) {
    console.error(`[coucou] ${cmd} failed`, err);
    return null;
  }
}

async function callOrThrow<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  if (!IS_TAURI) throw new Error("not running inside Coucou");
  return invoke<T>(cmd, args);
}

export type FlowKey = "right_ctrl" | "right_alt" | "right_shift" | "left_ctrl_super";
export type Edge = "bottom" | "left" | "right";
export type Style = "verbatim" | "natural" | "polished";

export interface FlowPrefs {
  enabled: boolean;
  key: FlowKey;
  edge: Edge;
  mic: string;
  keepDays: number;
  cleanup: boolean;
  defaultStyle: Style;
  summaryEngine: "claude" | "off";
  openAtLaunch: boolean;
  /** « OK Coucou »: listen for it and answer with Claude. */
  voice: boolean;
  voiceOutput: VoiceOutput;
  voiceGender: "female" | "male";
}

export type ModelState =
  | { state: "missing" }
  | { state: "downloading"; fraction: number }
  | { state: "ready" }
  | { state: "failed"; error: string };

export interface ModelsStatus {
  parakeet: ModelState;
  downloadMb: number;
}

export interface FlowStatus {
  prefs: FlowPrefs;
  models: ModelsStatus;
  /** "ok", or why the key can't be watched ("wayland", "no-display"). */
  keys: string;
  hasClaudeKey: boolean;
  mics: { name: string; default: boolean }[];
  platform: "windows" | "linux";
  autostarted: boolean;
  userName?: string | null;
}

export interface FlowEntry {
  id: string;
  date: number;
  text: string;
  app?: string | null;
  words: number;
  seconds: number;
}

export interface Totals {
  words: number;
  seconds: number;
  dictations: number;
  wordsPerMinute: number;
  minutesSaved: number;
}

export interface FlowStats {
  week: Totals;
  month: Totals;
  all: Totals;
  daily: [string, number][];
  apps: Record<string, number>;
  streak: number;
}

export interface Replacement {
  id: string;
  from: string;
  to: string;
}

export interface Snippet {
  id: string;
  trigger: string;
  text: string;
}

export interface AppStyle {
  id: string;
  name: string;
  style: Style;
}

export interface Speaker {
  id: string;
  name: string;
  color: number;
  isMe: boolean;
}

export interface NoteLine {
  id: string;
  speaker: string;
  start: number;
  end: number;
  text: string;
}

export interface Todo {
  id: string;
  text: string;
  owner?: string | null;
  due?: string | null;
  done: boolean;
}

export interface Note {
  id: string;
  title: string;
  titleEdited: boolean;
  start: number;
  end?: number | null;
  app?: string | null;
  status: "recording" | "processing" | "ready" | "failed";
  speakers: Speaker[];
  lines: NoteLine[];
  summary?: string | null;
  keyPoints: string[];
  todos: Todo[];
  error?: string | null;
  startLocal: string;
}

export interface NotesState {
  notes: Note[];
  recording: string | null;
  working: string[];
}

export interface Announcement {
  id: number;
  icon: string;
  tint: string;
  text: string;
  action?: string | null;
  actionId?: string | null;
}

export interface PillState {
  phase: "idle" | "listening" | "thinking" | "locked" | "copied" | "failed" | "pastedAgain";
  edge: Edge;
  /** "wayland" where the desktop holds the shortcut. */
  key: FlowKey | "wayland" | "";
  noteStartedAt: number | null;
  announcement: Announcement | null;
  enabled: boolean;
  /** « OK Coucou » is talking with you. */
  voice: VoiceView | null;
}

export interface VoiceView {
  phase: "listening" | "thinking" | "speaking";
  heard: string;
  answer: string;
}

export type VoiceOutput = "system" | "elevenlabs" | "off";

export const FlowBridge = {
  status: () => call<FlowStatus>("flow_status"),
  setPrefs: (prefs: FlowPrefs) => call<void>("flow_set_prefs", { prefs }),
  history: () => call<FlowEntry[]>("flow_history"),
  deleteEntry: (id: string) => call<void>("flow_delete", { id }),
  clear: (everything: boolean) => call<void>("flow_clear", { everything }),
  stats: () => call<FlowStats>("flow_stats"),
  words: () => call<{ words: string[]; replacements: Replacement[] }>("flow_words"),
  setWords: (words: { words: string[]; replacements: Replacement[] }) => call<void>("flow_set_words", { words }),
  snippets: () => call<Snippet[]>("flow_snippets"),
  setSnippets: (snippets: Snippet[]) => call<void>("flow_set_snippets", { snippets }),
  styles: () => call<AppStyle[]>("flow_styles"),
  setStyles: (styles: AppStyle[]) => call<void>("flow_set_styles", { styles }),
  runningApps: () => call<{ id: string; name: string }[]>("flow_running_apps"),
  copy: (text: string) => call<boolean>("flow_copy", { text }),
  pasteAgain: () => call<void>("flow_paste_again"),
  download: () => call<void>("flow_models_download"),
  removeModels: () => call<void>("flow_models_remove"),

  notes: () => call<NotesState>("notes_state"),
  startNote: () => callOrThrow<string>("notes_start"),
  stopNote: () => call<void>("notes_stop"),
  renameNote: (id: string, title: string) => call<void>("notes_rename", { id, title }),
  renameSpeaker: (id: string, speaker: string, name: string) => call<void>("notes_rename_speaker", { id, speaker, name }),
  toggleTodo: (id: string, todo: string) => call<void>("notes_toggle_todo", { id, todo }),
  deleteNote: (id: string) => call<void>("notes_delete", { id }),
  summarize: (id: string) => call<void>("notes_summarize", { id }),
  retryNote: (id: string) => call<void>("notes_retry", { id }),
  markdown: (id: string) => call<string>("notes_markdown", { id }),
  exportNote: (id: string) => callOrThrow<string>("notes_export", { id }),

  pillState: () => call<PillState>("pill_state"),
  pillHot: (rects: [number, number, number, number][]) => call<void>("pill_hot", { rects }),
  pillHover: (inside: boolean) => call<void>("pill_hover", { inside }),
  pillAction: (action: string, id?: number) => call<void>("pill_action", { action, id: id ?? null }),
  /** The pill has said what « OK Coucou » answered. */
  voiceDone: (id: number) => call<void>("voice_done", { id, text: null }),
  /** speech-dispatcher or espeak-ng, where the webview has no voice. */
  sayNative: (text: string, lang: string | null) => call<boolean>("voice_say_native", { text, lang }),
};

/** One colour per person in a call: you first, then the others. */
export const SPEAKER_COLORS = ["#3B9EFF", "#34D399", "#A78BFA", "#F7B32B", "#F472B6", "#22D3EE"];

export function speakerColor(index: number): string {
  return SPEAKER_COLORS[Math.max(0, index) % SPEAKER_COLORS.length];
}

/** 75 → "1:15", 3725 → "1:02:05". */
export function clock(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const two = (n: number) => String(n).padStart(2, "0");
  if (s >= 3600) return `${Math.floor(s / 3600)}:${two(Math.floor((s % 3600) / 60))}:${two(s % 60)}`;
  return `${Math.floor(s / 60)}:${two(s % 60)}`;
}
