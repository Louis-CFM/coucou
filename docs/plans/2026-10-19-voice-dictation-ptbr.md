# Voice and dictation in pt-BR — implementation plan

Date: 2026-10-19 · Branch: `feat/voice-ptbr` · Author: Daedalus (plan only) · Risk: Medium

## Objective

Make Coucou's voice assistant (OK Coucou → intent → answer → speech) and dictation (Flow, Notetaker)
work end to end in Brazilian Portuguese, as a **third language next to English and French**. en and fr
keep working exactly as today.

## Non-goals

- Removing or rewriting the en/fr paths. Every change is additive (a `pt` branch, a new table, a new file).
- European Portuguese as a separate voice language (pt-PT recognizers can be a fallback, answers are pt-BR).
- Restyling any Settings view (CLAUDE.md rule). Only new options in the existing pickers.
- Changing the audio pipeline, VAD, wake-window backoff or SpotterGeneration (language-free, see Evidence).
- Windows/Tauri app, iPhone app.
- New ML models. Parakeet Ultra already covers Portuguese.

## Success criteria / stop condition

1. With the app or Mac in pt-BR and no stored voice setting, Settings → Voz shows "Você fala: Automático" and
   "Coucou responde em: Português (Brasil)"; the recognizer used is `pt-BR` (logged in `nb.log`).
2. "OK Coucou" spoken in Portuguese wakes Coucou (≥ 8/10 tries on Caio's Mac), and normal Portuguese speech
   with "ok" does not (0 wakes in a 5-minute conversation sample).
3. These pt-BR commands produce the right intent and a pt-BR answer spoken by a pt-BR voice:
   "adiciona o GitHub", "tira o Stripe", "troca o GitHub pelo Vercel", "toca música", "pausa", "próxima",
   "aumenta o volume", "quanto eu vendi hoje?", "como tá o tempo amanhã?", "abre o Figma",
   "manda um e-mail pro Tana dizendo que a imagem está pronta", "pesquisa na internet quem ganhou ontem".
4. Answers about Stripe/GitHub/Vercel/n8n/Notion/Cal.com/agents/plan/music/pills/weather are in Portuguese,
   with pt-BR money (`R$ 1.240,00`), durations ("há 3 minutos" style) and dates.
5. Claude brain on: replies in Portuguese; mail drafted in the language the user spoke.
6. Flow dictation and Notetaker transcribe Portuguese with both engines (Parakeet, Apple) and clean-up keeps
   Portuguese (no translation, Portuguese fillers removed).
7. All existing scripts pass (`test-voice-*`, `test-turn-end-policy`, `test-flow-*`, `test-notetaker`,
   `test-localization`, `test-step-language`) plus the new pt-BR cases; `xcodebuild` Debug builds.

## Evidence — what is language-dependent today

### Voice: settings and language choice
| Where | What |
|---|---|
| `NotchBuddy/Sources/App/Voice/VoiceSettings.swift:38-43` | `language` is "en" (default) or "fr"; `answerLocale` = `fr-FR` or `en-US`. |
| `VoiceSettings.swift:45-50` | `listenLanguage` "auto"/"en"/"fr". |
| `VoiceSettings.swift:52-56` | `languageOfferDone` (one-time "answer in the language you speak" offer). |
| `NotchBuddy/Sources/App/SettingsView.swift:1643-1644` | `@AppStorage("voiceLanguage") = "en"` — a **second, independent default**: must follow the new default or Settings and the engine disagree. |
| `SettingsView.swift:1726-1747` | Pickers "You speak" / "Coucou answers in": only `Français`/`English` tags (`Text(verbatim:)`). |
| `SettingsView.swift:1653-1658` | Voice sample text and locale: en/fr ternary. |
| `SettingsView.swift:1801` | Mac voice name looked up for `fr-FR`/`en-US` only. |
| `NotchBuddy/Sources/App/IslandWindowController.swift:1967-1972` | Language offer only when spoken ∈ `["fr","en"]`. |
| `Voice/LiveVoiceControls.swift:95-98` | `onLanguageSwitch` writes `VoiceSettings.language` (works for any code). |
| `NotchBuddy/Sources/App/StepLanguage.swift:10-15` | Fork precedent: Portuguese when app language is Portuguese, or first preferred language is `pt`, or region BR. Reuse this rule for the voice default. |
| `NotchBuddy/Sources/App/AppLanguage.swift:5-40` | `AppLanguage.launched == .portuguese`. |

### Voice: listening and wake
| Where | What |
|---|---|
| `Voice/VoiceEngine.swift:700-717` | `suitableLocale()`: explicit cases fr/en only; auto = `MacDictation.automaticLocales()` then `en-US`, `fr-FR`. Requires `supportsOnDeviceRecognition`; if pt-BR is not on-device available it **silently falls back to en-US** — likely part of Caio's symptom. |
| `NotchBuddy/Sources/App/MacDictation.swift:235-256` | `automaticLocales()`: Mac languages, keyboard layouts, preferred languages, then en-US (pt-BR comes first on a pt-BR Mac). |
| `Voice/VoiceEngine.swift:106` | `cancelPhrases` fr/en only. |
| `Voice/VoiceEngine.swift:501` | `audioError` literal English, shown in Settings (`SettingsView.swift:1693`), bypasses the catalog. |
| `Voice/WakePhrase.swift:40-45, 86-94` | Patterns `ok/hey + coucou` and `cou cou`; variants cuckoo/kuku/kucou/okay. Nothing for what a pt-BR recognizer writes ("okei", "oquei", "cucu", "cuco"…). |
| `Voice/WakeSpotter.swift:101` | `contextualStrings = ["Coucou","OK Coucou","okay Coucou","hey Coucou"] + pills` — language-free, keep. |
| `Voice/VoiceWakeFilter.swift`, `Voice/SpotterGeneration.swift`, `Voice/WakeWindowBackoff.swift`, `Voice/EnergyVAD.swift` | Language-free. No change. |
| `Voice/TurnEndPolicy.swift:29-56` | `conversationEndPhrases` and `extendingWords` fr/en only (used by `VoiceEngine.swift:636`, `IslandWindowController.swift:1614`). |

### Voice: intent parsing
| Where | What |
|---|---|
| `Voice/IntentParser.swift:412-420` | `normalise` lowercases and folds diacritics (é→e, ç→c, ã→a): pt tables must be written normalised ("proxima", "musica", "voce"). |
| `Voice/IntentParser.swift:636-786` | All keyword tables (politeness, interjections, infinitiveMap, pause/next/prev/volUp/volDown/playlist, pillMain/musicPill/pillAddOnly/pillRemove triggers, bare music verbs, music nouns, play prefixes) are **one union of fr+en** — language-agnostic matching, so pt is added as more entries, no language switch needed. |
| `IntentParser.swift:68, 171, 181, 308, 349, 374, 387, 402-403, 442-445, 504, 514, 568, 589-593, 610` | Inline fr/en word sets (articles, fillers, conjunctions, "à la place", places, replace/instead/only triggers). |
| `Voice/VoiceQuery.swift:28-84` | `topic(of:)` weather/service/generic words; `questionMarkers` (`:82-87`), `actionVerbs` (`:89-95`). |
| `VoiceQuery.swift:120-135, 227-346` | Mail: send verbs, mail words, file words, subject/body/instruction markers, `instructionText` leads, `looksFrench` (`:308-320`), `simpleMail` greeting (`:322-329`). |
| `VoiceQuery.swift:422-475` | `webQuery`: web words, verbs, heads, tails. |
| `VoiceQuery.swift:477-499` | `looksLikeQuestion` starters/phrases. |
| `VoiceQuery.swift:542-554` | `appToOpen`: `ouvre/ouvrir/open`. |
| `Voice/EntityResolver.swift` | Pill name matching, no language words — no change expected (verify "o GitHub", "a Stripe" are stripped by article sets). |
| `Voice/VoiceActionRunner.swift:600-660` | `cancelsMail`, `isYes`, `isNo`, `askIfIncomplete` verbs fr/en only. |

### Voice: answers
| Where | What |
|---|---|
| `Voice/VoiceQuery.swift:612-741` | `VoiceAnswer.text(_:_:french:)` — every answer through `t(fr, en)`. |
| `VoiceQuery.swift:743-791` | `serviceName` ("Météo"), `stateText(fr:)`, `weatherText(fr:)`. |
| `Voice/VoiceDataSources.swift:20-28` | `answer` → `isFrench(locale)`; everything else is English. |
| `VoiceDataSources.swift:125-163` | `money`, `ago`, `duration`, `when`, `plan` format with `fr_FR`/`en_US` only. |
| `VoiceDataSources.swift:200-209` | `openApp` messages fr/en ternary. |
| `VoiceDataSources.swift:290-296` | Open-Meteo geocode `language: fr/en`. |
| `Voice/VoiceActionRunner.swift:51, 70, 438, 481` | `VoiceInfoProviding.webAnswer(…, french: Bool)`; `answersFrench`. Stub in `tests/VoiceActionRunnerTests.swift:411`. |
| `VoiceActionRunner.swift:340-356, 609-621` | Language switch confirmations and offer text: fr/en literals. |
| `VoiceActionRunner.swift:699-714` | `localizedString(key, locale:)` reads `<code>.lproj`; all 58 `voice.*` catalog keys already have pt-BR (checked), so runner messages become Portuguese as soon as `commandLocale` is `pt-BR`. |
| `NotchBuddy/Sources/App/ClaudeService.swift:829-848` | `voiceAnswer(…, french:)`: system prompt fr or en, date locale. |
| `Voice/VoiceBrain.swift:111-133` | On-device model instructions: fr or en. |
| `VoiceBrain.swift:136-160` | `draftMail`: `looksFrench` → fr or en instructions and prompt. |
| `VoiceBrain.swift:457` | service tool locale fr-FR/en-US. |
| `Voice/ClaudeVoiceBrain.swift:112-125` | System prompt `language = fr ? "French" : "English"`, date locale. |
| `IslandWindowController.swift:1730, 2010-2011, 2038-2040` | "Je regarde."/"Let me check.", "C'est fait."/"Done.", attachment sentence: fr/en ternaries spoken and shown. |
| `Voice/VoiceCaptionManager.swift:320` | caption via `localizedString(…, answerLocale)` — fine once locale is pt-BR. |

### Voice: speaking
| Where | What |
|---|---|
| `Voice/VoiceSpeaker.swift:134-180` | `bestVoice(for:locale, gender:)` is generic (language code + region) — pt-BR works if a pt-BR voice is installed (Luciana, Felipe, Fernanda…). |
| `Voice/VoiceGenderNames.swift:10-28` | Gender by first name: en/fr names only; pt voices with unspecified gender fall into the wrong pool. |
| `Voice/ElevenLabsTTS.swift:19, 46, 70-91` | Model `eleven_flash_v2_5` (multilingual, Portuguese supported); `pick()` prefers **English** voices; no `language_code` sent. |

### Dictation
| Where | What |
|---|---|
| `NotchBuddy/Sources/App/FlowLanguages.swift:52-53` | pt-BR / pt-PT already in the translate list. |
| `NotchBuddy/Sources/App/MacDictation.swift:235-256` | Apple engine "Automatic" uses Mac languages → pt-BR on Caio's Mac. Fixed language from the mic's right-click menu. No change. |
| `NotchBuddy/Sources/App/ParakeetEngine.swift:23-24` | `AsrModelVersion.ultra` = "v3's 25 languages"; FluidAudio README: 25 European languages, Portuguese included (`Shared/TokenLanguageFilter.swift:10 case portuguese`). Auto language, no hint needed (the `language:` param of FluidAudio is a script filter, useless between Latin languages). **No model change.** |
| `NotchBuddy/Sources/App/FlowCleanup.swift:104, 157` | Prompts list fillers "euh, hum, uh, um, like, tu vois…" and a correction example in English; "answer in the language the text is in" — language-neutral otherwise. Add Portuguese fillers/correction example. |
| `NotchBuddy/Sources/App/FlowText.swift`, `FlowKeyLogic.swift`, `DictationTranscript.swift` | Language-free (FlowText formats with `Locale.current`). No change. |
| `NotchBuddy/Sources/App/NoteTaker.swift:243, 313, 368, 476-477, 504` | Speaker labels from the catalog (`notes.me`, `notes.person %lld`, pt-BR present); summary/correction prompts say "language of the transcript". No change needed. |
| Catalog | `notes.*` 48, `flow.*` 37, `hub.*` 128 keys: none missing pt-BR. |

### Tests (baseline run on 2026-10-19, all green)
`test-voice-intent` 165/165, `test-voice-query` 105/105, `test-voice-wake` 26/26, `test-turn-end-policy` ok,
`test-voice-runner` 111/111, `test-voice-gender` 9/9, `test-flow-text` ok.
Scripts compile a fixed file list with `swiftc` (e.g. `scripts/test-voice-intent.sh`: VoiceTestStubs, PillFixture,
VoiceIntent, EntityResolver, IntentParser, VoiceQuery, IntentParserTests). **Any new source file used by
IntentParser/VoiceQuery/VoiceActionRunner must be added to `test-voice-intent.sh`, `test-voice-entity.sh`,
`test-voice-query.sh`, `test-voice-runner.sh`.**

## Design: small seams, Portuguese in its own files

- **`VoiceLang`** (new `Voice/VoiceLanguage.swift`, pure Foundation): `enum VoiceLang: String { case en, fr, pt }`
  with `init(code:)` ("pt", "pt-BR", "pt_BR" → .pt; unknown → .en), `init(locale: Locale?)`, `locale`
  (en-US / fr-FR / pt-BR), `formatLocale` (en_US / fr_FR / pt_BR), `englishName`, and
  `static func defaultCode(appPortuguese: Bool, preferred: [String], region: String?) -> String`
  ("pt" when app language is Portuguese, first preferred language starts with "pt", or region BR; else "en" —
  same rule as `StepLanguage.choose`, but en instead of fr as the non-pt default, matching upstream).
  Also `static func detect(_ text: String) -> VoiceLang` (word-count heuristic over fr/en/pt stop-words,
  generalising `VoiceQuery.looksFrench`) for mail language.
- **`VoicePT`** (new `Voice/VoicePortuguese.swift`): pt-BR word tables consumed by IntentParser, VoiceQuery,
  TurnEndPolicy. Upstream files only get `… + VoicePT.xxx` on the table that needs it.
- **`VoiceAnswerPT`** (new `Voice/VoiceAnswerPT.swift`): `extension VoiceAnswer { static func text(_:_:lang:) }`
  that dispatches `.pt` to a full Portuguese switch and en/fr to the existing `text(_:_:french:)`;
  plus `stateTextPT`, `weatherTextPT`. The upstream answer function stays untouched; a new upstream topic
  breaks the exhaustive pt switch at compile time (good merge signal).
- Stored codes stay short: `voiceLanguage` / `voiceListenLanguage` ∈ "en" | "fr" | "pt" (| "auto").

## Phased task breakdown

Each task lists the files it owns. Within a wave no two tasks own the same file. Executors: Sonnet,
Feature Implementation Loop, no commits (git is MAIN's).

### Phase 1 — must-have (Caio uses voice and dictation in pt-BR end to end)

#### Wave A (one executor, first; everything else depends on it) — ~9 files
**A1. Language seam and default**
- New `Voice/VoiceLanguage.swift` (`VoiceLang` as above).
- New stubs `Voice/VoicePortuguese.swift` (`enum VoicePT {}` with empty tables declared, see B2) and
  `Voice/VoiceAnswerPT.swift` (`extension VoiceAnswer { static func text(_ t: VoiceTopic, _ s: VoiceSnapshot, lang: VoiceLang) -> String { text(t, s, french: lang == .fr) } }`) so B tasks only fill them in.
- `Voice/VoiceSettings.swift`: `language` getter default = `VoiceLang.defaultCode(appPortuguese: AppLanguage.launched == .portuguese, preferred: <system AppleLanguages>, region: Locale.current.region?.identifier)` when the key is unset (do not overwrite a stored value); `answerLocale` = `VoiceLang(code: language).locale`; add `static var lang: VoiceLang`; doc comments mention pt.
- Wire the three new files into `scripts/test-voice-intent.sh`, `test-voice-entity.sh`, `test-voice-query.sh`, `test-voice-runner.sh` (before the files that use them).
- New `tests/VoiceLanguageTests.swift` + `scripts/test-voice-language.sh` (init(code:), locale, defaultCode cases mirroring `tests/StepLanguageTests.swift`, detect()).
- Done when: all existing voice scripts still pass unchanged, new script passes, app builds.

#### Wave B (parallel after A1) — each task independent
**B1. Listening, wake, turn end** — owns `Voice/VoiceEngine.swift`, `Voice/WakePhrase.swift`, `Voice/TurnEndPolicy.swift`, `tests/WakePhraseTests.swift`, `tests/TurnEndPolicyTests.swift`, `tests/VoiceConversationTests.swift` (only if it asserts end phrases), `NotchBuddy/Resources/Localizable.xcstrings` (only task in Phase 1 that edits the catalog). ~7 files
- `suitableLocale()`: `case "pt": [pt-BR, pt-PT]`; final fallback list becomes `[VoiceSettings.lang.locale, en-US, fr-FR]` (answer language before English). Log once per session `"[Voice] listening in <id> (wanted <listenLanguage>)"`; if wanted pt but got another locale, log `pt-BR recognizer not available on-device` (diagnoses the silent en-US fallback).
- `cancelPhrases` += "cancela", "cancelar", "deixa pra la", "deixa para la", "esquece".
- `WakePhrase.normWord`: single-token maps only — "okei"/"oquei"→"ok"; "cucu", "cuco", "cocu"→"coucou" ("kuku" exists); patterns add `["ei","coucou"]` (the pt recognizer's "hey"). Do **not** add a `["o","que",…]` pattern or map "coco"/"cocô" (see Risks, Q2).
- `TurnEndPolicy.conversationEndPhrases` += "obrigado", "obrigada", "valeu", "e isso", "so isso", "pode parar", "cancela", "deixa pra la", "tchau", "ate mais" (normalised). Never add bare "para" (preposition). `extendingWords` += "e", "mas", "ou", "entao", "depois", "tipo", "ne", "hum", "ahn", "o", "os", "as", "um", "uma", "do", "da", "dos", "das", "no", "na", "em", "com", "pra", "para", "pro", "adiciona", "tira", "remove", "coloca", "bota", "toca", "liga", "desliga", "aumenta", "abaixa", "diminui". Check each against existing tests ("a" already present; "e" is a new single letter — verify it does not lengthen common en/fr endings unduly; it's only the *last* word).
- `audioError` stall literal → `String(localized: "voice.error-stalled")` with en/fr/pt-BR (and the 8 other languages left absent, per test-localization rule) in the catalog.
- Tests: WakePhraseTests pt cases ("Okei Coucou adiciona GitHub", "ok cucu toca música", "ok, tudo bem" must not match); TurnEndPolicyTests pt end phrases and extending words.

**B2. Intent parsing pt vocabulary** — owns `Voice/VoicePortuguese.swift`, `Voice/IntentParser.swift`, `Voice/VoiceQuery.swift` (detection part only: lines 1-560; the answer section is not edited), `tests/IntentParserTests.swift`, `tests/VoiceQueryTests.swift`, `tests/EntityResolverTests.swift`. ~6 files
- `VoicePT` tables (normalised), appended with `+ VoicePT.x` to each upstream table:
  - politeness: "voce pode", "pode", "voce poderia", "poderia", "eu quero que voce", "queria que voce", "por favor", "tem como".
  - interjections: "obrigado", "valeu", "beleza", "entao", "tipo", "ne", "ahn", "hum", "opa", "e ai", "sim", "pois e".
  - infinitiveMap: adicionar→adiciona, colocar/botar→coloca, tirar→tira, remover→remove (en already), tocar→toca, ativar→ativa, desativar→desativa, trocar/substituir→troca, mostrar→mostra, esconder→esconde, aumentar→aumenta, abaixar/diminuir→abaixa, pausar→pausa, parar→para*(only in multi-word pause prefixes), pular→pula, abrir→abre; subjunctive after "quero que voce": adicione→adiciona, tire→tira, coloque→coloca, toque→toca, ative→ativa, troque→troca, abra→abre.
  - pause: "pausa", "pausar", "pausa a musica", "para a musica", "para de tocar", "para a musica ai"; next: "proxima", "proxima musica", "pula", "pular", "passa", "avanca"; prev: "anterior", "musica anterior", "volta", "volta a musica"; volUp: "aumenta o som", "aumenta o volume", "mais alto", "sobe o volume"; volDown: "abaixa o som", "abaixa o volume", "diminui o volume", "mais baixo"; playlist: "toca a playlist", "coloca a playlist", "bota a playlist"; pillMain: "muda para", "troca para", "usa", "coloca como principal"; musicPill: "toca", "coloca", "bota", "liga"; pillAddOnly: "adiciona", "ativa", "mostra", "inclui", "acrescenta", "eu quero"; pillRemove: "tira", "remove" (dup ok), "desativa", "esconde", "apaga", "exclui", "nao preciso mais de"; bare music: "toca", "tocar"; music nouns: "musica", "som", "cancao", "musicas"; play prefixes: "toca musica", "toca uma musica", "coloca uma musica", "bota um som", "continua a musica".
  - inline sets: articles += "o", "a", "os", "as", "do", "da", "dos", "das", "um", "uma", "no", "na"; fillers += "meu", "minha", "o", "a"; conjunctions += "e", "depois", "entao"; "instead" tail += ["no", "lugar"]; places += "pilulas", "pilula", "notch", "barra"; replace triggers += "troca", "substitui"; instead-of markers += ["no","lugar","do"], ["no","lugar","da"], ["em","vez","de"], ["em","vez","do"], ["pelo"], ["pela"] (as in "troca o GitHub pelo Vercel"); only: ["deixa","so"], ["mantem","so"], ["so","deixa"].
  - VoiceQuery: weather += "tempo", "previsao", "vai chover", "chover", "chuva", "guarda chuva", "temperatura", "calor", "frio", tomorrow += "amanha"; generic sales += "vendi", "vendas", "venda", "faturamento", "faturei", "receita", "dinheiro", "saldo", "pagamentos"; github += "estrelas", "estrela"; vercel += "deploy", "implantacao", "publicacao"; calcom += "reuniao", "reunioes", "agenda", "compromisso", "compromissos"; quota += "limite", "cota", "uso"; music += "musica", "tocando", "cancao"; pills += "pilula", "pilulas"; agents phrases += "o que esta acontecendo", "o que ta rolando", "como esta"; questionMarkers += "quanto", "quantos", "quantas", "qual", "quais", "como", "o que", "me diz", "me mostra", "tem", "status", "esta", "ta"; actionVerbs += pt verbs above + "manda", "envia", "escreve", "abre".
  - Careful: "como" and "tem"/"ta" are frequent; questionMarkers only matter after `actionVerbs` filtering and with a service/generic word, same as fr "comment". Keep "e" **out** of questionMarkers.
  - Mail: send verbs += "manda", "mandar", "envia", "enviar", "escreve", "escrever"; mail words += "e mail", "email", "emeil"; file words += "arquivo", "imagem", "foto", "documento", "print"; subject markers += "com o assunto", "assunto", "titulo"; body markers += "dizendo que", "dizendo", "falando que", "com o texto", "o texto"; instruction markers += "dizendo que", "dizendo", "falando que", "pra dizer que", "para dizer que"; recipient "pro"/"pra"/"para o"/"para a" handling in `mail(of:)`.
  - `looksFrench` stays; add `VoiceQuery.mailLanguage(_:) -> VoiceLang` = `VoiceLang.detect`; `simpleMail` uses it: pt → "Olá,\n\n…\n\nAbraço!".
  - webQuery: web words += " internet ", " na internet ", " no google "; verbs += "pesquisa", "pesquisar", "procura", "procurar", "busca", "buscar", "ve", "olha"; heads += ["voce","pode"], ["pode"], ["pesquisa","na","internet"], ["pesquisa"], ["procura"], ["busca"], ["sobre"], ["pra","mim"]; tails += ["na","internet"], ["no","google"], ["online"], ["por","favor"], ["pra","mim"], ["obrigado"].
  - looksLikeQuestion starters += "quem", "quando", "onde", "por que", "porque", "qual", "quais", "quanto", "como", "o que"; phrases += "o que e", "me fala", "me conta", "me explica"; requests += "voce pode", "pode", "voce poderia".
  - appToOpen verbs += "abre", "abrir", "abra"; skip words += "o", "a", "app", "aplicativo".
- Tests: ≥ 40 new pt cases across IntentParserTests (one per table family, multi-action "adiciona GitHub e tira Stripe", replace "troca o GitHub pelo Vercel", "tira a pílula do Stripe"), VoiceQueryTests (topics, mail, web, question, app), EntityResolverTests ("o GitHub"). Every existing en/fr case unchanged and passing.

**B3. Answers, formatting, runner, web answer** — owns `Voice/VoiceAnswerPT.swift`, `Voice/VoiceDataSources.swift`, `Voice/VoiceActionRunner.swift`, `NotchBuddy/Sources/App/ClaudeService.swift` (only `voiceAnswer`), `tests/VoiceActionRunnerTests.swift`, `tests/VoiceTestStubs.swift` (if needed). ~6 files
- `VoiceAnswerPT`: full pt-BR switch for every `VoiceTopic` (informal "você", short sentences, e.g. "Hoje: R$ 320,00 em 4 pagamentos. Saldo: R$ 1.240,00.", "O último deploy de X está no ar, há 3 minutos.", "Amanhã em São Paulo: chuva, de 18 a 25 graus."), `stateTextPT`, `weatherTextPT`, service name "Tempo" for weather.
- `VoiceDataSources`: replace `isFrench` use by `VoiceLang(locale:)`; `snapshot(for:lang:)`; `money/ago/duration/when/plan` take `lang: VoiceLang` and use `lang.formatLocale` (keep `fr:` overloads only if other callers exist — grep first); `answer` calls `VoiceAnswer.text(topic, snap, lang:)`; `openApp` pt messages ("Abrindo o X." / "Não encontrei o app X."); geocode `language: "pt"`.
- `VoiceActionRunner`: `VoiceInfoProviding.webAnswer(_:history:lang:)` (rename param; update the stub at `tests/VoiceActionRunnerTests.swift:411` and the conformance in VoiceDataSources); `answersFrench` → `answerLang`; switchLanguage yes/no confirmations and `offerLanguageSwitch` for pt ("Quer que eu responda em português?", "Beleza, agora respondo em português.", "Ok, continuo em português."), current-language phrasing for all 3×3 combinations; `isYes` += "sim", "claro", "pode", "pode ser", "beleza", "bora", "com certeza", "uhum", "quero"; `isNo` += "nao", "nao precisa", "deixa", "deixa assim", "mantem", "fica"; `cancelsMail` += "cancela", "cancelar", "deixa pra la", "esquece", "para"; `askIfIncomplete` verbs += "adiciona", "adicionar", "ativa", "coloca" / "tira", "remove", "remover", "desativa", "apaga"; `commandLocale = VoiceLang(code: lang).locale`.
- `ClaudeService.voiceAnswer(_:history:lang:)`: pt system prompt (same rules as fr/en, "em português do Brasil"), date with `pt_BR`.
- Tests: runner pt cases (answer in pt-BR for pills/music when `commandLocale = pt-BR` — catalog lookup needs the lproj bundle; if the script cannot load it, assert the key path instead), yes/no/cancel pt, language-switch pt flow, `VoiceAnswer.text(…, lang: .pt)` for every topic in `tests/VoiceQueryTests.swift`? **No — that file is B2's.** Put answer tests in a new `tests/VoiceAnswerPTTests.swift` + `scripts/test-voice-answer-pt.sh` (compiles VoiceLanguage, VoiceIntent, EntityResolver, IntentParser, VoiceQuery, VoiceAnswerPT, VoicePortuguese).

**B4. Brains and island phrases** — owns `Voice/VoiceBrain.swift`, `Voice/ClaudeVoiceBrain.swift`, `NotchBuddy/Sources/App/IslandWindowController.swift` (lines ~1730, ~1967, ~2010, ~2038 only). ~3 files
- `VoiceBrain.instructions()`: pt branch (Portuguese translation of the fr text). `draftMail`: language by `VoiceLang.detect(instruction)` → pt instructions/prompt ("E-mail para X. O que eu quero dizer: …"). Line 457 → `VoiceSettings.answerLocale`.
- `ClaudeVoiceBrain.systemPrompt()`: `language = VoiceSettings.lang.englishName` ("Brazilian Portuguese"), "(the user may speak Portuguese, French or English)", date locale `VoiceSettings.lang.formatLocale`.
- `IslandWindowController`: "Deixa eu ver." / "Pronto." / "X está anexado. É só clicar em Enviar." via a 3-way switch on `VoiceSettings.lang`; offer condition `["fr","en","pt"].contains(spoken)`.
- Verification: build only (no script covers these files); manual in Phase 1 verification.

**B5. Speaking** — owns `Voice/VoiceGenderNames.swift`, `Voice/ElevenLabsTTS.swift`, `tests/VoiceGenderTests.swift`. ~3 files
- Gender names: female += "luciana", "fernanda", "joana", "catarina", "francisca", "ines"; male += "felipe", "joaquim", "rafael", "tiago". Verify against `AVSpeechSynthesisVoice.speechVoices()` on Caio's Mac (`say -v '?' | grep pt_`), add what is installed.
- ElevenLabs: `pick(_:gender:language:)` prefers voices whose `labels.language` starts with the answer language (or accent "brazilian"/"portuguese" for pt), falls back to today's English rule; send `"language_code": "pt"` with `eleven_flash_v2_5` when answering in pt (supported by the v2.5 models). Cache key must include the language (today `chosen = (gender, v)`).
- Tests: gender names pt; `pick` pure function cases (pt voice preferred; none → English path unchanged).

**B6. Settings UI** — owns `NotchBuddy/Sources/App/SettingsView.swift` (voice section only). 1 file
- Both pickers: add `Text(verbatim: "Português (Brasil)").tag("pt")` next to the existing two (same style, same order logic: put it after Français/English or first — keep the existing two rows untouched).
- `@AppStorage("voiceLanguage")` default: use `VoiceSettings.language` value at init (e.g. `= VoiceSettings.language`), so an unset key shows the computed default instead of "en".
- `speakVoiceSample()`: 3-way: pt "Oi, eu sou o Coucou. Diz OK Coucou quando precisar de mim." with `pt-BR`.
- Line 1801: `VoiceLang(code: voiceLanguage).locale`.
- `onChange(of: voiceLanguage)` unchanged (already sets offer done and restarts).

**B7. Dictation clean-up** — owns `NotchBuddy/Sources/App/FlowCleanup.swift`. 1 file
- Filler list in both prompts (`:104`, `:157`): add "é…, hã, né, tipo, sabe, então (as filler)". Correction example: add the pt form ("às 3, não, às 4"). No other change (language rules already neutral).
- Verification: `scripts/test-flow-text.sh`, `scripts/test-flow-keys.sh` still pass; manual dictation in pt (both engines) with clean-up on and off.

#### Wave C (after B) — MAIN-dispatched verification
**C1. Full verification** (tester, no source edits): all `scripts/test-*.sh` listed in Verification, `xcodebuild` Debug, `scripts/test-localization.sh`; manual checklist on Caio's Mac (below). Hera review (Medium risk) before commit.

### Phase 2 — nice-to-have
- **P2-1 Wake-word tuning from real logs**: opt-in debug log of raw wake-window transcripts (local `nb.log`, never network) to collect what the pt-BR recognizer writes for "OK Coucou"; add the observed variants with tests. Owns `Voice/WakeSpotter.swift`, `Voice/WakePhrase.swift`. 2 files.
- **P2-2 First-run offer for existing installs**: if `voiceLanguage` is stored "en" and the Mac/app is pt, offer once (reusing `offerLanguageSwitch(to: "pt")`, separate key `voiceLanguagePtOfferDone`). Owns `IslandWindowController.swift`, `VoiceSettings.swift`. 2 files. Depends on Q1.
- **P2-3 Settings hint when pt-BR on-device recognition is missing**: a one-line caption under "Você fala" (existing caption style) linking to System Settings → Keyboard → Dictation to download Portuguese. Owns `SettingsView.swift`, catalog. 2 files.
- **P2-4 pt-PT answers** (`pt-PT` answerLocale variant) — only if asked.
- **P2-5 SPEC/README**: `docs/SPEC.md` voice section note "en, fr, pt-BR" (French text) and CHANGELOG entry at release time.

## Verification strategy

Automated (each task runs the scripts touching its files; C1 runs all):
```
bash scripts/test-voice-language.sh      # new (A1)
bash scripts/test-voice-intent.sh
bash scripts/test-voice-entity.sh
bash scripts/test-voice-query.sh
bash scripts/test-voice-runner.sh
bash scripts/test-voice-answer-pt.sh     # new (B3)
bash scripts/test-voice-wake.sh
bash scripts/test-turn-end-policy.sh
bash scripts/test-voice-conversation.sh
bash scripts/test-voice-gender.sh
bash scripts/test-voice-wake-blocked.sh scripts/test-voice-spotter-gen.sh scripts/test-voice-backoff.sh scripts/test-voice-vad.sh scripts/test-voice-island.sh
bash scripts/test-flow-text.sh scripts/test-flow-keys.sh scripts/test-notetaker.sh
bash scripts/test-step-language.sh
bash scripts/test-localization.sh
cd NotchBuddy && xcodegen && xcodebuild -scheme NotchBuddy -configuration Debug build
```
Baseline counts must not drop (165 / 105 / 26 / 111 / 9 …): only additions.

Manual on Caio's Mac (`./scripts/dev-install.sh`, app language pt-BR):
1. Fresh defaults (`defaults delete fr.louisraille.NotchBuddy voiceLanguage voiceListenLanguage voiceLanguageOfferDone`) → Settings shows Português; `nb.log` says listening in pt-BR.
2. Success-criteria commands (list above), with Claude brain off then on.
3. 5 minutes of normal Portuguese talk near the Mac with voice on → no wake.
4. TTS: system voice (Luciana/Felipe) female/male, then ElevenLabs.
5. Flow: hold the key, dictate a Portuguese sentence with "é… tipo… né" and a self-correction, with Parakeet and with Apple engine; Flow translate to English still works.
6. Notetaker: 1-minute Portuguese recording → transcript and summary in Portuguese.
7. Regression: switch answer language to Français and English, repeat 3 commands each.
8. Activity Monitor: 0 % CPU with island hidden and voice off (unchanged pipeline).

## Risks

| Risk | Mitigation |
|---|---|
| Wake false positives: "ok" is very common in pt-BR speech; mapping "coco"/"cocô"/"o que" would fire on normal sentences. | Map only rare tokens (cucu, cuco, cocu, okei/oquei→ok, ei+coucou); require the 2-token pattern; negative tests ("ok, tudo bem", "ok, o que você acha", "coco ralado"); P2-1 log-driven tuning. |
| pt-BR on-device recognizer not installed → silent en-US fallback (`VoiceEngine.swift:712` requires `supportsOnDeviceRecognition`). | Log it (B1), Settings hint (P2-3), manual step 1. Do not drop the on-device requirement (privacy rule: no audio to Apple in a language not chosen). |
| Shared word tables: pt words colliding with fr/en meaning ("para" = stop/for, "e" = and/is, "passa", "tem", "como", "mais"). | Never add bare "para"/"e" as commands or question markers; multi-word sequences for pause; all existing en/fr tests must pass; add pt negative cases. |
| Two defaults for `voiceLanguage` (VoiceSettings vs `@AppStorage` in SettingsView). | B6 binds the AppStorage default to `VoiceSettings.language`; test in manual step 1. |
| Merge friction with upstream (Voice files churn often). | Portuguese lives in 3 new files; upstream files get one-line seams (`+ VoicePT.x`, `lang:` param); answer switch not edited. Signature change `french:`→`lang:` in `VoiceInfoProviding`/`ClaudeService.voiceAnswer`/`VoiceDataSources` formatters is the main conflict surface — keep it in one commit so it can be re-applied. |
| Performance (0 % CPU hidden). | No pipeline change; tables are static lets; `defaultCode` read only when the key is unset (cache not needed, cheap). |
| ElevenLabs voice language labels vary. | Fallback to current English rule; cache keyed by language. |
| Catalog: test-localization requires all-or-none of the 8 upstream languages. | New keys get en + fr + pt-BR only (fork style), none of the other 8. |

## Open questions for Caio (recommended defaults)

1. **Existing installs that already stored "en"** (via Settings or the offer): switch them to pt automatically?
   *Default: no automatic overwrite; the new default applies only when unset, and P2-2 offers once by voice.* Caio
   can also just pick Português in Settings.
2. **Wake variants**: accept "OK Coco"/"OK Cocô" as wake phrases if his recognizer writes that?
   *Default: not in Phase 1; decide from P2-1 logs.*
3. **Tone of answers**: informal "você"/"tá" style like the fr "tu"? *Default: informal, short, standard
   spelling ("está", not "tá", in written captions).*
4. **Listening "Automatic"** on a Mac with pt and en: today the first Mac language wins. *Default: keep.*

## Files per phase (estimate)

| Phase | Tasks | Files (new + edited) |
|---|---|---|
| 1 / Wave A | A1 | 3 new sources + 1 new test + 1 new script; edits VoiceSettings + 4 scripts → ~10 |
| 1 / Wave B | B1–B7 | ~27 (B1 7, B2 6, B3 6 + 2 new, B4 3, B5 3, B6 1, B7 1) |
| 1 / Wave C | C1 | 0 source edits |
| 2 | P2-1…P2-5 | ~8 |
