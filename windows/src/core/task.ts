// "+ New task" form logic, kept free of the DOM so the fixture can test it.

import type { AgentTask, Settings } from "./state";

export type TaskAgent = "claude" | "codex" | "kimi-code" | "hermes";
export type TaskTarget = "cli" | "desktop";

export const TASK_AGENTS: { id: TaskAgent; label: string; app: string }[] = [
  { id: "claude", label: "Claude", app: "Claude" },
  { id: "codex", label: "Codex", app: "ChatGPT (Codex)" },
  { id: "kimi-code", label: "Kimi", app: "Kimi Code" },
  { id: "hermes", label: "Hermes", app: "Hermes" },
];

/** Same cap as the Rust side (launch::MAX_PROMPT_CHARS). */
export const MAX_TASK_PROMPT = 8000;

export interface TaskForm {
  agent: TaskAgent;
  target: TaskTarget;
  folder: string;
  prompt: string;
}

export interface TaskOutcome {
  status: "started" | "clipboard";
  message: string;
}

export function lastTarget(settings: Settings, agent: TaskAgent): TaskTarget {
  return settings.lastTaskTargets?.[agent] === "desktop" ? "desktop" : "cli";
}

/** Same key as Rust settings::task_profile_key. */
export function taskProfileKey(agent: TaskAgent, target: TaskTarget): string {
  return `${agent}/${target}`;
}

/** This agent and target's saved folder, else the last folder used anywhere, else "". */
export function savedFolder(settings: Settings, agent: TaskAgent, target: TaskTarget): string {
  const own = settings.taskProfiles?.[taskProfileKey(agent, target)]?.folder?.trim();
  return own || settings.lastTaskFolder?.trim() || "";
}

export function defaultTaskForm(settings: Settings, agent: TaskAgent = "claude"): TaskForm {
  const target = lastTarget(settings, agent);
  return { agent, target, folder: savedFolder(settings, agent, target), prompt: "" };
}

/** Switching agent brings back the target last used with it, and that pair's folder. */
export function selectAgent(form: TaskForm, settings: Settings, agent: TaskAgent): TaskForm {
  const target = lastTarget(settings, agent);
  return { ...form, agent, target, folder: savedFolder(settings, agent, target) };
}

/** Switching CLI/Desktop brings back that pair's folder. */
export function selectTarget(form: TaskForm, settings: Settings, target: TaskTarget): TaskForm {
  return { ...form, target, folder: savedFolder(settings, form.agent, target) };
}

/** Mirrors what Rust saves after a launch (Settings::remember_task). */
export function rememberTask(settings: Settings, agent: TaskAgent, target: TaskTarget, folder: string): Settings {
  return {
    ...settings,
    lastTaskFolder: folder,
    lastTaskTargets: { ...settings.lastTaskTargets, [agent]: target },
    taskProfiles: { ...settings.taskProfiles, [taskProfileKey(agent, target)]: { folder } },
  };
}

/** A reason Go is unavailable, or null when the form can be sent. */
export function taskFormProblem(form: TaskForm): string | null {
  if (!form.folder.trim()) return "Choose a folder.";
  if (!form.prompt.trim()) return "Write a prompt.";
  if (form.prompt.includes("\0")) return "The prompt contains a NUL character.";
  if ([...form.prompt.trim()].length > MAX_TASK_PROMPT) return `Keep the prompt under ${MAX_TASK_PROMPT} characters.`;
  return null;
}

/** The short line shown under the form after Go. */
export function outcomeNote(outcome: TaskOutcome | null, error: string | null): { kind: "ok" | "paste" | "error"; text: string } | null {
  if (error) return { kind: "error", text: error };
  if (!outcome) return null;
  return outcome.status === "started" ? { kind: "ok", text: outcome.message || "Started." } : { kind: "paste", text: outcome.message };
}

// ── Chat task tool ────────────────────────────────────────────────────────────

/** One action the chat ran (Rust tools::ChatAction). */
export interface ChatAction {
  kind: "started" | "clipboard" | "robot" | "error";
  agent: string;
  target: string;
  /** Folder name only, not the full path. */
  folder: string;
  message: string;
}

/** What list_sessions may see: no prompts, no tool inputs, no paths. */
export interface SessionSnapshot {
  agent: string;
  project: string;
  status: string;
}

export function sessionSnapshot(tasks: AgentTask[], waitingTaskId: string | null = null): SessionSnapshot[] {
  return tasks
    .filter((t) => t.sessionId)
    .slice(0, 20)
    .map((t) => ({
      agent: t.agent ?? "claude",
      project: t.name,
      status: t.id === waitingTaskId ? "waiting for approval" : t.questions?.length ? "asking a question" : t.state,
    }));
}

function agentLabel(id: string): string {
  return TASK_AGENTS.find((a) => a.id === id)?.app.replace("ChatGPT (Codex)", "Codex") ?? "agent";
}

/** The system line in the chat log for one action, built from the structured result. */
export function actionLine(a: ChatAction): { kind: "ok" | "paste" | "error"; text: string } {
  const where = a.folder ? ` in ${a.folder}` : "";
  const target = a.target === "desktop" ? "Desktop" : "CLI";
  if (a.kind === "started") return { kind: "ok", text: `▶ Started ${agentLabel(a.agent)} (${target})${where}` };
  if (a.kind === "clipboard") return { kind: "paste", text: `⚠ ${a.message}` };
  if (a.kind === "robot") return { kind: "ok", text: "▶ Robot started in the hidden browser" };
  if (a.agent === "robot") return { kind: "error", text: `✕ Robot not started: ${a.message}` };
  const who = a.agent ? `${agentLabel(a.agent)} not started` : "Task not started";
  return { kind: "error", text: `✕ ${who}: ${a.message}` };
}
