# Coucou Brain

Transforme les sessions Claude Code et les repos git locaux en un second cerveau structuré — pages Markdown reliées entre elles, éléments extraits par type (décisions, faits, leçons, tâches, préférences, mesures), couverture vérifiable.

## Ce que ça fait

1. **Collecte** les sessions Claude Code (`~/.claude/projects/`) et les repos git locaux
2. **Masque** les secrets avant tout envoi au modèle (clés API, tokens, JWT, IBAN, numéros de carte…)
3. **Digère** chaque session via `claude -p` pour en extraire un `SessionDigest` : titre, résumé, éléments typés (kind : décision / fait / leçon / tâche / préférence / mesure), tâches, fichiers touchés, personnes, état du projet
4. **Sessions longues** : découpées en morceaux (~100k tokens chacun), chaque morceau digéré séparément puis fusionné avec déduplication
5. **Maintient un état par projet** dans `~/CoucouBrain/.state/proj/` — chaque élément a un ID stable, les nouveaux ingests ajoutent sans écraser
6. **Reconstruit** les pages Markdown depuis l'état (sans LLM) : `rebuild`
7. **Commite** automatiquement dans le git local de `~/CoucouBrain/`

Les données restent en local — aucun remote, aucune télémétrie.

## Structure de ~/CoucouBrain/

```
~/CoucouBrain/
  records/        ← une fiche par session (AAAA-MM-JJ_projet_hash.md)
  projects/       ← une page par projet, reconstruite depuis l'état
  people/         ← une page par personne mentionnée
  lessons.md      ← leçons transverses (tous projets)
  INDEX.md        ← index court, première chose que Claude lira
  .gitignore      ← exclut .state/
  .state/         ← manifest SQLite + états par projet (non suivi par git)
    manifest.db          ← sessions et repos traités (hash, status, prompt_hash)
    proj/                ← JSON par page (éléments, project_states, files_touched)
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

# Re-digérer malgré le cache (prompt changé)
brain ingest --force

# Reconstruire les pages sans LLM
brain rebuild

# Stats (JSON)
brain stats --pretty

# Vérifier la couverture des éléments attendus
brain coverage

# Ajouter une correction manuelle (jamais écrasée par l'ingestion)
brain correct "texte de la correction"

# Remettre tout en pending pour re-ingestion complète
brain reset
```

## Configuration

`brain.config.json` (commité, valeurs par défaut publiques) :

```json
{
  "brainPath": "~/CoucouBrain",
  "claudeProjectsPath": "~/.claude/projects",
  "repoPaths": ["~/Developer"],
  "additionalRepoPaths": ["~/Documents/Projets"],
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

## Cache et re-ingestion

Le manifeste SQLite (`~/CoucouBrain/.state/manifest.db`) suit chaque session avec son `prompt_hash` — le SHA-256 du template de prompt au moment de la digestion. Une relance ne retraite que :
- les sessions nouvelles (pas encore dans le manifeste)
- les sessions modifiées (hash du fichier différent)
- les sessions en échec (status `failed`)
- les sessions dont le `prompt_hash` ne correspond plus au prompt actuel (si `--force`)

## PIÈGE : auto-ingestion

Les appels à `claude -p` créent eux-mêmes des sessions dans `~/.claude/projects/`. Ils tournent depuis `~/CoucouBrain/.state/digestion/`, dont le chemin Claude correspond à un dossier exclu de l'ingestion.

## Éléments et provenance

Chaque élément extrait a un `kind`, une `provenance` et un `statut` :

| kind | description |
|------|-------------|
| `décision` | Choix architectural, de workflow ou de style |
| `fait` | État actuel d'un projet (déploiement, format, config) |
| `leçon` | Erreur ou apprentissage réutilisable |
| `tâche` | Action demandée ou accomplie dans la session |
| `préférence` | Règle personnelle de Louis (workflow, style, communication) |
| `mesure` | Métrique nommée (MRR, abonnés…) |

Provenance : `décidé` (Louis a confirmé) · `proposé` (non validé) · `constaté` (fait observé, implémenté)

Statut : `✅` (en vigueur/faite) · `❌` (abandonné, raison obligatoire) · `⏳` (en attente) · `⚠️` (piège) · `null`

## Tests et couverture

```bash
npm test            # tests unitaires (vitest)
brain coverage      # compare les pages aux entrées du golden set
```

Le golden set (`tests/golden-set.json`) liste les éléments critiques attendus après ingestion, avec une priorité `must` (bloquant) ou `should` (objectif).
