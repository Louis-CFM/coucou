# « OK Coucou » : commande vocale mains libres (Mac)

Plan de travail pour Claude Code. Mac uniquement : ne toucher ni à `windows/`, ni à l'app iPhone (`Sources/Phone/`).
Chaque phase = une PR, avec ses tests, et rien ne sort de ce qui est demandé dans la phase.

## L'idée

Coucou écoute en permanence (si l'utilisateur l'a activé). On dit « OK Coucou » : l'île compacte s'ouvre, Mochi fait
une petite émote d'écoute et affiche « À l'écoute… » avec la transcription en direct. On dit ce qu'on veut, Coucou le fait,
Mochi réagit (content, ou « je n'ai pas compris »), l'île se referme. Coucou ne parle pas (pas de synthèse vocale pour l'instant).

## Règles non négociables

- **100 % local.** Reconnaissance vocale sur l'appareil uniquement (`requiresOnDeviceRecognition = true`, jamais de repli
  serveur : si la langue n'est pas disponible sur l'appareil, on le dit et on n'écoute pas). Compréhension par analyseur
  local, puis par le modèle d'Apple sur l'appareil (Foundation Models). Aucun appel réseau, aucune clé d'API.
- **Rien n'est enregistré.** L'audio reste en mémoire, jamais sur disque. Les transcriptions ne sont pas loguées
  (au plus « commande reconnue : music.play » dans les logs).
- **Désactivé par défaut.** Interrupteur dans Réglages → Voix. Éteint = micro fermé, 0 % CPU, comme aujourd'hui.
- **Budget CPU quand l'écoute est active** : < 1 % en moyenne au repos (silence) sur Apple Silicon, mesuré dans
  Moniteur d'activité, chiffres dans la PR. Pas de reconnaissance vocale qui tourne pendant le silence (détection de voix d'abord).
- **Règles de CLAUDE.md inchangées** : la voix ne peut jamais approuver une permission Claude Code / Codex, ni envoyer un e-mail.
  Elle prépare, l'utilisateur clique. (Refuser une permission à la voix est autorisé.)
- **Pas de dépendance tierce** : AVFoundation, Speech, FoundationModels, Contacts, CoreSpotlight/NSMetadataQuery, AppKit.
- **Ne pas restyler l'existant** : l'état d'écoute et la carte de confirmation sont de nouvelles vues dans le style de l'app.
- Cible de déploiement inchangée (macOS 15). Tout ce qui demande macOS 26 passe par `#available` avec un repli.
- Le micro affiche le point orange de macOS tant que l'écoute est active : c'est normal, à expliquer dans les réglages.

## Architecture

Nouveau dossier `NotchBuddy/Sources/App/Voice/` :

| Fichier | Rôle |
|---|---|
| `VoiceSettings.swift` | Interrupteur, phrase de réveil (« OK Coucou » par défaut, « Dis Coucou », « Hey Coucou »), langues (réutiliser `MacDictation.automaticLocales()`), raccourci pour couper le micro. |
| `VoiceAudio.swift` | `AVAudioEngine`, entrée 16 kHz mono. Détection de voix par énergie (seuil adaptatif au bruit de fond) qui ne réveille la reconnaissance que quand quelqu'un parle. |
| `WakeSpotter.swift` | Protocole + implémentations : `SpeechWakeSpotter` (SFSpeechRecognizer, macOS 15, `contextualStrings = ["Coucou", "OK Coucou"]`) et `AnalyzerWakeSpotter` (SpeechAnalyzer, macOS 26). Correspondance tolérante : « ok coucou », « okay coucou », « OK cuckoo », « ok kuku »… |
| `CommandListener.swift` | Après le réveil : capture la commande, transcription partielle en direct, fin sur 1,2 s de silence ou 10 s max. « Annule » / « laisse tomber » ferme. |
| `VoiceIntent.swift` | L'enum des actions (voir les 10 fonctions) avec leurs paramètres typés. C'est le seul contrat entre compréhension et exécution. |
| `IntentParser.swift` | Analyseur déterministe FR + EN (expressions + listes de synonymes). Instantané, prévisible, testable. |
| `EntityResolver.swift` | Relie les mots aux vraies choses : pilules (noms + alias de `PillCatalog`, sans jamais changer les IDs), tenues, apps installées, contacts, fichiers (Spotlight limité à Téléchargements / Bureau / Documents). Correspondance floue + score. |
| `VoiceBrain.swift` | macOS 26 + Apple Intelligence : `LanguageModelSession` avec des `Tool` qui renvoient des `VoiceIntent` (génération guidée `@Generable`). Le modèle n'exécute rien lui-même : il propose, `VoiceActionRunner` décide. Utilisé seulement si l'analyseur déterministe n'a rien trouvé, et pour les questions. |
| `VoiceActionRunner.swift` | Exécute un `VoiceIntent` selon sa politique : direct (musique, pilules…) ou carte de confirmation (e-mail, consigne à un agent). Renvoie un résultat pour la réaction de Mochi. |
| `VoiceIslandViews.swift` | État « écoute » de l'île : émote de Mochi, « À l'écoute… », transcription, puis résultat / carte de confirmation. |

Chaîne : micro → détection de voix → réveil → commande → `IntentParser` → (sinon `VoiceBrain`) → `EntityResolver` → `VoiceActionRunner` → île.

Pause automatique de l'écoute : écran verrouillé ou en veille, mode Économie d'énergie, dictée du chat en cours
(`MacDictation` utilise déjà le micro), raccourci « couper le micro ». Reprise automatique.

Machine d'état de l'île : ajouter un état `listening` à `IslandStateMachine` (à côté de `petit` / `home` / `coucou`),
avec ses tests comme les autres transitions.

## Les 10 fonctions de base

| # | Fonction | Exemples (FR / EN) | Exécution | Confirmation |
|---|---|---|---|---|
| 1 | **Musique** | « lance Apple Music », « mets ma playlist Focus », « pause », « suivant », « mets du Daft Punk », « monte le son » | `MusicController` (AppleScript déjà autorisé) ; Spotify via `SpotifyController` si c'est lui qui joue | Non |
| 2 | **Pilules actives** | « ajoute Vercel », « enlève Stripe », « remplace n8n par GitHub », « garde seulement GitHub et Vercel » | `AppState.activeIntegrations`, même logique que Réglages (limite de 4) | Non. Si c'est plein : Mochi demande laquelle retirer |
| 3 | **Pilule principale** | « passe la pilule principale sur Cursor », « main pill Terminal » | `AppState.mainPillId`, même enchaînement que le Picker des réglages | Non |
| 4 | **Envoyer un fichier par mail** | « envoie le fichier facture octobre de mes téléchargements à Tana » | Spotlight trouve le fichier, Contacts trouve l'adresse, `NSSharingService(.composeEmail)` avec destinataire, objet et pièce jointe | **Toujours** : carte « facture-octobre.pdf → Tana (tana@…) », puis l'envoi se fait d'un clic dans Mail. Si plusieurs fichiers ou contacts : choix dans la carte |
| 5 | **Ouvrir** | « ouvre Figma », « ouvre le dossier Coucou », « ouvre le dernier fichier téléchargé », « ouvre github.com » | `NSWorkspace` + Spotlight ; URL seulement en http(s) (`SafeWebURL`) | Non |
| 6 | **Où en sont mes agents** | « qu'est-ce que fait Claude ? », « ouvre la session Codex », « montre-moi le terminal de Claude » | Focus de la pilule + `TerminalTarget` pour sauter au terminal | Non |
| 7 | **Dicter une consigne à un agent** | « dis à Claude de lancer les tests », « demande à Cursor de corriger le lint » | Même chemin que les consignes de l'iPhone (`InstructionRunner`), Claude Code et Cursor seulement | **Oui** : carte avec le texte exact, un clic pour envoyer |
| 8 | **Demandes d'autorisation** | « c'est quoi la demande ? », « refuse » | Ouvre la carte d'approbation existante. Refuser à la voix : oui. Autoriser : jamais, le clic reste obligatoire | Autoriser = clic, toujours |
| 9 | **Minuteurs et rappels** | « rappelle-moi dans 20 minutes de sortir le linge », « minuteur 5 minutes » | Rappel local, Mochi l'annonce dans le notch (+ notification) | Non |
| 10 | **Questions** | « est-ce que la CI est verte ? », « combien j'ai vendu aujourd'hui ? », « il me reste combien sur mon plan Claude ? », « c'est quoi la commande pour annuler un commit ? » | État de Coucou et des services déjà lus (GitHub, Vercel, Stripe, Resend, n8n, usage Claude) ; questions générales par `VoiceBrain` sur l'appareil | Non. Réponse en texte dans l'île |

**E-mail guidé (fonction 4, version actuelle).** « Envoie un mail » → Coucou demande à qui (nom de contact ou
adresse épelée), l'objet, le texte (ou « écris-lui que… » : le modèle local rédige), puis « une pièce jointe ? » : on glisse
le fichier sur le notch (ou « non »). Les étapes déjà dites dans la première phrase sont sautées ; « annule » arrête tout.
La carte mail de l'île s'ouvre remplie et reste ouverte jusqu'au clic : Envoyer passe par Apple Mail (AppleScript),
Annuler ferme. Rien ne part sans ce clic.

**Recherche web (opt-in).** Réglages → Voix → « Répondre aux questions avec une recherche web », visible avec une clé
Anthropic. Une question que ni les pilules ni les services ne couvrent (« qui a gagné hier ? », « c'est quoi… ») ou une
demande explicite (« cherche sur internet… », « search the web for… ») part chez Claude (Haiku, outil `web_search`)
avec les derniers échanges de la conversation, en mémoire seulement, oubliés après 90 s. Réponse courte lue à voix haute ;
quand il y a plus à dire, elle finit par une question et Coucou réécoute : on peut continuer le sujet.

Bonus (après les 10) : Mochi et l'app à la voix (« mets-toi en pirate », « coupe les sons », « ne pas déranger »),
routines (« mode focus » = playlist + ne pas déranger + pilules de travail).

## Phases (une PR chacune)

**Phase 1 : écoute et réveil.** Réglages → Voix (désactivé par défaut, explication du point orange), permission micro
et reconnaissance vocale, `VoiceAudio` + détection de voix, `SpeechWakeSpotter`, état `listening` de l'île avec
l'émote de Mochi et la transcription. Pas encore d'actions : la commande s'affiche, c'est tout.
Critères : réveil en moins de ~1 s après « OK Coucou », pas de déclenchement sur « coucou » tout seul dans une phrase,
CPU au repos mesuré et < 1 %, 0 % et micro fermé quand c'est éteint, pause écran verrouillé / Économie d'énergie / dictée du chat.
Tests : correspondance de la phrase de réveil (table de variantes), transitions de l'île.

**Phase 2 : comprendre et agir (fonctions 1, 2, 3).** `VoiceIntent`, `IntentParser` FR + EN, `EntityResolver` pour les
pilules, `VoiceActionRunner`, réaction de Mochi (réussi / pas compris / impossible).
Tests : table d'au moins 60 phrases FR + EN → intention attendue, résolution floue des noms de pilules, limite de 4.

**Phase 3 : fichiers, apps, contacts (fonctions 4, 5).** Spotlight limité aux trois dossiers, Contacts (permission demandée
au premier usage seulement), carte de confirmation, `NSSharingService` pour Mail. Rien ne part sans le clic dans Mail.

**Phase 4 : agents (fonctions 6, 7, 8).** Focus et saut au terminal, consigne via `InstructionRunner` avec carte de
confirmation, carte d'autorisation (refuser à la voix oui, autoriser jamais).

**Phase 5 : rappels et questions sur l'état (fonctions 9, 10 sans le modèle).**

**Phase 6 : le cerveau local (macOS 26).** `VoiceBrain` avec Foundation Models et des `Tool` pour chaque `VoiceIntent`,
utilisé quand l'analyseur ne trouve pas, plus les questions générales. Vérifier `SystemLanguageModel.default.availability`
et dire clairement dans les réglages quand ce n'est pas disponible (Mac Intel, Apple Intelligence éteinte, langue).
Passer aussi la détection sur `SpeechAnalyzer` quand macOS 26 est là.

**Phase 7 : finitions.** Réglage de la sensibilité, liste des faux déclenchements, traductions (le catalogue de chaînes
existant), `docs/SPEC.md`, section README, CHANGELOG, puis release (règles de release de CLAUDE.md).
Piste pour plus tard : un petit modèle Core ML dédié à « OK Coucou » sur le Neural Engine, pour descendre encore le CPU.

## Build App Store (sandbox)

À vérifier à chaque phase : entitlements micro (`com.apple.security.device.audio-input`), Contacts, Téléchargements en
lecture. Pour Mail, `NSSharingService` passe sans Apple Events. Si une fonction ne peut pas marcher dans le sandbox, elle reste
dans le build GitHub (comme l'usage du plan Claude aujourd'hui) et c'est écrit dans la PR.
