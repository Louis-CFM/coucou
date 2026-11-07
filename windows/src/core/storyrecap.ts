// @ts-nocheck — kept as its authors wrote it, in plain JavaScript, so it can be
// compared with and updated from the original.
//
// From dotpals (dotpals contributors), MIT (https://github.com/Rikinshah787/dotpals),
// bridge/ui/recap.js at 6f3cf5d. The notice is in windows/THIRD_PARTY_NOTICES.md.
//
// Turning activity entries into something a person can read: requests
// ("turns"), plain-language steps, tallies and Markdown recaps. Shared by the
// pal (bridge/index.html) and the dashboard (bridge/dashboard.html).

// Agents with a color of their own (--h-claude, --h-codex); every other agent is "other".
export const HARNESS = { claude: 'Claude', codex: 'Codex' };
const NAMES = { ...HARNESS, cursor: 'Cursor', gemini: 'Gemini CLI', opencode: 'OpenCode', copilot: 'Copilot CLI' };
export const harnessName = (h) => NAMES[h] ?? (h ? h[0].toUpperCase() + h.slice(1) : 'Agent');
export const harnessClass = (h) => (HARNESS[h] ? `h-${h}` : 'h-other');

export const plural = (n, one, many = `${one}s`) => `${n} ${n === 1 ? one : many}`;
export const baseName = (p) => String(p).split(/[\\/]/).pop();
export const fileUrl = (path) => `vscode://file/${encodeURI(String(path).replace(/\\/g, '/'))}`;
export const secs = (ms) => (ms < 1000 ? `${ms}ms` : ms < 60000 ? `${(ms / 1000).toFixed(1)}s` : `${Math.floor(ms / 60000)}m ${Math.round((ms % 60000) / 1000)}s`);
export const hours = (ms) => (ms >= 3600000 ? `${Math.floor(ms / 3600000)}h ${Math.round((ms % 3600000) / 60000)}m` : ms >= 60000 ? `${Math.round(ms / 60000)}m` : secs(ms));
export const shortTime = (at) => new Date(at).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
export const startOfDay = (at = Date.now()) => { const d = new Date(at); d.setHours(0, 0, 0, 0); return d.getTime(); };

/** One step, as a short sentence ("Editing app.js" while it runs, "Edited app.js" after). */
export function sentence(e) {
  const t = e.title || e.tool || '';
  if (e.status === 'running' || e.status === 'waiting') {
    const doing = { read: 'Reading', edit: 'Editing', write: 'Writing', run: 'Running', search: 'Searching for', web: 'Looking up', agent: 'Asking a helper agent:', mcp: 'Using', skill: 'Using the skill' }[e.kind] ?? 'Using';
    return `${doing} ${e.kind === 'run' || e.kind === 'search' || e.kind === 'web' ? `“${t}”` : t}`;
  }
  switch (e.kind) {
    case 'read': return `Read ${t}`;
    case 'edit': return `Edited ${t}`;
    case 'write': return `Wrote ${t}`;
    case 'run': return `Ran “${t}”`;
    case 'search': return `Searched the code for “${t}”`;
    case 'web': return `Looked up “${t}”`;
    case 'agent': return `Asked a helper agent: ${t}`;
    case 'mcp': return `Used ${e.detail ? `${e.detail}: ` : ''}${t}`;
    case 'skill': return `Used the ${t} skill`;
    case 'plan': return 'Updated its to-do list';
    case 'compact': return 'Tidied up its memory of the conversation';
    default: return `Used ${t}`;
  }
}

/** Agent replies are Markdown; show them as plain text (a code block keeps its contents, without the fences). */
export const plain = (md) => String(md ?? '')
  .replace(/```[^\n]*\n?([\s\S]*?)\n?```/g, '$1')
  .replace(/`([^`\n]+)`/g, '$1')
  .replace(/\*\*([^*\n]+)\*\*|__([^_\n]+)__/g, '$1$2')
  .replace(/\[([^\]\n]+)\]\([^)\n]+\)/g, '$1')
  .replace(/^#{1,6}\s*/gm, '')
  .replace(/^\s*[-*]\s+/gm, '• ')
  .replace(/\n{3,}/g, '\n\n')
  .trim();

/**
 * Group entries (any order) into turns: a prompt, the steps after it, and how
 * it ended. Entries with no prompt before them start a turn of their own.
 */
export function buildTurns(entries) {
  const list = [...entries].sort((a, b) => a.at - b.at);
  const turns = [];
  const current = new Map();
  for (const e of list) {
    let t = current.get(e.session);
    if (e.kind === 'prompt' || !t) {
      t = { id: e.id, session: e.session, harness: e.harness, label: e.label, at: e.at, prompt: e.kind === 'prompt' ? e : null, steps: [], end: null, usage: null };
      turns.push(t);
      current.set(e.session, t);
    }
    // Tokens, from every entry of the request (a second "done" can take the first one's place as its end).
    if (e.usage) t.usage = { ...t.usage, ...e.usage };
    if (e.kind === 'prompt') continue;
    if (e.kind === 'done' || e.kind === 'error') {
      if (!t.end || e.summary || !t.end.summary) t.end = e;
      continue;
    }
    if (t.end && e.at > t.end.at) t.end = null; // it kept going
    t.steps.push(e);
  }
  return turns;
}

/**
 * The tokens a request (or several) used, from its replies' usage:
 * { input, output, cacheRead, cacheWrite, replies }, or null when the agent's logs don't say
 * (Claude Code and Codex do; hook-only agents don't). `usages`: turns' `usage` maps.
 */
export function tokens(...usages) {
  const k = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, replies: 0 };
  for (const u of usages) {
    for (const [input = 0, output = 0, cacheRead = 0, cacheWrite = 0] of Object.values(u ?? {})) {
      k.input += input; k.output += output; k.cacheRead += cacheRead; k.cacheWrite += cacheWrite; k.replies++;
    }
  }
  return k.replies ? k : null;
}

export const short = (n) => (n >= 1e6 ? `${+(n / 1e6).toFixed(1)}M` : n >= 1e4 ? `${Math.round(n / 1e3)}k` : n >= 1e3 ? `${+(n / 1e3).toFixed(1)}k` : String(n));

/**
 * "52k tokens in · 3.1k out · 1.2M cached", or ''. In: what the model read new (cache writes
 * are new input too); cached: what it read again from the cache, which costs much less.
 */
export function tokenLine(k) {
  if (!k) return '';
  const parts = [`${short(k.input + k.cacheWrite)} tokens in`, `${short(k.output)} out`];
  if (k.cacheRead) parts.push(`${short(k.cacheRead)} cached`);
  return parts.join(' · ');
}

/** How long a finished turn took. */
export const turnTime = (t) => (t.end ? t.end.ms ?? (t.prompt ? Math.max(0, t.end.at - t.at) : 0) : 0);

/** The work in a set of steps: which files changed, what ran, what was used. */
export function facts(steps) {
  const rank = { read: 0, edit: 1, write: 2, delete: 3 };
  const files = new Map(); // path → strongest change
  const f = { runs: 0, runFailed: 0, searches: 0, web: 0, agents: 0, failed: 0, mcp: new Set(), skills: new Set() };
  for (const s of steps) {
    if (s.status === 'failed') f.failed++;
    else for (const file of s.files ?? []) {
      const key = String(file.path).toLowerCase();
      if (!files.has(key) || rank[file.change] > rank[files.get(key).change]) files.set(key, file);
    }
    if (s.kind === 'run') { f.runs++; if (s.status === 'failed') f.runFailed++; }
    if (s.kind === 'search') f.searches++;
    if (s.kind === 'web') f.web++;
    if (s.kind === 'agent') f.agents++;
    if (s.kind === 'mcp') f.mcp.add(s.detail || s.title);
    if (s.kind === 'skill') f.skills.add(s.title);
  }
  const by = (change) => [...files.values()].filter((x) => x.change === change);
  Object.assign(f, { changed: by('edit'), wrote: by('write'), deleted: by('delete'), read: by('read') });
  f.otherFailed = f.failed - f.runFailed;
  f.touched = f.changed.length + f.wrote.length + f.deleted.length;
  return f;
}

// The Markdown recap (turnMarkdown, recapMarkdown) lives in story.js: it needs the story's rules.

/** Sessions (one per agent conversation) with their totals, newest first. */
export function summarizeSessions(entries) {
  const bySession = new Map();
  for (const e of entries) {
    const s = bySession.get(e.session) ?? { id: e.session, harness: e.harness, label: e.label, first: e.at, last: e.at, entries: [] };
    s.harness ??= e.harness;
    s.label ??= e.label;
    s.first = Math.min(s.first, e.at);
    s.last = Math.max(s.last, e.at);
    s.entries.push(e);
    bySession.set(e.session, s);
  }
  return [...bySession.values()].map((s) => {
    const turns = buildTurns(s.entries);
    const f = facts(s.entries);
    return { ...s, turns, facts: f, requests: turns.filter((t) => t.prompt).length, time: turns.reduce((sum, t) => sum + turnTime(t), 0) };
  }).sort((a, b) => b.last - a.last);
}
