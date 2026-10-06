# Notch Buddy — intégrations

Règle d'or : **vérifier la doc officielle au moment d'implémenter**. Les formats ci-dessous sont le plan, pas une garantie. Sources à relire :
- Hooks Claude Code : https://code.claude.com/docs/en/hooks
- Hooks Cursor : https://cursor.com/docs/hooks
- API Claude (Messages, outil de recherche web, modèles) : https://docs.claude.com/en/api/overview
- API publique n8n : `{URL de l'instance}/api/v1/docs` (playground de l'instance de Louis)

---

## 1. Claude Code (sessions de Louis)

### Architecture
```
claude (terminal, VS Code, app Claude)
  └─ hook "command" ─► nb-hook (petit exécutable Swift, livré avec l'app)
                         └─ socket Unix ─► Notch Buddy.app
                         ◄─ décision (pour PermissionRequest)
```
- `nb-hook` (script shell) et `nb-hook.py` (relais Python) : écrits par l'app (`HookServer.swift`). Version GitHub : au lancement, dans `~/Library/Application Support/NotchBuddy/`. Version App Store : à l'installation des hooks, dans `~/.claude/coucou/`. Voir `docs/AGENTS.md` pour les autres agents qui utilisent ces scripts.
- Socket : `~/Library/Application Support/NotchBuddy/nb.sock` (version GitHub) ou `~/Library/Containers/fr.louisraille.Coucou/Data/nb.sock` (version App Store). Dossier en 0700, socket en 0600. Connexions du même utilisateur seulement (vérification `getpeereid`). 1 Mio et 5 s maximum par message, 32 connexions simultanées.
- `nb-hook [--agent <nom>] <Event>` lit le JSON du hook sur stdin, ajoute le contexte du terminal (`TERM_PROGRAM`, `ITERM_SESSION_ID`, `TERM_SESSION_ID`, `__CFBundleIdentifier`, le tty trouvé en remontant les processus parents, `cwd`) et, si `--agent` est fourni, le champ `coucou_agent`, puis l'envoie à l'app.
- **Si l'app ne répond pas en 300 ms, `nb-hook` sort en code 0 sans rien écrire** : Claude Code continue normalement. Jamais de blocage.
- Champ optionnel `coucou_agent` : nom en minuscules, chiffres et tirets, 24 caractères au plus. Si absent ou invalide, l'événement va dans la pastille Claude. Voir `docs/AGENTS.md` pour les autres agents.

### Événements à brancher et état du bonhomme
| Hook | Effet dans l'app |
|---|---|
| `SessionStart` | crée la tâche (nom = dossier), état `idle` |
| `UserPromptSubmit` | état `thinking`, ligne du défilé = début du prompt |
| `PreToolUse` | état `working`, ligne = outil + cible (« Edit Invoice.swift », « Bash npm test ») |
| `PostToolUse` / `PostToolUseFailure` | met à jour la ligne ; un échec reste `working` |
| `PermissionRequest` | alerte `approval` (voir plus bas) |
| `Notification` | selon le type : attente d'entrée → `question` si une question est posée, sinon rien ; limite d'usage → `ratelimit` |
| `Stop` | état `finished` → vue `finished` 5,2 s, résumé = dernière phrase utile de la réponse si disponible |
| `StopFailure` (si présent dans la doc) | alerte `error` |
| `SubagentStart` / `SubagentStop` | afficher « + sous-agent » dans le défilé |
| `SessionEnd` | retire la tâche |

Vérifier dans la doc la liste exacte des événements et leurs champs.

### Approuver depuis le notch
- Sur `PermissionRequest`, `nb-hook` **attend** la décision de l'app (défaut 110 s, réglable) puis écrit sur stdout le JSON de décision du hook (d'après la doc actuelle : `hookSpecificOutput` avec `decision.behavior` = `allow` ou `deny`). Timeout du hook dans settings.json : décision + 10 s.
- Pas de réponse avant le délai, ou app fermée → aucune sortie, le terminal affiche sa demande habituelle. Si Louis répond dans le terminal, l'app retire l'alerte au prochain événement de la session.
- Un bug a été signalé où `deny` était ignoré sur `PermissionRequest` (issue GitHub anthropics/claude-code #19298). **Tester allow et deny** ; si deny ne marche pas, basculer la décision sur `PreToolUse` (`permissionDecision`) pour les outils concernés.
- « Toujours autoriser » : si la doc permet de renvoyer une règle de permission persistante, l'utiliser. Sinon l'app garde sa propre liste (projet + outil + motif de commande) et répond `allow` automatiquement ensuite. Liste visible et supprimable dans les réglages.
- Raccourcis Y / N quand la vue `approval` est ouverte.

### Répondre aux questions (`AskUserQuestion`)
- **Claude Code 2.1.85+** : `AskUserQuestion` arrive en `PreToolUse` (avec `matcher: "AskUserQuestion"`), non plus en `PermissionRequest`. Un hook dédié avec `--ask` et un timeout de 130 s est requis dans `settings.json`. Si ce hook manque, l'app affiche la bannière « Hooks outdated — update them to answer Claude's questions from the notch » dans les réglages et propose la mise à jour.
- `PermissionRequest` pour `AskUserQuestion` : l'app répond `{"permissionDecision":"ask"}` immédiatement (no-op) et n'affiche pas de carte.
- `PreToolUse` général pour `AskUserQuestion` : l'app ignore l'événement (pas de mise à jour de l'état `.working`).
- `tool_input.questions` : tableau de 1 à 4 questions, chacune avec `question` (texte), `header` (≤ 12 car.), `options` (2 à 4, chacune `label` + `description`), `multiSelect`.
- L'app parse en un modèle Foundation (`AskQuestion`) ; si le parse échoue, nb-hook.py n'émet rien → Claude Code re-pose la question dans le terminal.
- La vue `question` affiche une question à la fois (compteur 1/N), les options en grille fluide (`ChipFlowLayout`), un champ libre « Other… », et un lien « Reply in terminal » dans l'en-tête (envoie `ask`, aucune sortie).
- Single-select : clic = réponse immédiate (pas de bouton Send). Multi-select : toggles + bouton Send/Next, désactivé tant qu'aucun choix.
- Réponse via socket : `{"decision":"answer","answers":{"<question>":"<label>"}}`. Multi-select : valeur `[String]` (tableau, Claude Code 2.1.136+). Single-select et « Other… » : valeur `String`.
- nb-hook.py `--ask` : si `decision == 'answer'` → émet `hookSpecificOutput` avec `hookEventName: "PreToolUse"`, `permissionDecision: "allow"` et `updatedInput: {questions, answers}` — Claude Code reçoit les réponses et continue.
- Fallback : si l'app ne répond pas (absente, timeout 125 s) ou renvoie `ask`, nb-hook n'émet rien → Claude Code re-pose la question dans le terminal.

### Sauter au terminal
| Contexte capté | Action |
|---|---|
| `TERM_PROGRAM=Apple_Terminal` + tty | AppleScript Terminal : sélectionner l'onglet dont le `tty` correspond, activer |
| `TERM_PROGRAM=iTerm.app` + `ITERM_SESSION_ID` | AppleScript iTerm : sélectionner la session, activer |
| `TERM_PROGRAM=vscode` | ouvrir le dossier `cwd` dans VS Code ou Cursor (selon `__CFBundleIdentifier`) |
| Ghostty, Warp, autre | activer l'app |
| rien (app Claude) | activer l'app Claude |
Demande l'autorisation Automatisation la première fois (normal).

### Installation des hooks : procédure obligatoire
1. Lire `~/.claude/settings.json` (le créer s'il n'existe pas).
2. Copier en `~/.claude/settings.json.bak-AAAAMMJJ-HHMM`.
3. **Fusionner** : ajouter les hooks Notch Buddy sans toucher aux hooks existants. Chemin de `nb-hook` entre guillemets (il contient un espace).
4. Montrer le diff à Louis, attendre son OK, écrire.
5. Bouton « Désinstaller les hooks » dans les réglages qui retire uniquement les entrées Notch Buddy.

---

## 1bis. Jauge de forfait Claude (statusLine)

**Affichage** : petit pill dans l'en-tête de l'île (vue home uniquement) — plus de pastille dans le catalogue Active pills.  
**Plateforme** : macOS uniquement (build GitHub)  
**Plans** : Pro et Max uniquement (le champ `rate_limits` n'est présent que pour ces plans)

Affiche la consommation du forfait Claude via un pill coloré dans l'en-tête de l'île. Couleur dynamique : vert `#22C55E` < 50 %, orange `#F59E0B` 50–80 %, rouge `#F4505E` ≥ 80 %, gris `#6B7079` sans données. Cliquer sur le pill bascule `showingPlanDetail`, ce qui remplace la carte en cours par `ClaudePlanCardView`. `showingPlanDetail` se remet à false au changement de focusId, de vue ou de mode.

### Données

Claude Code envoie, à chaque réponse et avec un debounce de 300 ms, un JSON à la commande `statusLine` configurée dans `~/.claude/settings.json`. Ce JSON contient :

```json
{
  "session_id": "…",
  "rate_limits": {
    "five_hour": { "used_percentage": 23.5, "resets_at": 1738425600 },
    "seven_day":  { "used_percentage": 67.0, "resets_at": 1738598400 }
  }
}
```

`used_percentage` va de 0 à 100. `resets_at` est un epoch UNIX en secondes. Le champ `rate_limits` peut être absent (plan Free, ou première réponse de la session). Chaque fenêtre peut être absente indépendamment. Les valeurs absurdes (< 0 ou > 100) sont ignorées. Une fenêtre dont `resets_at` est passé s'affiche à 0 % jusqu'à la prochaine mise à jour.

### Relais

nb-hook.py, en mode `--statusline`, lit le JSON de stdin, en extrait `rate_limits` et `session_id`, et envoie `{"coucou_kind": "statusline", …}` au socket en fire-and-forget (timeout 0,3 s). Si une `statusLine` précédente existait (sauvegardée dans `statusline-previous.json` à côté de nb-hook), elle est appelée via `/bin/sh -c` avec le même stdin et sa sortie est réécrite telle quelle (timeout 10 s, couleurs ANSI comprises).

### Installation et activation

Réglages → Agents → Plan usage → **Install relay**. Coucou montre le diff de `~/.claude/settings.json` avant d'écrire quoi que ce soit. Si une `statusLine` existait, seul le champ `command` est remplacé ; les autres champs (`padding`, `refreshInterval`, etc.) sont conservés. Une fois le relais installé, activer le toggle **Show in the notch** pour faire apparaître le pill dans l'en-tête. Si le toggle est activé avant l'installation du relais, l'installation est lancée automatiquement ; le toggle s'active après confirmation.

### Désinstallation

Réglages → Agents → Plan usage → **Uninstall relay**. Remet l'objet `statusLine` d'origine à l'identique, ou retire la clé si elle n'existait pas. Si la `statusLine` actuelle n'est plus celle de Coucou (l'utilisateur l'a changée), elle n'est pas touchée.

---

## 1ter. Diff en direct (live diff)

Sur `PostToolUse` pour `Edit`, `MultiEdit` et `Write` (Claude Code, Cursor), l'app calcule un diff ligne à ligne et l'affiche dans le fil de l'île.

**Données**
- `Edit` : `old_string → new_string`
- `MultiEdit` : liste `edits`, chaque entrée `old_string → new_string`
- `Write` : `content` — tout le contenu est compté en ajout (on ne lit jamais le fichier sur le disque)
- Le diff est calculé localement (Foundation, jamais de lecture sur le disque).
- Limite : 200 Ko de texte combiné ou 4 000 lignes combinées → bilan seul, "Diff too large".
- Mémoire : 50 diffs max par session, les plus anciens sont oubliés ; tout effacé à la fin de la session (`SessionEnd`) ou après une heure sans activité.

**Fil (TickerView)** — les étapes de modification affichent le nom du fichier, `+N` en vert `#22C55E` et `−M` en rouge `#F4505E`, petits et monospacés.

**Carte diff** — un clic sur une étape de modification ouvre la carte diff dans la vue principale :
- En-tête : nom du fichier + bilan + bouton ↗ (ouvre dans VS Code via `code -g fichier:ligne`, sinon `NSWorkspace`)
- Lignes en monospace 10,5 pt, fond vert ou rouge à 12 %, symbole +/− en marge, 3 lignes de contexte
- Défilement vertical ; Échap ou clic sur l'en-tête pour revenir au fil

**Vue Terminé (FinishedView)** — affiche la dernière ligne utile de la session (`finalLine` → dernière étape non-diff → "Session finished"), sur une ligne (`.lineLimit(1).truncationMode(.tail)`). Pas de liste de fichiers.

---

## 1quater. Cursor Agent *(build GitHub, macOS)*

**Doc officielle** : https://cursor.com/docs/hooks — à revérifier avant toute évolution.

### Architecture
```
Cursor Agent (Composer)
  └─ hooks.json (~/.cursor/hooks.json)
       └─ /bin/sh "…/nb-hook" --agent cursor
            └─ socket Unix → Coucou (pastille agent_cursor)
```

- Installateur : Settings → Agents → Cursor Hooks (même flux backup + preview + confirm que Gemini/Codex).
- Format Cursor : `{ "version": 1, "hooks": { "<event>": [ { "command": "…", "timeout": N } ] } }` (tableau plat, pas de groupes `matcher`).
- Le relais traduit les noms camelCase et mappe `afterFileEdit` vers un `PostToolUse`/`MultiEdit` pour le live diff (clés `old_string` / `oldString` / `old_line` acceptées).
- À chaque Edit/MultiEdit (et `afterFileEdit`) : focus sur `agent_cursor`, île force-expand, layout **programming** (rail d'étapes à gauche + éditeur diff large à droite) avec typewriter sur `+` et strikethrough sur `−`. Les Write full-file trop gros restent ticker-only. `pendingOpenDiff` couvre la course expand ↔ montage de OverviewView.

---

## 1quater-bis. Render *(build GitHub, macOS)*

- Réglages → Integrations → Render : clé API (`render-api-key`, Trousseau) + filtre de services.
- Polling 30 s : `GET /v1/services` puis dernier deploy par service (`GET /v1/services/{id}/deploys?limit=1`).
- Pastille `integration_render` (`#46E3B7`) : liste des deploys + détail (statut live/failed/building, commit, lien dashboard).
- MVP : observation seule (thinking / working / finished). Pas de `beforeShellExecution` ni carte Allow/Deny (prévu en MVP+).
- Claude Code lancé dans le terminal de Cursor continue d'être routé vers la même pastille via le bundle ID Electron.

Détail des événements : `docs/AGENTS.md` § Cursor Agent.

---

## 1quater-ter. Spotify *(build GitHub, macOS)*

- Pastille `integration_spotify` (`#1DB954`) : même UX qu'Apple Music (carte now-playing + contrôles play/pause/prev/next dans la pastille au survol).
- Carte : volume Spotify (`sound volume` 0–100, ±/− par pas de 10) + bouton pour lancer / ouvrir l'app desktop.
- Mode compact : ticker « now playing » (titre · artiste) qui défile dans la bande centrale entre Mochi et la mini-grille.
- Idle : « Launch Spotify » si l'app n'est pas ouverte, sinon « Open Spotify ». Les contrôles transport lancent Spotify s'il n'est pas déjà lancé.
- État via notification distribuée `com.spotify.client.PlaybackStateChanged` + lecture AppleScript (`application id "com.spotify.client"`).
- Pas d'OAuth Web API : contrôle local du client desktop Spotify uniquement.
- Permission Automatisation → Spotify (macOS). Si refusée (`-1743`), la carte propose d'ouvrir Réglages Système.
- Mochi danse quand Spotify joue et que la pastille est active (même règles que Music).

---

## 1quinquies. GitHub (pulse)

**Plateforme** : macOS uniquement (build GitHub)

**Token** : token classique avec scope `repo`, ou token fin avec accès en lecture à Pull requests, Commit statuses et Actions. Stocké dans le Trousseau (`github-token`).

### Données récupérées

Deux requêtes GraphQL séparées (POST `https://api.github.com/graphql`, même token, même en-tête) :

**Requête pulse** :
- **Mes PRs ouvertes** (20 dernières par date de mise à jour) : numéro, titre, URL, isDraft, `reviewDecision`, `oid` du dernier commit, état CI du dernier commit (`statusCheckRollup.state`)
- **PRs à reviewer** (recherche `is:pr is:open review-requested:@me`, 20 max) : numéro, titre, URL, auteur
- **CI branche par défaut** (10 derniers dépôts propres, non archivés) : `oid` et état CI du commit HEAD sur `defaultBranchRef`

**Cadence pulse** : 5 min (pas de PRs en attente) ou 60 s (au moins une PR/CI en état `PENDING` ou `EXPECTED`). Première requête 10 s après le lancement.

**Rafraîchissement pulse à l'ouverture** : `GithubPoller.refreshIfStale(maxAge: 60)` appelé quand `integration_github` prend le focus, quand l'île s'étend avec GitHub en focus, et à l'ouverture d'une vue détail (sauf Activity). Si données < 60 s ou requête en vol, ignoré.

**Requête activité** (`contributionCalendar`) :
```graphql
query { viewer { login contributionsCollection { contributionCalendar {
  totalContributions weeks { contributionDays { date contributionCount contributionLevel weekday } }
} } } }
```
- `contributionLevel` : NONE → 0, FIRST_QUARTILE → 1, SECOND_QUARTILE → 2, THIRD_QUARTILE → 3, FOURTH_QUARTILE → 4. Valeur inconnue → 0.

**Cadence activité** : 30 min, première requête 15 s après le lancement.

**Rafraîchissement activité à l'ouverture** : `GithubPoller.refreshActivityIfStale(maxAge: 300)` appelé à l'ouverture de la vue Activity. Si données < 5 min ou requête en vol, ignoré.

Données gardées en mémoire (`AppState.githubActivity`). Remises à nil si token change ou si `integration_github` est désactivé.

### États CI (`CIState`)

| Valeur GitHub         | `CIState`  |
|-----------------------|------------|
| `PENDING`, `EXPECTED` | `.pending` |
| `SUCCESS`             | `.success` |
| `FAILURE`, `ERROR`    | `.failure` |
| `null` ou autre       | `.unknown` |

### Alertes

Premier poll après lancement : toujours silencieux. Polls suivants :

**Même `headSha` (oid) qu'au poll précédent** — règles classiques de transition :
- CI passe de `!failure` → `failure` : `.ciFailed` / `.mainFailed`
- CI passe de `pending` → `success` : `.ciPassed`

**`headSha` différent ou PR/dépôt absent au poll précédent** (nouveau commit ou nouvelle PR, CI déjà terminée avant le poll) :
- CI = `success` → `.ciPassed` (PR uniquement ; pas d'alerte vert pour main)
- CI = `failure` → `.ciFailed` / `.mainFailed`
- CI = `pending` → rien (le poll suivant, même sha, verra la transition)

| Événement             | Badge   | Son        |
|-----------------------|---------|------------|
| CI PR failure / main  | `.error` (rouge) | `error` |
| Nouvelle review demandée | `.finished` (vert) | `question` |
| CI PR success         | `.finished` (vert) | `finish` |

Priorité : failure > review demandée > success. Un seul badge/son par cycle.

---

## 2. n8n (workflows de Louis)

- Réglages : URL de l'instance (probablement `https://n8nlouis.dcsys.tech`, **à confirmer avec Louis**) et clé API n8n (Trousseau). La clé se crée dans n8n : Settings → n8n API.
- Le Mac joint n8n, pas l'inverse : **polling** toutes les 5 s de l'API publique :
  - noms des workflows : `GET /api/v1/workflows` (cache 10 min) ;
  - exécutions récentes : `GET /api/v1/executions` avec filtres de statut et `limit`.
- Mapping :
  - exécution en cours → tâche `working` (si l'API expose les exécutions en cours ; sinon n8n n'apparaît qu'aux erreurs et aux succès, c'est acceptable) ;
  - nouvelle exécution en erreur → alerte `error`, détail = nœud en échec + message (`GET /api/v1/executions/{id}?includeData=true`) ;
  - succès → mini-bonhomme `finished` 3 s en compact, **sans** ouvrir l'island (sinon trop de bruit), sauf réglage contraire.
- Boutons :
  - « Relancer » → endpoint de retry de l'API publique (vérifier sa présence et son chemin dans le playground de l'instance). S'il n'existe pas : ouvrir l'exécution dans n8n.
  - « Ouvrir dans n8n » → ouvrir `{URL}/workflow/{workflowId}/executions/{executionId}` dans le navigateur par défaut.
- Réglage « workflows suivis » : tous par défaut, liste à cocher.

---

## 3. Fichiers déposés

- Glisser-déposer natif sur la panel (types `fileURL`). Copier les fichiers dans `~/Library/Application Support/NotchBuddy/inbox/` (c'est la phase `uploading`).
- Vue `choose` :
  - **Poser une question dessus** → vue `prompt` avec une pastille du fichier. Envoi à l'API Claude (§5) : PDF en bloc `document`, images en bloc `image`, texte et code (≤ 200 Ko) en texte. Autres types : message « Je ne sais pas lire ce format, mais je peux l'envoyer par mail. »
  - **Envoyer par mail** → vue `mail` (§6).
- Nettoyer l'inbox après 7 jours.

---

## 4. Attacher le bonhomme à une fenêtre

1. Au lâcher, trouver la fenêtre sous le point : `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`, première fenêtre de couche 0 qui n'est pas la nôtre et contient le point. Récupérer app, titre, cadre.
2. Afficher le **halo** : une panel transparente, non cliquable, posée sur le cadre de la fenêtre. Bordure conique arc-en-ciel de 3 pt qui tourne en 3 s (`#FF6B5B → #F7B32B → #2DD4A7 → #38BDF8 → #A78BFA → #F472B6`), voile multicolore en mode multiply qui respire (voir `.attach` du prototype), fondu d'entrée 600 ms. Son `attach`, émote Clin d'œil.
3. Contexte envoyé à Claude :
   - capture de la fenêtre avec ScreenCaptureKit (`SCScreenshotManager`), redimensionnée à 1568 px de large max ;
   - si c'est Safari, Chrome, Arc ou Brave : URL et titre de l'onglet actif via AppleScript.
4. Vue `prompt` avec la pastille « Safari, escale.fr » (app + domaine), focus sur le champ.
5. Le halo reste pendant `searching`, disparaît quand le résultat s'affiche ou quand l'island se ferme.

Permissions : Enregistrement de l'écran (capture) et Automatisation (navigateur). Si refusées : on continue sans capture ou sans URL, et on le dit en une ligne dans la vue.

---

## 5. API Claude (recherche)

- `POST https://api.anthropic.com/v1/messages`, en-têtes `x-api-key`, `anthropic-version`, `content-type: application/json` (versions à vérifier dans la doc).
- Modèle par défaut : `claude-sonnet-4-6`, choisi dans Settings → Anthropic API **ou depuis la puce de modèle dans la vue `.prompt`**. La liste est récupérée à l'ouverture des réglages via `GET /v1/models?limit=100` (en-têtes `x-api-key` et `anthropic-version: 2023-06-01`) ; si l'appel échoue ou qu'il n'y a pas de clé, une liste de secours est utilisée (`claude-sonnet-4-6`, `claude-sonnet-5-5`, `claude-opus-5-5`, `claude-haiku-4-5-20251001`). Un champ libre permet d'entrer n'importe quel identifiant. Si le modèle sauvegardé n'est pas dans la liste, le sélecteur reste sur « Custom… ». Dans le chat, si le modèle enregistré n'est pas dans la liste reçue, le premier dont l'identifiant contient « sonnet », sinon le premier de la liste.
- Erreurs de l'API : affiche `error.message` au lieu du JSON brut. Pour un `not_found_error`, affiche « Model not found: \<id\>. Pick another one in Settings. »
- Outil de recherche web côté serveur de l'API : l'identifiant de type à jour est dans la doc (au moment d'écrire, `web_search_20250305`) ; `max_uses` 5.
- Prompt système (français) : répondre court, pour un affichage dans le notch, au format JSON strict :
  ```json
  { "title": "…", "items": [ { "label": "…", "detail": "…", "url": "…" } ], "note": "…" }
  ```
  3 items maximum. Si le JSON est invalide : afficher le texte brut (3 lignes max) dans la vue `result`.
- Contenu du message utilisateur : capture (bloc image) + « URL : … / Titre : … / Demande : … », ou fichier (§3) + demande, ou demande seule (onglet Demander).
- Pendant l'appel : état `searching`, vue `searching`, texte scintillant. Réponse : état `finished`, vue `result`, émote Fier, son `finish`.
- Boutons du résultat : « Ouvrir » (premier lien, seulement s'il est en http ou https ; sinon le bouton est grisé), « Copier » (texte), « Fermer ».
- Erreur réseau ou clé invalide : état `error`, vue `note` avec la raison en une phrase et « Ouvre les réglages pour vérifier la clé ».
- Micro (bouton du champ) : dictée `SFSpeechRecognizer` en `fr-FR`, sur l'appareil si possible. Optionnel (M9). Si la permission est refusée, masquer le bouton.

---

## 5bis. Chat Coucursor — ClinePass

**ID de pastille** : `ai_clinepass` (violet `#7C5CFF`)  
**Catégorie** : AI for the chat  
**Plateforme** : Coucursor (target GitHub macOS)

Clé dans Settings → Chat (Trousseau : `cline-api-key`, créée sur app.cline.bot → Settings → API Keys).

- Catalogue : `GET https://api.cline.bot/api/v1/models` (Bearer) ; si l'appel échoue, liste fixe des slugs `cline-pass/*` (Qwen, Kimi, GLM, DeepSeek, etc.).
- Chat : `POST https://api.cline.bot/api/v1/chat/completions` (format OpenAI-compatible). Modèle par défaut `cline-pass/qwen3.7-max`.
- Contexte envoyé : texte + historique ; fenêtre attachée → app/titre/URL ; fichier attaché → nom seulement.

Les autres fournisseurs de chat (Anthropic chat, Google, OpenAI, Cursor Cloud Agents, Ollama, LM Studio) ne sont pas exposés dans Coucursor. Cursor reste disponible via les **hooks** Agent (`agent_cursor`).

---

## 6. Mail (app Mail du Mac)

- Vue `mail` : À (obligatoire, validation d'adresse), Objet (prérempli : nom du fichier), Message (optionnel, une ligne).
- Envoi uniquement au clic sur « Envoyer », via AppleScript (`NSAppleScript`) sur Mail :
  ```applescript
  tell application "Mail"
    set m to make new outgoing message with properties {subject:"…", content:"…", visible:false}
    tell m
      make new to recipient at end of to recipients with properties {address:"…"}
      make new attachment with properties {file name:(POSIX file "…")} at after the last paragraph of content
    end tell
    delay 1
    send m
  end tell
  ```
  Le `delay` laisse le temps à la pièce jointe d'être prise en compte (comportement connu de Mail). `Info.plist` : `NSAppleEventsUsageDescription`.
- Succès : vue `note` « Mail envoyé à … », émote Clin d'œil, son `send`. Échec : état `error` avec la raison.

---

## 7. Permissions macOS demandées (récapitulatif pour Louis)

| Permission | Pourquoi | Quand |
|---|---|---|
| Automatisation → Mail | envoyer les mails | premier envoi |
| Automatisation → Terminal / iTerm / navigateur | sauter au bon onglet, lire l'URL | première utilisation |
| Automatisation → Musique *(GitHub only)* | contrôler la lecture Apple Music | première commande depuis le notch |
| Automatisation → Spotify *(GitHub only)* | contrôler la lecture Spotify | première commande depuis le notch |
| Enregistrement de l'écran | capturer la fenêtre attrapée | première attache |
| Micro + Reconnaissance vocale (optionnel) | dictée | premier clic sur le micro |

Aucune permission Accessibilité nécessaire.


