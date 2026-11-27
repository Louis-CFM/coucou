# Brain — Handoff

## What it does

`brain ingest` reads every Claude Code session in `~/.claude/projects/` and every git repo under `repoPaths`, sends each one to `claude -p` (no tools, model: opus), and writes structured Markdown into `~/CoucouBrain/`.

Each session becomes one **record** (`records/YYYY-MM-DD_project_hash.md`) and its elements are merged into the matching **project page** (`projects/myproject.md`). Cross-project lessons go into `lessons.md`. Preferences go into `owner.md`. People get individual pages under `people/`.

## State model

State lives in `~/CoucouBrain/.state/` (gitignored):
- `manifest.db` — SQLite. Tracks every session and repo: content hash, processing status, `prompt_hash` (SHA-256 of the digest prompt template at ingest time).
- `proj/*.json` — one JSON per page, holding the full element list. Pages are rebuilt from these without LLM calls (`brain rebuild`).

A re-run only touches sessions that are new, changed, failed, or whose `prompt_hash` doesn't match the current prompt. Use `--force` to override.

## Extraction schema

Each session produces a `SessionDigest` with typed `elements`:

| kind | description |
|------|-------------|
| `décision` | Architectural or workflow choice |
| `fait` | Stable project state (deploy method, file format, auth config) |
| `leçon` | Error or reusable lesson (`scope: transverse` = cross-project) |
| `tâche` | Task done or abandoned in the session |
| `préférence` | Personal workflow/style rule, `projets: []` if global |
| `mesure` | Named metric (MRR, subscriber count…) — deduplicated by `nom` on merge |

Each element has: `kind`, `sub_kind`, `provenance` (décidé/proposé/constaté), `statut` (✅/❌/⏳/⚠️), `texte`, `nom`, `projets`, `remplace`, `raison`, `domaine`, `scope`.

## Long sessions

Sessions > ~100k tokens are split into chunks. Each chunk is digested independently (full extraction, not summary), then `mergeChunkDigests` deduplicates by `kind + texte[:60]`, with mesures deduped by `nom` (last wins).

## Secret masking

`mask.ts` strips API keys, tokens, JWTs, IBANs, card numbers, .env secrets, and URLs with embedded credentials before any LLM call. Masked items are reported in the ingest output.

## Coverage

`brain coverage` compares the state files against `~/CoucouBrain/.state/golden-set.json` (private, not in repo). The repo ships `tests/golden-set.example.json` as a template. Priority `must` = always required; `should` = LLM variability acceptable.

## Key files

| File | Role |
|------|------|
| `src/digest.ts` | Prompt template + schema + chunk merge logic |
| `src/collect.ts` | JSONL parsing, secret masking, session condensation |
| `src/write.ts` | All Markdown rendering and state persistence |
| `src/elements.ts` | Element types, merge/dedup logic |
| `src/coverage.ts` | Coverage check against golden set |
| `src/manifest.ts` | SQLite manifest (sessions + repos) |
| `brain.config.json` | Public defaults; override with `brain.config.local.json` |

## Running

```bash
cd brain && npm install && npm run build && npm link
brain ingest --dry-run   # preview
brain ingest             # run
brain coverage           # check
brain rebuild            # re-render pages without LLM
```
