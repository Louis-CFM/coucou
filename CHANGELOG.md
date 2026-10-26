# Changelog

## Unreleased

- **Mac: WhatsApp statuses aren't chats** — a contact's WhatsApp Status and channel posts no longer show up as a conversation in the WhatsApp pill (#901, same fix as #910)

## Windows and Linux 0.5.3 — October 22, 2026

WhatsApp comes to Windows and Linux, as on the Mac.

- **WhatsApp in the island** *(experimental)* — your incoming WhatsApp messages in a green pill, one row per conversation with initials, name, the last message and the unread count; photos, voice messages and documents show as a label. Click a conversation to read its last ten messages and reply: Enter sends, Shift+Enter starts a new line, Esc goes back. Mochi smiles at a new message. Groups stay quiet unless you're mentioned, chats you ignore never show, and read receipts go only when you open a conversation or reply. Off by default: Settings → Integrations → WhatsApp
- **Install WhatsApp in one click** — Coucou downloads GOWA, the open-source gateway, from its GitHub page, checks it against the SHA-256 GOWA publishes, starts it on this computer only and shows the QR code to scan; **Update** fetches GOWA's latest version, and your own GOWA or OpenWA goes under **Advanced**. Messages stay in memory, are never logged or saved, and are forgotten when Coucou quits. Use it on your own account only: WhatsApp may restrict accounts that abuse it
- **Statuses aren't chats** — a contact's WhatsApp Status and channel posts no longer show up as a conversation in the pill (#910 by @afpruivo, reported by @orphic07 in #901)
- **Mochi stays whole on another monitor** — moving the island or Mochi on the desktop to a screen with another scale no longer cuts him off or blurs him; the mini Mochis and the wardrobe follow too (#892 by @ZouaouiB, tested on two monitors by @afpruivo; fixes #344)

## Android 0.3.0 — October 22, 2026

- **Coucou for Android 0.3.0**, by @Rhytam23 — a bigger release (versionCode 3). It works with Coucou 0.5.0 or later on Windows and Linux; the weekly recap needs Coucou 0.5.2 on Windows or Linux.
  - **Clearer link** — Home names the likely cause when the computer is out of reach (computer closed, other network, phone link off); predictive back; the ongoing notification is updated only when its text changes.
  - **Permission requests** — choose the vibration (default, short, off) and whether a request wakes the screen (off by default). Allow still needs your fingerprint or screen lock, and approvals are never muted or hidden.
  - **Look** — a light theme (System, Light, Dark) and the phone's own colours on Android 12 and later; Reduce motion, TalkBack in words, large text and 48 dp touch targets.
  - **Nine more languages** — French, Spanish, Brazilian Portuguese, Simplified Chinese, Hindi, Bengali, Russian, Indonesian and Arabic (right to left), with a language picker.
  - **Quick actions** — launcher shortcuts (Chat, Recent decisions, Pair again), a Team widget, and Share to Coucou (the text lands in the chat box and is never sent).
  - **Weekly recap and history** — last week's counts on Home (optional, off by default, behind its own switch on the computer), search and export of recent decisions as text, and a per-agent mute for finished, failed and limit notices (requests and questions are never muted).
  - Fixes #629: the *Away from home Wi-Fi* section only shows when the pairing carries a relay (#682 by @Rhytam23)

## 0.5.3 — October 22, 2026

Mochi tells you a new version waits, and after the update he shows you what it brings.

- **Mochi turns blue when a new version waits** *(macOS, GitHub build)* — once you agreed to look for updates, a newer Coucou turns Mochi blue with a little up arrow whenever he has nothing else to tell you, in the notch and in the menu bar, and opening the notch shows **Update now** first (it is also the first line of the menu). Later hides it for a day. Approvals and questions always come first
- **What's new, after the update** — once Coucou updated itself, the notch shows what the new version brings (with an icon each, in your language), then *Your Coucou so far*: agent sessions, time with your agents, lines written, approvals from the notch, words dictated and time saved with Flow, calls transcribed. All of it is counted on your Mac and never leaves it
- **Buy Mochi a coffee** — Coucou stays free and open source; if it saves you time, the last step of What's new has a coffee for Mochi (Stripe, the same page as Coucou's website)

## Windows and Linux 0.5.2 — October 22, 2026

- **Mochi turns blue when a new version waits** — once you agreed to look for updates, a newer version turns Mochi blue with a little up arrow, in the island and in the tray, and opening the island shows **Update now** first. Later hides it for a day. Approvals and questions always come first
- **What's new, after the update** — the island shows once what the new version brings, then *Your Coucou so far* (counted on your computer, never sent) and **Buy Mochi a coffee**
- **GitLab and Gitea** — two new pills like GitHub's: open merge and pull requests, reviews asked of you, the default branch's CI and your activity, for gitlab.com or your own instance; tokens stay in the system's credential store (#831 by @Andrey89711, from #591 and #585)
- **Weekly recap on Coucou for Android** — Settings → Android phone → *Show my weekly recap on the phone*: last week's counts only, off by default (#682 by @Rhytam23)

## 0.5.2 — October 20, 2026

New versions now come to you: Mochi says it in the notch and one click installs it. Plus four new languages and a round of community work.

- **New version in the notch** *(macOS, GitHub build)* — Coucou asks once whether it may look at its releases on GitHub; then, a few times a day, Mochi tells you when a new Coucou is out: **Update now**, What's new, Later. The click downloads it from GitHub, checks it is Coucou at the announced version, signed with its developer's Developer ID and notarized by Apple, swaps the app and restarts. Also in the menu bar and in Settings → General → Updates (Check now). Nothing is checked before you say yes, and nothing about you is sent
- **Four new languages** — German and Turkish (by @Ohualtex), Thai (by @XBalanceZ) and Traditional Chinese (by @shawn-t516): 14 languages in Settings → General → Language
- **Homebrew** — `brew tap louis-cfm/coucou https://github.com/Louis-CFM/coucou`, then `brew install --cask coucou` (#340 by @espensgr)
- **Plan approval from the notch** — when Claude Code has a plan ready, the card offers the terminal's own choices: Auto mode, Manual, or Change plan, which brings the terminal forward to type the change (#703 by @orrrrli)
- **The pill's name** — a Claude Code session's pill is named after its `/rename` title, else the folder it started in (no longer the subfolder it moved into), and with several sessions it follows the one that is working (#761 by @orrrrli)
- **Quiet when you're watching** — a turn that ends while its terminal is in front only takes a badge: no sound, no reveal (#719 by @orrrrli)
- **Alerts from every pill** — Settings → General → Behavior → *Open for every pill's alerts*: another pill that finishes or fails opens the notch for a moment, then the pill you had comes back (#683, asked by @Arochell). Off by default
- **Claude Desktop chats** *(GitHub build, experimental)* — Mochi jumps when a regular chat reply is ready in the Claude app, while you're elsewhere (#686, idea by @GreGCerisier). Settings → Agents → Claude Desktop chats, off by default; it uses Accessibility and reads nothing of the chat
- **Antigravity questions** — when Antigravity asks you something, its pill says so with a sound (#709 by @Ohualtex, #690)
- **Conductor** — Claude Code sessions run from Conductor land on the Claude Code pill, and Open terminal brings Conductor forward (#793, asked by @victorlohezic)
- DeepSeek, Qwen and Moonshot chats work again: streaming sent the wrong key (#803 and #730 by @itgoodojo, fix from #667 by @pedrozampiroli)

## Windows and Linux 0.5.1 — October 20, 2026

- **New version in the island** — Coucou asks once whether it may look at its releases on GitHub, then tells you when a new one is out. On Windows, **Update now** downloads the installer that matches how you installed Coucou (setup.exe or MSI), checks its SHA-256 against the one GitHub publishes, installs it and comes back by itself; the portable exe and Linux get the release page. Settings → General → Updates and the tray menu too (#812, plan by @afpruivo)
- **German and Turkish** (by @Ohualtex): 12 languages
- **Optional clock** in the middle of the compact island, for the place a Mac has its notch: Settings → General → Show clock in the island (#788 by @eduardo-qts)
- **Antigravity questions** — the pill turns to a question with a sound and the island shows up (#709 by @Ohualtex)
- **Linux**: the Coucou window no longer keeps a core busy once closed, on KDE and other desktops whose webview doesn't report it hidden (#792, reported by @Michael-1103)
- The island's error view shows the real error and who stopped

## 0.5.1 — October 18, 2026

- **WhatsApp in one click** *(macOS, GitHub build)* — no more GitHub, zip or Terminal: Settings → Integrations → WhatsApp → **Install WhatsApp**. Coucou downloads GOWA, the open-source gateway, for your Mac (about 15 MB, once), checks it against the SHA-256 GOWA publishes, starts it, and shows the QR code to scan. It starts and stops with Coucou, and **Update** fetches GOWA's latest version. Your own gateway (GOWA by hand, OpenWA, another address) moves under **Advanced**
- GOWA started by Coucou no longer fetches its own web dashboard from GitHub at each start (Coucou is the interface)

## 0.5.0 — October 18, 2026

WhatsApp in the notch, Mochi who feels your Mac, a screen capture for Claude, and dictation that writes prompts or translates. All of it free and open source.

- **WhatsApp in the notch** *(macOS, GitHub build, experimental)* — your incoming WhatsApp messages in a new green pill, one row per conversation with initials, name, the last message and the unread count; photos, voice messages and documents show as a label. Click a conversation to see its last ten messages and reply: Return sends, Shift-Return starts a new line, Esc goes back. Mochi smiles at a new message (with a sound if sounds are on). Groups stay quiet unless you're mentioned, chats you ignore never show, and read receipts go only when you open a conversation or reply. It goes through an unofficial gateway that runs on your Mac ([GOWA](https://github.com/aldinokemal/go-whatsapp-web-multidevice), or [OpenWA](https://github.com/rmyndharis/OpenWA)), which Coucou can start and stop for you; scan its QR code right in Settings → Integrations → WhatsApp. Nothing leaves your Mac: messages stay in memory, are never logged or saved, and are forgotten when Coucou quits. Use it on your own account only: WhatsApp may restrict accounts that abuse it. Off by default; see [WhatsApp (experimental)](README.md#whatsapp-experimental)
- **Mochi feels your Mac** — under full processor load he panics (hops, trembling eyes, sweat), he flushes when the Mac is warm, puffs up when memory is short, gets heavy eyelids under 20 % battery and falls asleep under 10 %; plugging in wakes him. Point at Mochi to see why ("CPU 94 % · node, Google Chrome"). Read only while Mochi is on screen. Settings → General → Mochi and your Mac
- **Screen capture for Claude** *(macOS, GitHub build)* — ⌃⌥X: select part of the screen, Mochi swallows the image, then Paste (⌘V, or ⌃V in a terminal where Claude Code takes images), Copy, Annotate (arrows, boxes, pen) or Ask Claude. With a capture on the island, holding the Flow key pastes the image, then your words
- **Flow: prompt mode and translation** *(macOS, GitHub build)* — what you say can become a structured prompt for an agent (goal, context, steps, constraints), or be pasted in another language: about 70 languages and regional variants. One Claude call with your key; if it's late, your words are pasted as heard. Coucou → Flow → Settings
- **Notetaker** — the other person's voice coming back through your speakers is no longer written as yours, one voice is no longer split into two persons, and Claude fixes misheard words and keeps the names it learns for your next calls. Any line can be edited or given to another person
- **iPhone** — a request you open from a notification now says whether it expired or was already answered on your Mac
- The island's error view shows the real error and who stopped (Claude Code, an agent or n8n), with buttons that work; no false "your words are copied" after dictating into Electron apps; the Coucou window's sidebar is centred

## Windows and Linux 0.5.0 — October 15, 2026

Windows and Linux catch up with the Mac's 0.3.0 and 0.4.0: the Coucou window, Flow dictation, the Notetaker and « OK Coucou ». All of it free and open source.

- **Coucou, the app** — Coucou now has its own window and sits in the taskbar. On the left, **Flow** (Dictation, Notetaker, Statistics, Dictionary, Snippets, Styles, Settings), then **Notch** (General, Active pills, Agents, Chat, OK Coucou, Integrations, Android phone, Shortcuts): the settings you had, in the same place as on the Mac, with the little Mochis walking around each page. It opens when you launch Coucou yourself, not when it starts with your computer (Flow → Settings → App)
- **Flow dictation** — hold a key anywhere (right Ctrl by default, or right Alt, right Shift, Ctrl + Win / Ctrl + Super), speak, let go: your words are pasted where you type. Two quick taps keep it listening hands-free until the next tap; Esc cancels; the pill's toolbar pastes the last dictation again. Clipboard history managers leave the dictation out and the clipboard gets back what it held. Off by default. On Linux it works on X11 and on Wayland: there the desktop holds the key for Coucou through its shortcuts portal (Ctrl+Alt+V unless you pick others) and the first paste asks once to let Coucou type for you
- **Parakeet, on your computer** — dictation, the Notetaker and « OK Coucou » run on NVIDIA's Parakeet through [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx), on the CPU: accurate, offline, 25 languages. Nothing is downloaded until you click Download (about 700 MB, once, checked against its SHA-256)
- **The pill** — the same see-through pill as on the Mac, at the bottom of the screen or on its left or right edge: hover it for the toolbar (dictate, record a call, open Coucou), Mochi and nine dots that follow your voice while you speak, messages in a bubble next to it
- **Your words, your way** — Dictionary, Snippets, Styles per app (an optional clean-up by Claude with your own key) and Statistics, as on the Mac. The history stays on your computer, kept as long as you choose
- **Notetaker** — click Record a call: Coucou records your microphone and what the computer plays (WASAPI loopback on Windows, the PulseAudio or PipeWire monitor on Linux; no bot joins the call), shows the words live, then writes the transcript person by person — you, Person 2, Person 3… which you can rename — with a summary, key points and to-dos by Claude with your key. Copy it as Markdown or export it. The audio is deleted once the transcript is written; tell the people in the call that you record
- **« OK Coucou »** — say it, then ask anything, in any of Parakeet's languages: add or swap pills, play, pause or search on Spotify, how much you made on Stripe today, what your agents are doing, the weather or the news (web search), open an app, prepare an email that opens in your mail app for you to send. Claude is the brain, with your own key; only the words after « OK Coucou » leave the computer, never audio. Coucou answers in the pill and out loud, with the system's voice or ElevenLabs with your key. Off by default: Notch → OK Coucou
- **Spotify on Windows** — the Spotify pill and card, read from the system media controls, and Mochi dances to it (#493 by @alexisrja)
- The island's size follows the webview's zoom, so it no longer comes up cut on scaled displays (#467 by @Ohualtex); pill labels leave room for Mochi (#522 by @Ohualtex); the Claude Desktop pill opens the Microsoft Store app through its link (#417 by @Ohualtex); the Claude Code pill has the same name everywhere (#409 by @Ohualtex); the OpenCode plugin works with OpenCode 2 (#530 by @Ohualtex)

## 0.4.0 — October 14, 2026

Coucou becomes a real app: a window in the Dock, dictation everywhere on the Mac, and notes of your calls. All of it free and open source.

- **Coucou, the app** *(macOS, GitHub build)* — Coucou now has its own window and sits in the Dock. Open it and everything is in one place: on the left, **Flow** (Dictation, Notetaker, Statistics, Dictionary, Snippets, Styles, Settings), then **Notch** (General, Active pills, Agents, Chat, Integrations, Voice, Shortcuts), the same settings as before. The window opens when you launch Coucou yourself, not when it starts with your Mac; ⌘, opens the settings, and the Dock icon can be turned off in Settings → App. Each page has its own colour and a band of little Mochis that walk around, wave, hop and react when you poke them, over a deep black with particles that drift away from the pointer
- **Flow dictation** *(macOS, GitHub build)* — hold a key anywhere on the Mac (right ⌥ by default, or fn, right ⌘ or right ⌃), speak, let go: your words are pasted where you type, like Wispr Flow. Two quick taps keep it listening hands-free until the next tap; Esc cancels; ⌃⌘V pastes the last dictation again. ⌘V follows your keyboard layout, clipboard managers leave the dictation out, and the clipboard gets back what it held. When no text field has the focus, the words are kept on the clipboard and a message says so. Off by default; it needs the Accessibility permission to see the key and paste
- **The pill** — a small see-through pill rests at the bottom of the screen while Flow dictation is on. Hover it and it opens into a toolbar: Mochi, dictate hands-free, record a call, open the Coucou window, each with its tip. When you speak, Mochi and nine dots rise and fall with the low and high notes of your voice. Put it at the bottom, on the left or on the right of the screen: on the sides it stands up and everything in it is stacked. Messages (a dictation kept on the clipboard, a microphone that is off) show in a bubble next to it, with a button to act
- **Your words, your way** — **Dictionary**: names Coucou always spells right, and replacements (« cloud code » → « Claude Code »). **Snippets**: say a short phrase, the whole text is pasted, untouched. **Styles**: an optional clean-up by Claude with your own key (no « um », no repeats, your corrections applied), as said, natural or polished, per app. **Statistics**: words, time saved, speed, words per day and the apps you dictate in. Your history stays on your Mac, kept as long as you choose
- **Parakeet** *(macOS, GitHub build)* — dictation can run on NVIDIA's Parakeet through [FluidAudio](https://github.com/FluidInference/FluidAudio), on the Mac's Neural Engine: more accurate, offline, 25 languages. Nothing is downloaded until you click Download in Coucou → Settings (about 650 MB, once); until then the Mac's own recognition is used. Apple silicon only
- **Notetaker** *(macOS, GitHub build)* — click Record a call: Coucou records your microphone and what the Mac plays (no bot joins the call), shows the words live, then writes the transcript person by person — you, Person 2, Person 3… which you can rename — with a summary, key points and the to-dos, by Claude with your key or by Apple Intelligence on your Mac. Copy it as Markdown or export it. The pill turns red with the time and a button to stop. Notes stay on your Mac and the audio is deleted once the transcript is written; tell the people in the call that you record

## Android 0.2.0 — October 13, 2026

- **Home-screen widgets** — nine to pick from, each with a real preview in the widget picker: Mochi at a glance, Mochi's mood, Approvals waiting, Finished today, Plan usage, a one-line status with four buttons, all your agents, Mochi big (Mochi, plan usage and six buttons), and the agents summary, now on the same card. The colour follows your most urgent agent: orange when something waits for you, blue while it works, green when it's done, grey when the computer isn't there. Plan usage has its own colours (teal, yellow from 75 %, red from 90 %, with the time it resets). Read-only: the buttons only open a screen of the app, and a request is always decided in the app, behind your fingerprint. No background refresh: they redraw when something changes, plus once at midnight so Finished today starts again at zero, and that count stays on the phone (#620 by @Rhytam23)
- Working notes that were not meant to ship are gone from `android/` (#618 by @Rhytam23)

## Android 0.1.0 — October 11, 2026

- **Coucou for Android**, by @Rhytam23 — your agents, Allow and Deny with your fingerprint or screen lock (even on a locked phone), answers to Claude's questions, chat through the computer's own keys, plan usage and services, an optional island over other apps, a widget, a quick-settings tile and an ongoing notification. It pairs with Coucou 0.4.0 or later on Windows or Linux. Android 11 or later, English only; a signed APK on the [release page](https://github.com/Louis-CFM/coucou/releases/tag/android-v0.1.0) (#501 by @Rhytam23)

## Windows and Linux 0.4.0 — October 11, 2026

- **Your Android phone** — Settings → Android phone: the link for [Coucou for Android](android/README.md), an opt-in server on your local network, off by default (nothing listens until you turn it on), paired with a QR code and a pinned certificate. "Pair again" disconnects every phone, a command too long to show in full can only be allowed on the computer, and each extra (session details, answers, chat through your own keys, file changes, plan usage, services) has its own switch (#500 by @Rhytam23)
- **Plan usage**: Settings and the README say that the Claude gauge needs the Claude Code command-line tool, not the Claude desktop app (#479 by @Rhytam23)
- Newer versions of the GitHub actions in the build workflows (#499 by @Rhytam23)

## 0.3.0 — October 11, 2026

- **« OK Coucou »: talk to Mochi** *(macOS, GitHub build)* — say « OK Coucou » and ask anything, in English or French. Claude is Coucou's brain, with your own Anthropic API key: add or swap pills, play music, ask how much you made on Stripe today, your GitHub stars, your Vercel deploys, what your agents are doing, search the web, open an app. It keeps the thread, asks back when something is missing, and listens again for your answer. Speech recognition runs on your Mac; your words and the data Coucou reads to answer go to Anthropic, never audio. Turn it on in Settings → Voice
- **Emails by voice** — « send an email to Enzo to tell him the image is ready »: Coucou finds the address in your contacts, writes the email, opens it in the notch, and you drop an attachment on the notch if you want one. Nothing is sent until you click Send
- **Mochi lives the conversation** — he listens (his eyes follow your voice), thinks, talks back, and winks when he's done. The answer shows under the notch: click it to read it in full. You can open the island while he talks
- **His voice** — the Mac's voices with Woman / Man and pitch, the best installed voice picked automatically (Premium voices recommended), or ElevenLabs with your own key
- **Smoother and lighter** — animations at the display's full rate, a hidden island that really rests, and less background work everywhere (pollers, logs, Mochi on the desktop)

## Windows and Linux 0.3.0 — October 9, 2026

The first Linux release since 0.1.1, so on Linux it also brings everything in Windows and Linux 0.2.0 below.

- **Open on hover**: the island opens when the pointer reaches it and folds again shortly after it leaves; a click inside keeps it open — Settings → General, off by default
- **Your own sounds**: put a file named like one of Mochi's sounds (`finish.wav`, `approval.mp3`, `greet.m4a`…) in the sounds folder to replace it — Settings → General → Open sounds folder, Reload sounds
- **A colour of your own for each Mochi**: click a pill's colour dot in Settings (#320 by @shakibbinkabir)
- **Mochi to the desktop from the keyboard**: `Ctrl+Alt+D` sends him out and brings him home, like ⌃⌥D on the Mac
- **Keyboard in the open island**: `Ctrl+↑` / `Ctrl+↓` move through the GitHub lists and `Ctrl+O` opens the row; `Ctrl+E` opens the latest diff
- **Spotify pill** *(Linux)*: the track, play/pause and next on the pill; the cover, progress with seek, shuffle, repeat and volume on the card, read from Spotify over MPRIS — and Mochi dances to it, in the island and on the desktop
- **Global shortcuts on Wayland** *(Linux)*: registered with the desktop through the GlobalShortcuts portal (KDE Plasma 6, GNOME 48+, Hyprland, COSMIC…); where there is none, the commands to bind by hand stay in Settings → Shortcuts
- **Open terminal brings the terminal forward** *(Linux)*: on X11 and KDE Plasma (Wayland too), and the right tab in kitty; GNOME on Wayland still opens the folder in VS Code
- Antigravity runs its tools again: Coucou answers "ask", so Antigravity keeps its own prompt and nothing is allowed on its own (#317 by @kobaltgit)

## Windows and Linux 0.2.0 — October 8, 2026

The Windows and Linux app catches up with the Mac, from 0.1.1 to 0.2.1 — everything except Apple Music and the iPhone, which depend on macOS and iCloud.

- **Agents**: Codex, GitHub Copilot CLI and Muse Code sessions with Allow / Deny in the island; Gemini CLI, Antigravity, Cursor Agent, OpenCode, Amp and Hermes sessions on their own pills; Claude Code sessions from the Claude app on Windows. Install them all from Settings → Agents, which shows the diff and takes a dated backup before writing — one hardened writer for every agent's config (#278 by @Totopo27, #298 by @kobaltgit, #231 by @BeyondBirthday07)
- **Questions**: answer Claude Code's multiple-choice questions from the island; answers are checked against the questions asked, and a question answered in the terminal takes the card down (#216 by @PythonTilk)
- **The permission card** comes up for every agent, brings its pill forward, can be folded without answering, and never decides on its own
- **Chat**: Anthropic, Google AI, OpenAI and OpenRouter, switchable by clicking the model name; local models through Ollama, LM Studio or any OpenAI-compatible server, streamed, thinking hidden; Markdown answers with a copy button; full answers; your first name in the greeting; `COUCOU_ANTHROPIC_BASE_URL` for a gateway, https only (#161 by @4rchila, #166 by @AlphaIsYour, #173 by @AinzDerErste, #206 by @Totopo27)
- **Plan usage**: Claude's 5-hour and weekly limits and Codex's, in the island header (#171 by @AinzDerErste)
- **Live diff**: each file Claude edits shows in the ticker with its +N −M, and a click opens the diff; the finished card shows Claude's final message
- **GitHub**: your pull requests with their CI, reviews waiting for you, the CI of your default branches, alerts when CI turns red or green, and your contribution grid
- **Mochi**: the wardrobe and seasonal outfits, the new greeting and its sound, and Mochi on the desktop (Windows, X11 and layer-shell compositors)
- **Keyboard shortcuts** from anywhere, changeable in Settings → Shortcuts; the defaults never type an AltGr character on French, German, Spanish, Italian or Portuguese keyboards
- **Weekly recap** on Monday mornings, shareable as an image; history stays on your computer
- **Pills**: declare the tools you use and pick your main one; hook-based pills no longer ask for a key; "Open terminal" brings the session's own window forward on Windows
- **10 languages**: English, 中文, हिन्दी, Español, العربية, Français, বাংলা, Português (Brasil), Русский, Bahasa Indonesia — Settings → General → Language (#228; picker from #226 by @alexisrja)
- **File drop** works from every Explorer view, and Cancel works (#240 by @KauaDc, #126); only files a real drop delivered can be read
- **Linux**: auto-close on KDE/Wayland and GNOME (#160 by @4rchila, #136), the island at the top on GNOME (#149 by @betodoescher), pinned to its display on Hyprland and Sway with a display picker (#227 by @chuxclay), GNOME large text no longer cuts the island (#122), an Arch Linux PKGBUILD (#299 by @FabioLukas123, #230)
- The step ticker no longer stops at a session's 20th step (#265 by @PythonTilk), ticker steps keep their own line (from #203 by @shakibbinkabir), `tauri dev` no longer crashes on EBUSY (#202 by @Andrev-91)

## 0.2.3 — October 8, 2026

- **Terminal sessions**: Claude Code sessions started in Warp, Terminal, iTerm, Ghostty, cmux or Orca show in the notch, and "Open terminal" brings back the app the session runs in. Answering their questions and permissions from the notch is opt-in — Settings → Agents (#282 by @guerraOrzc, #238 by @mateuslamaral)
- **Spotify pill**: what's playing in Spotify, with play/pause and skip (#246 by @JhoanG956)
- **A colour of your own for each Mochi**: click a pill's colour dot in Settings → Active pills (#320 by @shakibbinkabir)
- **Dictate in the chat** *(GitHub build)*: click the mic and talk in any of your languages — Coucou listens in your Mac's languages and keyboard layouts and keeps the one you spoke; right-click the mic to pick a language. On-device when the Mac supports it (#116 by @xynlaze234)
- **Open on hover**: the island opens when the pointer reaches the notch and closes when it leaves — Settings → General → Behavior, off by default (asked by felix11zx)
- **Your own sounds**: drop a file named after one of Mochi's sounds in the sounds folder to replace it — Settings → General → Sound (#116)
- Antigravity runs its tools again: Coucou answers "ask", so Antigravity keeps its own prompt and nothing is allowed on its own (#317 by @kobaltgit)

## 0.2.2 — October 8, 2026

- **Choose Mochi's screen**: the screen with the notch, the main screen, a specific display, or "Follow the mouse" — Settings → General → Display. The island moves right away and finds its place again when screens are plugged in or out; Mochi's gaze is right on any display arrangement (#236 by @steeven-th)
- **Claude Desktop pill**: Claude Code sessions started from the Claude app's Code tab get their own pill instead of being ignored; their permission prompts stay in the Claude app (#191 by @samuelmtz2000)
- **Codex plan usage**: a Codex pill next to the Claude one shows your Codex limits and free resets, read from the Codex CLI — Settings → Agents → Plan usage *(GitHub build)* (#244 by @Ace3Z)
- **Questions** show in full, with each option's description (#249 by @Mehdi-fsn)
- A pending permission can be folded away with Escape in the notch or the toggle shortcut, without answering it; Escape typed in another app never hides it (#290 by @jhannesreimann)
- Pills that run on hooks (Claude Code, Cursor, Codex, Gemini CLI, Antigravity, Copilot CLI, Muse Code, OpenCode, Amp, Hermes) say whether their hooks are installed instead of asking for a key (#183 by @TheodoreRiant)
- The chat keeps Claude's whole answer — web-search answers were cut after the first block (#67 by @RAMZI0TO99)
- `~/.claude/settings.json` is never rewritten from scratch when it can't be read, the backup must succeed before anything is written, and nothing is written if the file changed since the preview (#243 by @Fabian-2026)
- The auto-close delay set in Settings is respected (#25 by @Kamasoutra); reopening Coucou brings the island back (#270 by @AndersonPGS)
- Fixed a crash an hour after a file edit (#286 by @i87ce)
- Lighter when hidden: the island checks the pointer 8 times a second instead of 60 while it is hidden and the pointer is away from it

## 0.2.1 — October 7, 2026

- **Hermes Agent** (Nous Research, open-source): sessions appear in the notch — live tool steps, the final response when done, and the platform (Telegram, Discord…) when running via the gateway. Install from Settings → Agents → Hermes: it writes a small Python plugin to `~/.hermes/plugins/coucou/` and enables it in `~/.hermes/config.yaml`, with the same preview, backup and confirmation flow as other agents *(macOS, GitHub build)* (#288)
- Hermes approval requests show a "⏳ Approval pending in Hermes" step in the notch. Approving directly from the notch isn't supported yet — current Hermes versions (0.15.x) don't expose the transport API. The Approvals toggle in Settings will activate automatically once Hermes adds it (#288)
- Coucou never blocks Hermes: if the app is closed or unreachable, Hermes continues normally and handles approvals itself (#288)

## 0.2.0 — October 6, 2026

- GitHub Copilot CLI and Muse Code sessions show up in the notch: see every step live and approve or deny permissions right from the island. Install from Settings → Agents → Copilot CLI / Muse Code, which shows what will change in your config and backs it up before writing *(GitHub build)* (#263)
- OpenCode sessions appear in the notch via a small JavaScript plugin: install it from Settings → Agents → OpenCode. Same installer flow — preview, backup, confirm. OpenCode never blocks on the plugin (fire-and-forget), so Coucou never slows it down *(macOS, GitHub build)* (#263)
- Amp sessions appear in the notch the same way, via a TypeScript plugin: Settings → Agents → Amp *(macOS, GitHub build)* (#263)
- Weekly recap: on Monday morning, the first time an agent starts working or your Mac wakes, Coucou shows a card for the past week — time spent, sessions, files and lines changed, commands run, permissions and questions, plus your top agent, top project, busiest day and longest session. Open it any time from the menu bar with "Weekly recap" (#264)
- Share your week as a 1080 × 1920 image with Mochi: copy it, save it or share it from the notch. A privacy toggle lets you hide project names before sharing (#264)
- Everything stays on your Mac: the recap reads from a local history file (12-week rolling window) that never leaves your machine. Clear it any time in Settings → General → Weekly recap (#264)
- Coucou now speaks English, 中文, हिन्दी, Español, العربية, Français, বাংলা, Português, Русский and Bahasa Indonesia. Pick your language in Settings → General → Language, independent of your system locale. Translations welcome — open a pull request (#268)

## 0.1.9 — October 6, 2026

- Services up close on the iPhone: tap a service and your Mac fetches live data from its API — Vercel, GitHub, Stripe, Resend, Cal.com, n8n and Notion. The keys never leave the Mac; the detail is written to your iCloud encrypted (#251)
- Act from the iPhone: Vercel (redeploy, promote to production, cancel a build), GitHub (re-run failed jobs, approve, squash and merge), n8n (activate, deactivate, retry a failed run). Each action runs only if it was offered on an item in the last detail the Mac published for that service, is used once, and must be less than 5 minutes old. Nothing that moves money or sends an email (#251)
- The Live Activity starts 20 seconds after the Mac locks, not immediately, so a quick lock and unlock doesn't spend one of iOS's hourly starts. It starts right away when an agent is waiting for a permission or has a question (#251)
- After unlocking, the Live Activity waits 30 seconds before ending, in case the Mac locks again — useful on a laptop that goes to sleep the moment you put it down (#251)
- If the iPhone has no update token yet (iOS held back the start), and an approval or question is waiting, the Mac starts the activity again once for that specific request (#251)
- Cal.com upcoming bookings work again: the API v2 expects `afterStart` / `beforeEnd`, not `start` / `end`, so the bookings page was empty (#251)

## 0.1.8 — October 5, 2026

- Coucou on iPhone: turn on Settings → General → iPhone (off by default) and your agent sessions show up live in the Coucou iPhone app and its widgets, through your own private iCloud. Project names, commands and questions are encrypted with your iCloud keys; turning it off deletes them (#209, #211, #212, #213)
- Allow or deny a permission from the iPhone: a notification with the command, Deny right from it, Allow behind Face ID. Your Mac only applies a decision meant for the exact request it is waiting on, and the request expires after 2 minutes. The iPhone keeps a history of your decisions (#220)
- Lock your Mac while an agent works and Mochi moves to your iPhone's Lock Screen and Dynamic Island, then comes back to the notch when you unlock. Turn it on under Settings → General → iPhone. It goes through a small relay that only sees the agent's name and state (#221)
- Mochi, the pills and the diff engine now live in a shared package used by both apps; nothing changes in the notch (#210)
- The iPhone sees more of what your Mac sees: every service Mochi (GitHub, Stripe, Vercel, Resend, Cal.com, n8n, Notion) with its latest items, and the last turn of each session with its commands and diffs, all encrypted with your iCloud keys. No API key ever leaves the Mac (#224)
- Send the next instruction to Claude Code from the iPhone (GitHub build, off by default): your Mac picks it up within 15 seconds and continues the session in its own folder (#224)
- Answer Claude's questions from the iPhone: your Mac applies an answer only if it matches the question still waiting (#241)
- The Live Activity counts the time since Mochi left, and shows Allow and Deny while a command waits for you (#232, #241)
- A new coucou sound for Mochi's greeting (#241)

## 0.1.7 — October 4, 2026

- Keyboard shortcuts from anywhere: ⌃⌥Space opens the chat, ⌃⌥A jumps to a waiting permission or question, ⌃⌥T brings your terminal forward, ⌃⌥] and ⌃⌥[ switch pills, ⌃⌥M mutes Mochi, ⌃⌥D sends him to the desktop and back, ⌃⌥G opens the wardrobe, and ⌃⌥W attaches the front window to the chat (GitHub build) (#205)
- In the open island: ⌘← ⌘→ and ⌘1–9 switch pills, ⌘↑ ⌘↓ and ⌘O move through a card's list, ⌘E opens the diff, ⌘↩ sends, ⌘K starts a new chat, ⌘P pins the island (#205)
- Every global shortcut can be changed or turned off in Settings → Shortcuts, which also flags combinations another app already uses. They need no Accessibility permission (#205)
- ⌘⇧N now opens and closes the island (#205)

## 0.1.6 — October 4, 2026

- Mochi on the desktop: drag him out of the notch and drop him anywhere on your desktop. He hangs out there, follows your cursor with his eyes, wears his outfit and dances to your music (#198)
- When Claude needs you, he flies back to the notch with the permission or the question, then returns to his spot once you answer. He does a happy jump when a task finishes (#198)
- Click him to poke him, right-click for the wardrobe, drop him on a window to attach it to the chat (GitHub build), and drop him on the notch or double-click him to bring him home (#198)
- He falls asleep when nothing is going on, and remembers his spot between launches (#198)

## 0.1.5 — October 4, 2026

- Dress Mochi up: right-click him to open the wardrobe and pick a party hat, beanie, crown, witch hat, Santa hat, bunny ears, bow, sunglasses, round glasses, scarf or pumpkin, all drawn in code (#195)
- Auto mode dresses Mochi for the seasons on his own (#195)
- Outfits follow his head in 3D, glasses stay on his eyes, soft parts react when you tap or move him, and outfits come and go with a transition. Only the main Mochi wears them (#195)
- A new launch greeting: Mochi drops into the island, bounces, slides to the side and waves hello with a quick little hand, then comes back, with a new soft whisper of a sound (#196)
- Mochi's body is no longer clipped at two corners during the greeting (#196)

## 0.1.4 — October 3, 2026

- See what Claude is editing, live: each file edit shows up in the session ticker with its +N −M lines, and a click opens the diff right in the notch (#177)
- When Claude finishes, the session card shows its final message instead of the last step, without the shimmer (#177, #179)
- GitHub pill: your open pull requests with their CI status, the pull requests waiting for your review, and the CI of the default branch of your recent repos. Click a row for the list, then an item to open it on github.com (#181)
- GitHub alerts: a badge and a sound when the CI of one of your pull requests turns red or green, when a default branch breaks, or when someone requests your review. Fast CI runs are caught too, and the card refreshes when you open it (#181, #185)
- Your GitHub contribution grid: the last 7 days in the GitHub card header, click it for the past 23 weeks, and click a day for its count (#187)
- The GitHub token needs read access to pull requests and CI: a classic token with the repo scope, or a fine-grained token with read access to Pull requests, Commit statuses and Actions (#181)
- The finished view no longer overflows the card (#179)

## 0.1.3 — October 3, 2026

- Answer Claude's questions from the notch: when Claude Code asks a multiple-choice question, pick an option or type your own answer right in the island, and Reply in terminal hands it back. Update your hooks in Settings to turn it on (#165) — thanks @Vega8991 for the idea (#94)
- Claude plan usage (GitHub build): turn on Settings → Agents → Plan usage to see your 5-hour and weekly limits in a small pill in the notch header, and click it for the details and reset times. Pro and Max plans; your current status line keeps working (#159)
- Chat with local models through Ollama or LM Studio, no API key needed: connect them in Settings → Chat → Local models. Answers stream in, and thinking blocks stay hidden (#156)
- Markdown in chat answers: bold, lists, headings, quotes, and code blocks with a copy button. Links open only when they are web links (#156)
- Apple Music (GitHub build): see what is playing in the notch, play, pause and skip on hover, and Mochi dances along (#144, #153)
- Settings are now organized in a sidebar (#153)
- The chat greets you by your own first name (#154)

## 0.1.2 — October 2, 2026

- Codex support (GitHub build): sessions show up live on the Codex pill, and permission requests get Allow and Deny in the notch. Install from Settings → Codex Hooks, then trust the hooks once with /hooks in Codex (#130) — thanks @lacatu5
- Cursor: Claude Code started in Cursor's terminal shows up on the Cursor pill, and you can answer its permission requests from the notch (#120).
- Pick your main coding tool in Settings → Active pills: VS Code, Cursor, Codex or Antigravity (Codex and Antigravity: GitHub build). It stays on and no longer takes one of the 4 slots (#120).
- The permission card stays in the notch until you answer it: the mouse no longer folds it, and reopening the island shows the request again (#117).
- The permission card also shows when the island is already open, and the pill you were on comes back once you answer (#120).

## 0.1.1 — October 2, 2026

- Declare the tools you use in Settings: Gemini CLI, Antigravity, Anthropic, Google AI and OpenAI pills join the existing ones (Cursor and Codex pills are coming soon), and you pick the main pill.
- Chat now supports Google AI (Gemini) and OpenAI in addition to Anthropic; switch provider and model by clicking the model name in the chat view, on macOS.
- Linux version: the Tauri app now builds for Linux too (AppImage, .deb, .rpm), with the island as a layer-shell overlay on Wayland and Claude Code hooks over a private Unix socket (#21) — thanks @Davy133
- Compact island on screens without a notch (#22) — thanks @Kamasoutra
- Only web links (http/https) open from the notch; other kinds of links from Claude or integrations are ignored (#16) — thanks @Cris1670
- Hook socket limited to your own user account, with size and time limits; logs no longer keep commands, n8n data or full URLs, and stay under 1 MB (#16) — thanks @Cris1670 and @Vignesh-Thangamariappan
- The island always reopens after folding, and Settings opens below it, resizable — thanks @rouderz
- Choose the Claude model for the chat in Settings; the list comes from your Anthropic account, and Claude Sonnet 4.6 stays the default — thanks @rouderz
- Windows build artifacts are now downloadable from a manual CI run — thanks @MysJofR
- Any agent can talk to Mochi: tag a hook payload with `coucou_agent` (e.g. `nb-hook --agent my-agent`) and it gets its own pill in the island (#7, #9) — thanks @lacatu5
- Gemini CLI and Antigravity (agy) hook support on macOS: install from Settings and their sessions show up in the island — thanks @corefusiion

## 0.1.0 — September 27, 2026

- First release: Mochi lives in your notch, breathing, blinking, with eyes that follow your cursor
- Claude Code sessions: live steps, approve permissions, answer questions, jump to the terminal
- Chat with Claude from the notch
- Drop a file on the notch to ask a question about it or send it by email
- Drag Mochi onto any window to attach it as context
- Integrations: Stripe, n8n, GitHub, Vercel, Resend, Notion, Cal.com
- 28 handcrafted sounds
- Hides when idle, peeks out when you hover
