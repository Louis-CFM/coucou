#!/usr/bin/env node
/**
 * brain-session-start.js — Claude Code SessionStart hook
 *
 * Injects up to ~1500 tokens of brain context at session start:
 *   1. Corrections globales + corrections du projet courant (toujours)
 *   2. Préférences globales de Louis
 *   3. État + décisions actives + tâches ouvertes + leçons ⚠️ du projet
 *
 * Guards:
 *   COUCOU_BRAIN_INTERNAL=1 → silent exit (no injection, avoid digest contamination)
 *   BRAIN_OFF=1 → silent exit (manual override)
 *   pause flag → silent exit
 *
 * Never blocks: any error → empty stdout, exit 0.
 */
'use strict';

// ── Guard 1: env flag (best-effort — Claude Code may not forward inherited env) ──
if (process.env.COUCOU_BRAIN_INTERNAL || process.env.BRAIN_OFF) {
  process.exit(0);
}

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');

// ── Config loading ────────────────────────────────────────────────────────────
const HOOKS_DIR = __dirname;
const BRAIN_DIR = path.join(HOOKS_DIR, '..');

function loadBrainConfig() {
  const base = JSON.parse(fs.readFileSync(path.join(BRAIN_DIR, 'brain.config.json'), 'utf8'));
  const localPath = path.join(BRAIN_DIR, 'brain.config.local.json');
  const local = fs.existsSync(localPath) ? JSON.parse(fs.readFileSync(localPath, 'utf8')) : {};
  return { ...base, ...local };
}

function expandHome(p) {
  if (p.startsWith('~/')) return path.join(os.homedir(), p.slice(2));
  if (p === '~') return os.homedir();
  return p;
}

function toSlug(name) {
  return String(name).toLowerCase()
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}

// ── Token estimation (1 token ≈ 4 chars) ─────────────────────────────────────
function tokens(text) { return Math.ceil(text.length / 4); }

const MAX_TOKENS = 1500;

// ── Logging ───────────────────────────────────────────────────────────────────
let brainBase = null;

function log(level, message, extra) {
  if (!brainBase) return;
  // BRAIN_LOG_FILE overrides destination (used by tests to avoid polluting hooks.log)
  const logFile = process.env.BRAIN_LOG_FILE ||
    path.join(brainBase, '.state', 'logs', 'hooks.log');
  if (logFile === '/dev/null') return;
  try {
    fs.mkdirSync(path.dirname(logFile), { recursive: true });
    const line = `${new Date().toISOString().slice(0, 19)}Z [session-start] ${level} ${message}${extra ? ' | ' + JSON.stringify(extra) : ''}`;
    fs.appendFileSync(logFile, line + '\n', 'utf8');
  } catch {}
}

// ── Corrections parser ────────────────────────────────────────────────────────
function parseCorrections(corrPath) {
  if (!fs.existsSync(corrPath)) return [];
  const raw = fs.readFileSync(corrPath, 'utf8');
  // Strip YAML frontmatter
  const content = raw.replace(/^---[\s\S]*?---\s*/, '');
  const sections = [];
  let scope = null, lines = [];

  for (const line of content.split('\n')) {
    const m = line.match(/^##\s+(.+)$/);
    if (m) {
      if (scope !== null && lines.some(l => l.trim())) {
        sections.push({ scope, text: lines.join('\n').trim() });
      }
      scope = m[1].trim().toLowerCase().replace(/\s+/g, '-');
      lines = [];
    } else if (scope !== null) {
      lines.push(line);
    }
  }
  if (scope !== null && lines.some(l => l.trim())) {
    sections.push({ scope, text: lines.join('\n').trim() });
  }
  return sections;
}

// ── Project detection ─────────────────────────────────────────────────────────
function detectProject(cwd, stateDir) {
  // 1. Try git remote
  let repoName = null;
  let remoteUrl = null;
  try {
    const gitRemote = spawnSync('git', ['-C', cwd, 'remote', 'get-url', 'origin'], {
      encoding: 'utf8', timeout: 2000,
    });
    if (gitRemote.status === 0) {
      remoteUrl = gitRemote.stdout.trim();
      repoName = remoteUrl
        .replace(/\.git$/, '')
        .split(/[\/:]/)
        .pop() || null;
    }
  } catch {}

  if (!repoName) {
    repoName = path.basename(cwd);
  }

  const slugFromName = toSlug(repoName);
  const slugFromCwd = toSlug(path.basename(cwd));

  // 2. Scan state files for matching remote or slug
  if (!fs.existsSync(stateDir)) return { slug: slugFromCwd, state: null };

  let matchState = null;
  let matchSlug = slugFromName;

  for (const f of fs.readdirSync(stateDir)) {
    if (!f.endsWith('.json') || f === 'lessons.json' || f === 'louis.json') continue;
    try {
      const st = JSON.parse(fs.readFileSync(path.join(stateDir, f), 'utf8'));
      // Match by remote URL
      if (remoteUrl && st.remote && st.remote === remoteUrl) {
        matchState = st;
        matchSlug = st.id.replace(/^proj_/, '');
        break;
      }
      // Match by slug
      if (st.id === `proj_${slugFromName}` || st.id === `proj_${slugFromCwd}`) {
        if (!matchState) {
          matchState = st;
          matchSlug = st.id.replace(/^proj_/, '');
        }
      }
    } catch {}
  }

  return { slug: matchSlug, state: matchState };
}

// ── Main ──────────────────────────────────────────────────────────────────────
const startTime = Date.now();
let input = '';
process.stdin.on('data', chunk => { input += chunk; });
process.stdin.on('end', () => {
  try {
    run(input);
  } catch (e) {
    log('ERROR', e.message);
    process.exit(0);
  }
});

function run(rawInput) {
  // Parse session input
  let sessionData = {};
  try { sessionData = JSON.parse(rawInput); } catch {}

  const cwd = sessionData.cwd || process.env.PWD || process.cwd();
  const sessionId = sessionData.session_id || 'unknown';

  // Load config
  let config;
  try { config = loadBrainConfig(); } catch { process.exit(0); }

  brainBase = expandHome(config.brainPath);

  // ── Guard 2: cwd is inside brainPath (digestion subprocess, security tests…) ──
  if (cwd && (cwd + path.sep).startsWith(brainBase + path.sep)) {
    process.exit(0);
  }

  // Check pause flag
  const pausedFlag = path.join(brainBase, '.state', 'paused');
  if (fs.existsSync(pausedFlag)) {
    log('INFO', 'paused — no injection', { session: sessionId });
    process.exit(0);
  }

  const stateDir = path.join(brainBase, '.state', 'proj');
  const { slug: projectSlug, state: projectState } = detectProject(cwd, stateDir);

  // ── Guard 3: internal slugs that must never be treated as projects ────────────
  const INTERNAL_SLUGS = /^(digestion|brain-security|state|\.state|tmp|temp)$/;
  if (INTERNAL_SLUGS.test(projectSlug)) {
    process.exit(0);
  }

  const sections = [];
  let totalTokens = 0;

  // ── 1. Corrections (always, highest priority) ─────────────────────────────
  const corrPath = path.join(brainBase, 'corrections.md');
  const corrections = parseCorrections(corrPath);
  const relevantCorrs = corrections.filter(
    sec => sec.scope === 'global' || sec.scope === projectSlug
  );

  if (relevantCorrs.length > 0) {
    const corrLines = relevantCorrs.map(sec =>
      `### Corrections §${sec.scope}\n${sec.text}`
    ).join('\n\n');
    const corrBlock = `## ⚠️ Corrections (priorité max)\n\n${corrLines}`;
    sections.push(corrBlock);
    totalTokens += tokens(corrBlock);
  }

  // ── 2. Global prefs from louis.md ─────────────────────────────────────────
  if (totalTokens < MAX_TOKENS - 200) {
    const louisStatePath = path.join(stateDir, 'louis.json');
    if (fs.existsSync(louisStatePath)) {
      try {
        const louisState = JSON.parse(fs.readFileSync(louisStatePath, 'utf8'));
        const globalPrefs = (louisState.elements || [])
          .filter(e => e.statut !== '❌' && (!e.projets || e.projets.length === 0))
          .slice(0, 10);
        if (globalPrefs.length > 0) {
          const prefsBlock = `## Préférences globales\n${globalPrefs.map(renderElem).join('\n')}`;
          if (totalTokens + tokens(prefsBlock) <= MAX_TOKENS - 100) {
            sections.push(prefsBlock);
            totalTokens += tokens(prefsBlock);
          }
        }
      } catch {}
    }
  }

  // ── 3. Project context ─────────────────────────────────────────────────────
  if (projectState && totalTokens < MAX_TOKENS - 100) {
    const projectParts = [];

    // État actuel (first sentence only to save tokens)
    if (projectState.etatActuel) {
      const brief = projectState.etatActuel.split(/[.\n]/)[0]?.trim() || '';
      if (brief) projectParts.push(`**État** : ${brief}`);
    }

    // Active decisions (non ❌)
    const activeDecs = (projectState.elements || [])
      .filter(e => e.kind === 'décision' && e.statut !== '❌')
      .slice(0, 8);
    if (activeDecs.length > 0) {
      projectParts.push(`### Décisions actives\n${activeDecs.map(renderElem).join('\n')}`);
    }

    // Lessons ⚠️ and ❌ (things NOT to redo)
    const dangerItems = (projectState.elements || [])
      .filter(e =>
        e.statut === '⚠️' || e.statut === '❌' ||
        (e.kind === 'leçon' && e.sub_kind === 'erreur')
      )
      .slice(0, 5);
    if (dangerItems.length > 0) {
      projectParts.push(`### ❌ / ⚠️ — Ne pas refaire\n${dangerItems.map(renderElem).join('\n')}`);
    }

    // Open tasks
    const openTasks = (projectState.elements || [])
      .filter(e => e.kind === 'tâche' && e.statut !== '❌' && e.statut !== '✅')
      .slice(0, 5);
    if (openTasks.length > 0) {
      projectParts.push(`### Tâches ouvertes\n${openTasks.map(renderElem).join('\n')}`);
    }

    if (projectParts.length > 0) {
      const projBlock = `## Projet : ${projectState.title || projectSlug}\n\n${projectParts.join('\n\n')}`;
      if (totalTokens + tokens(projBlock) <= MAX_TOKENS) {
        sections.push(projBlock);
        totalTokens += tokens(projBlock);
      } else {
        // Truncate gracefully
        const available = MAX_TOKENS - totalTokens - 20;
        const truncated = projBlock.slice(0, available * 4);
        sections.push(truncated + '\n…(tronqué)');
      }
    }
  }

  if (sections.length === 0) {
    log('INFO', 'nothing to inject', { project: projectSlug, session: sessionId });
    process.exit(0);
  }

  const header = `# Mémoire CoucouBrain — ${projectSlug}\n\n`;
  const output = header + sections.join('\n\n---\n\n');

  const duration = Date.now() - startTime;
  log('INFO', 'injected', {
    project: projectSlug,
    session: sessionId,
    tokens: tokens(output),
    ms: duration,
  });

  process.stdout.write(output);
}

function renderElem(e) {
  const warn = (e.statut === '❌' || e.statut === '⚠️') ? ` ${e.statut}` : '';
  const stat = e.statut && !warn ? ` ${e.statut}` : '';
  const raison = e.statut === '❌' && e.raison ? ` ← ${e.raison}` : '';
  return `- [${e.kind}${stat}${warn}] ${e.texte}${raison}`;
}
