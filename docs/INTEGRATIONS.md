# Notch Buddy — intégrations

Règle d'or : **vérifier la doc officielle au moment d'implémenter**. Les formats ci-dessous sont le plan, pas une garantie. Sources à relire :
- Hooks Claude Code : https://code.claude.com/docs/en/hooks
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
- `nb-hook` : cible séparée dans le projet, copiée dans `~/Library/Application Support/NotchBuddy/bin/nb-hook` au premier lancement.
- Socket : `~/Library/Application Support/NotchBuddy/nb.sock` (version GitHub) ou `~/Library/Containers/fr.louisraille.Coucou/Data/nb.sock` (version App Store). Dossier en 0700, socket en 0600. Connexions du même utilisateur seulement (vérification `getpeereid`). 1 Mio et 5 s maximum par message, 32 connexions simultanées.
- `nb-hook <Event>` lit le JSON du hook sur stdin, ajoute le contexte du terminal (`TERM_PROGRAM`, `ITERM_SESSION_ID`, `TERM_SESSION_ID`, `__CFBundleIdentifier`, le tty trouvé en remontant les processus parents, `cwd`), l'envoie à l'app.
- **Si l'app ne répond pas en 300 ms, `nb-hook` sort en code 0 sans rien écrire** : Claude Code continue normalement. Jamais de blocage.

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

### Répondre aux questions
- Si Claude utilise l'outil de question (`AskUserQuestion`), l'intercepter en `PreToolUse` et afficher les options dans la vue `question`.
- Vérifier dans la doc si un hook peut fournir la réponse. Si oui : clic sur une option = réponse. **Si non** : la vue affiche la question et un bouton « Répondre dans le terminal » qui saute à la session. Ne pas bricoler de frappe clavier simulée.

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

- Fournisseur choisi dans les réglages (« AI Provider ») : API officielle Anthropic (défaut, web search activé, clé obligatoire) **ou** endpoint personnalisé — base URL + style (Messages Anthropic ou Chat Completions OpenAI) + modèle + clé optionnelle (les gateways locaux n'en demandent souvent pas). Le web search n'est envoyé que sur l'API officielle ; le dialecte OpenAI n'a pas d'équivalent portable.
- `POST https://api.anthropic.com/v1/messages`, en-têtes `x-api-key`, `anthropic-version`, `content-type: application/json` (versions à vérifier dans la doc).
- Modèle par défaut : `claude-sonnet-5`, réglable dans les réglages. Vérifier la liste des modèles disponibles dans la doc.
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
| Enregistrement de l'écran | capturer la fenêtre attrapée | première attache |
| Micro + Reconnaissance vocale (optionnel) | dictée | premier clic sur le micro |

Aucune permission Accessibilité nécessaire.
