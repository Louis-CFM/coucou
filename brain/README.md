# Coucou Brain

Transforme les sessions Claude Code et les repos git locaux en pages Markdown reliées entre elles — un second cerveau pour le développement.

## Ce que ça fait

1. **Collecte** les sessions Claude Code (`~/.claude/projects/`) et les repos git locaux
2. **Masque** les secrets avant tout envoi au modèle (clés API, tokens, JWT…)
3. **Digère** chaque session via `claude -p` pour en extraire résumé, décisions, faits, erreurs, tâches
4. **Écrit** des pages Markdown dans `~/CoucouBrain/` avec frontmatter YAML et liens internes `[[id]]`
5. **Fusionne** chaque nouvelle fiche dans la page projet correspondante (second appel LLM)
6. **Commite** automatiquement dans le git local de `~/CoucouBrain/`

Les données restent en local — aucun remote, aucune télémétrie.

## Structure de ~/CoucouBrain/

```
~/CoucouBrain/
  records/        ← une fiche par session (AAAA-MM-JJ_projet_hash.md)
  projects/       ← une page par projet, mise à jour par fusion
  lessons.md      ← leçons transverses (tous projets)
  INDEX.md        ← index court, première chose que Claude lira
  .gitignore      ← exclut .state/
  .state/         ← manifest SQLite + répertoire de digestion (non suivi par git)
    manifest.db
    digestion/    ← répertoire de travail pour claude -p
```

## Installation

```bash
cd brain
npm install
npm run build
npm link   # rend `brain` disponible en ligne de commande
```

## Usage

```bash
# Voir ce qui serait traité (aucun appel LLM)
brain ingest --dry-run

# 3 sessions de test
brain ingest --limit 3

# Seulement le projet coucou
brain ingest --project coucou

# Seulement depuis une date
brain ingest --since 2026-10-01

# Avec sous-agents (off par défaut)
brain ingest --include-subagents

# Stats (JSON)
brain stats --pretty
```

## Configuration

`brain.config.json` (commité, valeurs par défaut publiques) :

```json
{
  "brainPath": "~/CoucouBrain",
  "claudeProjectsPath": "~/.claude/projects",
  "repoPaths": ["~/Developer"],
  "additionalRepoPaths": ["~/Documents/Projets"],
  "chunkModel": "sonnet",
  "mergeModel": "opus",
  "maxChunkTokens": 100000,
  "language": "fr",
  "repoAliases": { "notch-buddy": "coucou" }
}
```

`brain.config.local.json` (gitignored, overrides personnels) :

```json
{
  "mergeModel": "sonnet"
}
```

## Incrémental

Le manifeste SQLite (`~/CoucouBrain/.state/manifest.db`) suit toutes les sessions et repos traités. Une relance ne retraite que :
- les sessions nouvelles (pas encore dans le manifeste)
- les sessions modifiées (hash différent)
- les sessions en échec (status `failed`)

## PIÈGE : auto-ingestion

Les appels à `claude -p` créent eux-mêmes des sessions dans `~/.claude/projects/`. Ils tournent depuis `~/CoucouBrain/.state/digestion/`, dont le chemin Claude correspond à un dossier exclu de l'ingestion.

## Provenance des décisions

Chaque décision est marquée :
- `[décidé]` = Louis l'a confirmé explicitement
- `[proposé]` = Claude l'a suggéré (non validé)
- `[constaté]` = fait observé

Les anciennes décisions remplacées ne sont jamais supprimées : elles passent en ❌ avec la date, la raison et un lien vers la nouvelle.
