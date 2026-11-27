# Brain — Backlog

## High priority

- **Golden set: 2 missing should entries** — `charges récurrentes` and `transactions élargi` are unrecovered. `charges récurrentes` appears as "Dépenses récurrentes" in the LLM output despite the prompt rule. `transactions élargi` is absent from all JSONL sources.

- **5 failed repos** — `Lyra`, `demo-clips`, `my-site`, `LandingPro-App`, `fade-anim` (all in `~/Projects`) are stuck at `failed` status. Investigate why each fails and either fix or mark as ignored.

- **owner.md owner name** — `owner.md` and `updateOwner()` in `write.ts` are hardcoded to "owner". Should be derived from config (new `ownerName` field) to make the tool usable by other users.

## Medium priority

- **Config: `additionalRepoPaths`** — currently `~/Projects` is in `brain.config.json` as a public default. Should move to `brain.config.local.json` (gitignored) since it's personal.

- **Coverage: needle matching** — currently `texte.includes(needle)` case-insensitive. Should support regex needles for entries that need looser matching (e.g. match "charges récurrentes" OR "dépenses récurrentes").

- **Digest: `taches_faites` / `taches_abandonnees`** — these are extracted by the LLM but currently only used in records. Should be surfaced in the project state as open/closed task counts.

- **Repo digestion: failure details** — `markRepoFailed` stores no reason. Add an optional `error` column so failed repos can be diagnosed without re-running.

- **`brain stats`** — currently outputs raw JSON. Add a `--pretty` flag that prints a readable summary (pages by group, most-linked records, masked secret types).

## Low priority

- **Multi-language owner name** — the prompt is in French and hardcodes "Human:" as the conversation role. Consider making the conversation language configurable (already `language: "fr"` in config but only used for… nothing currently).

- **CI integration** — `brain coverage` exits 1 when any `must` entry fails. Could be wired into a pre-push hook or a CI step that runs after `brain ingest` on a schedule.

- **Element IDs** — currently `${kind_prefix}_${sha256[:10]}` of the texte. If a texte changes, the old ID persists and the new one is added. Consider a stable ID strategy for elements that evolve over time.

- **`brain correct`** — appends to `corrections.md` but doesn't update state files. Consider parsing corrections as structured elements on `brain rebuild`.
