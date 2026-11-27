#!/usr/bin/env node
/**
 * brain-prompt.js — Claude Code UserPromptSubmit hook
 *
 * Performs FTS5 search on the user's message and injects up to 5 relevant
 * elements (~1000 tokens) as additionalContext.
 *
 * Constraints:
 *   - Total elapsed time < 300 ms (guarded by hard timeout)
 *   - Never injects mesures (financial data)
 *   - Never re-injects an element already seen in this session
 *   - Cross-project elements only if score is strong enough
 *   - Only injects if ≥ 2 significant query tokens match
 *
 * Guards:
 *   COUCOU_BRAIN_INTERNAL=1 → silent exit
 *   BRAIN_OFF=1 → silent exit
 *   pause flag → silent exit
 */
'use strict';

if (process.env.COUCOU_BRAIN_INTERNAL || process.env.BRAIN_OFF) {
  process.exit(0);
}

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');

// ── Hard timeout: never block a session for > 280 ms ─────────────────────────
const HARD_TIMEOUT = 280;
const deadline = setTimeout(() => {
  log('WARN', 'timeout — no injection');
  process.stdout.write('');
  process.exit(0);
}, HARD_TIMEOUT);
deadline.unref();

// ── Config ────────────────────────────────────────────────────────────────────
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
  return p;
}

function toSlug(name) {
  return String(name).toLowerCase()
    .normalize('NFD').replace(/[\u0300-\u036f]/g, '')
    .replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '');
}

// ── Logging ───────────────────────────────────────────────────────────────────
let brainBase = null;

function log(level, message, extra) {
  if (!brainBase) return;
  try {
    const logsDir = path.join(brainBase, '.state', 'logs');
    fs.mkdirSync(logsDir, { recursive: true });
    const line = `${new Date().toISOString().slice(0, 19)}Z [prompt] ${level} ${message}${extra ? ' | ' + JSON.stringify(extra) : ''}`;
    fs.appendFileSync(path.join(logsDir, 'hooks.log'), line + '\n', 'utf8');
  } catch {}
}

// ── Stopwords ─────────────────────────────────────────────────────────────────
const STOPWORDS = new Set([
  // FR — mots-outils et mots-questions
  'avec','dans','pour','plus','sous','tout','tous','bien','même','mais','donc',
  'alors','ainsi','aussi','comme','quand','dont','cette','quel','quelle','quels',
  'quelles','être','avoir','faire','votre','notre','leurs','leur','cette','ceci',
  'cela','voici','voilà','depuis','vers','sans','entre','après','avant','selon',
  'étant','ayant','fait','faits','nouveau','nouvelle','nouvelles','nouveaux','premier','première',
  // FR question words — common but semantically empty for brain search
  'comment','pourquoi','combien','quand','lequel','laquelle','lesquels',
  'toujours','jamais','souvent','maintenant','encore','peut','doit',
  'faut','faire','refaire','mettre','prendre','donner','passer',
  // EN
  'with','from','that','this','have','will','about','been','which','when','what',
  'your','their','there','these','those','them','then','than','just','also','into',
  'some','make','need','each','here','after','before','between','without','should',
  'would','could','must','back','both','however','because','other','another',
]);

// ── FTS query builder ─────────────────────────────────────────────────────────
function buildFtsQuery(text) {
  const words = text
    .toLowerCase()
    .replace(/[^\p{L}\p{N}\s]/gu, ' ')
    .split(/\s+/)
    .filter(w => w.length >= 4 && !STOPWORDS.has(w))
    .map(w => {
      const clean = w.replace(/["()+\-:*^~{}]/g, '');
      return clean.length >= 4 ? clean + '*' : null;
    })
    .filter(Boolean);

  if (words.length < 2) return null;
  const unique = [...new Set(words)].slice(0, 8);
  return unique.join(' ');
}

// ── Session seen-IDs tracking ─────────────────────────────────────────────────
function getSeenPath(sessionId) {
  if (!brainBase || !sessionId || sessionId === 'unknown') return null;
  return path.join(brainBase, '.state', 'sessions', `${sessionId}.json`);
}

function loadSeen(sessionId) {
  const p = getSeenPath(sessionId);
  if (!p || !fs.existsSync(p)) return new Set();
  try {
    return new Set(JSON.parse(fs.readFileSync(p, 'utf8')));
  } catch { return new Set(); }
}

function saveSeen(sessionId, ids) {
  const p = getSeenPath(sessionId);
  if (!p) return;
  try {
    fs.mkdirSync(path.dirname(p), { recursive: true });
    fs.writeFileSync(p, JSON.stringify([...ids]), 'utf8');
  } catch {}
}

function cleanupOldSeenFiles() {
  if (!brainBase) return;
  const sessionsDir = path.join(brainBase, '.state', 'sessions');
  if (!fs.existsSync(sessionsDir)) return;
  try {
    const cutoff = Date.now() - 86400000; // 24h
    for (const f of fs.readdirSync(sessionsDir)) {
      const fp = path.join(sessionsDir, f);
      try {
        if (fs.statSync(fp).mtimeMs < cutoff) fs.unlinkSync(fp);
      } catch {}
    }
  } catch {}
}

// ── Project detection from CWD ────────────────────────────────────────────────
function detectProjectSlug(cwd, stateDir) {
  let repoName = path.basename(cwd);
  let remoteUrl = null;
  try {
    const r = spawnSync('git', ['-C', cwd, 'remote', 'get-url', 'origin'], {
      encoding: 'utf8', timeout: 500,
    });
    if (r.status === 0) {
      remoteUrl = r.stdout.trim();
      repoName = remoteUrl.replace(/\.git$/, '').split(/[\/:]/).pop() || repoName;
    }
  } catch {}

  const slugFromName = toSlug(repoName);
  const slugFromCwd = toSlug(path.basename(cwd));

  if (!fs.existsSync(stateDir)) return slugFromCwd;

  for (const f of fs.readdirSync(stateDir)) {
    if (!f.endsWith('.json') || f === 'lessons.json' || f === 'louis.json') continue;
    try {
      const st = JSON.parse(fs.readFileSync(path.join(stateDir, f), 'utf8'));
      if (remoteUrl && st.remote && st.remote === remoteUrl) {
        return st.id.replace(/^proj_/, '');
      }
      if (st.id === `proj_${slugFromName}` || st.id === `proj_${slugFromCwd}`) {
        return st.id.replace(/^proj_/, '');
      }
    } catch {}
  }

  return slugFromName;
}

// ── Render result ─────────────────────────────────────────────────────────────
function renderResult(r) {
  if (r.isCorrection) {
    const scope = r.sourceProject.replace('corrections:', '');
    return `[CORRECTION:${scope}]\n${r.texte}`;
  }
  const warn = (r.statut === '❌' || r.statut === '⚠️') ? ` ${r.statut}` : '';
  const notRedo = r.statut === '❌' ? ' ← NE PAS REFAIRE' : '';
  const proj = r.sourceProject.replace(/^proj_/, '');
  return `[${r.kind}${warn}][${proj}]${notRedo}\n${r.texte}`;
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
  let data = {};
  try { data = JSON.parse(rawInput); } catch {}

  const prompt = data.prompt || '';
  const sessionId = data.session_id || 'unknown';
  const cwd = data.cwd || process.env.PWD || process.cwd();

  if (!prompt || prompt.length < 8) { process.exit(0); }

  let config;
  try { config = loadBrainConfig(); } catch { process.exit(0); }

  brainBase = expandHome(config.brainPath);

  // Check pause flag
  if (fs.existsSync(path.join(brainBase, '.state', 'paused'))) {
    process.exit(0);
  }

  // Build FTS query — exit early if not enough significant tokens
  const ftsQuery = buildFtsQuery(prompt);
  if (!ftsQuery) {
    log('INFO', 'no sig tokens', { prompt: prompt.slice(0, 50) });
    process.exit(0);
  }

  // Load FTS DB
  const ftsDbPath = path.join(brainBase, '.state', 'fts.db');
  if (!fs.existsSync(ftsDbPath)) { process.exit(0); }

  let Database;
  try {
    Database = require('better-sqlite3');
  } catch { process.exit(0); }

  let db;
  try {
    db = new Database(ftsDbPath, { readonly: true });
  } catch { process.exit(0); }

  // Detect project
  const stateDir = path.join(brainBase, '.state', 'proj');
  const projectSlug = detectProjectSlug(cwd, stateDir);
  const projectId = `proj_${projectSlug}`;

  // Load seen IDs for this session
  const seen = loadSeen(sessionId);
  cleanupOldSeenFiles();

  try {
    const sql = `
      SELECT elem_id, kind, statut, provenance, domaine, scope,
             projets_text, date_str, source_project, is_correction, texte,
             bm25(fts_elements) as score
      FROM fts_elements
      WHERE fts_elements MATCH ?
        AND bm25(fts_elements) < -0.5
        AND kind != 'mesure'
      ORDER BY
        is_correction DESC,
        CASE WHEN source_project = ? OR projets_text LIKE ? THEN 0 ELSE 1 END ASC,
        CASE WHEN scope = 'transverse' THEN 0 ELSE 1 END ASC,
        bm25(fts_elements) ASC
      LIMIT 20
    `;

    const projectLike = `%${projectSlug}%`;
    const rows = db.prepare(sql).all(ftsQuery, projectId, projectLike);
    db.close();

    // Filter: cross-project only if strong match, exclude seen
    const results = [];
    for (const row of rows) {
      if (seen.has(row.elem_id)) continue;
      const isCurrentProject =
        row.source_project === projectId ||
        row.projets_text.includes(projectSlug);
      const isGlobal =
        row.scope === 'transverse' ||
        row.source_project.startsWith('corrections:global');
      const isProjectCorr = row.is_correction &&
        row.source_project === `corrections:${projectSlug}`;

      if (!isCurrentProject && !isGlobal && !isProjectCorr && row.score > -6.0) continue;

      results.push(row);
      if (results.length >= 5) break;
    }

    if (results.length === 0) {
      log('INFO', 'no results above threshold', { query: ftsQuery, project: projectSlug });
      process.exit(0);
    }

    // Format injection (max ~1000 tokens = ~4000 chars)
    const lines = results.map(r => renderResult({
      id: r.elem_id,
      kind: r.kind,
      texte: r.texte,
      statut: r.statut || null,
      sourceProject: r.source_project,
      scope: r.scope,
      isCorrection: r.is_correction === 1,
    }));

    const context = `Mémoire CoucouBrain [${projectSlug}] :\n\n` + lines.join('\n\n');

    // Clamp to ~4000 chars (~1000 tokens)
    const clamped = context.length > 4000 ? context.slice(0, 3990) + '\n…' : context;

    // Save seen IDs
    const injectedIds = results.map(r => r.elem_id);
    for (const id of injectedIds) seen.add(id);
    saveSeen(sessionId, seen);

    const duration = Date.now() - startTime;
    log('INFO', 'injected', {
      project: projectSlug,
      session: sessionId,
      ids: injectedIds,
      tokens: Math.round(clamped.length / 4),
      ms: duration,
      query: ftsQuery,
    });

    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: 'UserPromptSubmit',
        additionalContext: clamped,
      },
    }));

  } catch (e) {
    try { db?.close(); } catch {}
    log('ERROR', e.message, { query: ftsQuery });
    process.exit(0);
  }
}
