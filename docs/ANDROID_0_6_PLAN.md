# Coucou for Android 0.6.0: plan

For Louis, to review before any pull request. Two features that only Coucou can do, because the phone is linked to the
computer. Nothing here changes the Mac app. Dictation and a voice keyboard are not part of this release and are not built.

Each part ends with **Decisions you may want changed**: say which, and it is changed before the PR.

## Part 1: spoken alerts (Android only)

**What the user gets.** One switch, *Settings → Sound → Spoken alerts*, off by default. When it is on, the phone says one
short line with Android's own voice (`TextToSpeech`) when an agent of the linked computer:

- needs the user: "Claude Code needs your approval", "Claude Code has a question for you";
- finishes: "Claude Code has finished".

**What it never does.**

- It never reads a command, a diff, a file name or a message. The rule that builds the line receives the agent and the kind
  of event, nothing else. A known agent is said by its catalog name; an unknown one by its name reduced to letters, digits
  and spaces (40 characters at most), so a name made up by a computer cannot carry a path or a command into the sentence.
- It never answers, allows or denies anything. Speaking is all it does.
- No network call and no new dependency. Only a voice that is installed on the phone and works offline is used.

**When it stays silent.** In Do Not Disturb; when the ringer is silent or on vibrate; during a phone call; when the phone
has no offline voice for the app's language (Settings then says so under the switch). A finish also stays silent for an
agent the user muted and during quiet hours, like its notice; a request or a question is never held back by those two.

**Never twice.** An event is a *change* into "approval", "question" or "finished". The first picture after connecting is
never an event (a request that was already waiting is not announced when the link comes back), and neither is a repeated
update or the list sent again after a reconnect. The same agent's same kind of event is also not repeated within 8 seconds.

**Where the code is.** The decision (speak or not, which line, which voice) is pure Kotlin with unit tests:
`core/SpokenAlerts.kt`, `SpokenAlertsTest`. `app/SpokenAlerts.kt` only asks Android and speaks. The engine exists only while
the switch is on and is shut down when it goes off. The manifest gains the `<queries>` entry Android 11 and later need to
find the speech engine; no permission is added (no microphone).

**Decisions you may want changed**

1. The switch is in the *Sound* section, under the volume. It could go under *Notices* instead.
2. It speaks while the app is on screen too (Mochi's sounds do the same).
3. Failed and rate-limited sessions are not spoken: you asked for "needs you" and "finishes" only.
4. A finish follows mute and quiet hours but not the switch "When an agent finishes or fails": spoken alerts are their own opt-in.
5. The line is spoken on the notification volume, after anything already being said (two events are heard one after the other).
6. The demo never speaks (it loops through every state).
7. Android's voice can sound robotic in some languages; there is no choice of voice in the app (Android's own settings have it).

## Part 2: start a Claude Code session from the phone

The desktop 0.6 feature "Start a Claude Code session from the island", asked for from the phone. **There is no second
launcher**: the phone's request ends in the function the island's own card calls (`launch_session` in
`windows/src-tauri/src/launch.rs`), with the same terminals and the same way of handing the prompt over.

### What the phone shows

On Home, when a computer is paired, a row **New Claude Code session**. It opens a sheet in the style of the other sheets:

- the **projects** the computer offers, to tap (their folder names);
- a text field, **What should Claude do?**;
- **Send**, with the lock icon: it asks for the fingerprint or screen lock, like Allow.

The states it can say, each in plain words:

| State | When |
|---|---|
| Sent | the computer answered that the terminal opened. The session then shows on Home like any other |
| Refused | the computer answered no, with why: the switch was turned off, the project is no longer in its list, too many starts, the terminal could not open |
| No answer | nothing came back in 10 seconds (the link dropped). The phone says to look at the computer before sending again |
| Your computer doesn't offer this yet | the computer did not offer the feature: an older Coucou, a Mac, or the switch is off there. The sheet says where the switch is |
| No project yet | the feature is on but the computer has no project to offer yet (no Claude Code session has run there) |
| Not connected | the computer is not reachable right now |

### What the phone sends

A new optional capability, `launch`, negotiated like the others (`hello.caps` / `welcome.caps`). Protocol v1 is unchanged.

```
computer → phone   {"type":"projects","projects":[{"id":"3f9a…","name":"coucou"}, …]}
phone → computer   {"type":"launch","id":"<made by the phone>","project":"<an id of the list>","prompt":"<text>"}
computer → phone   {"type":"launchResult","id":"…","ok":true}
                   {"type":"launchResult","id":"…","ok":false,"reason":"off|empty|too_long|unknown_project|rate|failed"}
```

- `projects` is the list of the island's own card: the folders Claude Code sessions ran in (and any folder you chose there),
  ten at most. The phone is told a **folder name** and an **id** for each. The id is 16 hex characters derived from the path
  and a random value made at each start of Coucou; **the path never leaves the computer**.
- `launch` carries an id of that list and the text. **There is no field for a path**, and the computer reads none: a phone
  cannot name a folder, a command or an option.
- The text is at most 4000 characters, like a chat message.

### What the computer accepts and refuses

Accepted only if **all** of this is true:

- the phone is paired (valid token, pinned certificate) — as for everything else on the link;
- the switch *Settings → Android phone → Let the phone start Claude Code sessions* is on. **Off by default.** It is read
  when the phone connects and again for every request, and changing it disconnects the phones once, like the other switches;
- the phone asked for `launch` and was offered it on this connection;
- `project` is an id of the list this computer sent; the folder still exists (the launcher checks, as for the island);
- the text is not empty and not over 4000 characters. Control characters are removed first;
- fewer than 6 sessions were started from phones in the last 10 minutes.

Refused or ignored:

- a phone that did not negotiate `launch` is not heard and not answered (to it, `launch` is an unknown message);
- a path, a folder name, or an id that is not in the list: `unknown_project`;
- the same request arriving twice (same `id`) starts one session;
- nothing is logged about the text. The log says that a phone asked, and the folder's name.

**The prompt is passed exactly as the island passes it, never in a command line**: on Linux in the `COUCOU_PROMPT`
environment variable of the terminal; on Windows in a temporary file that PowerShell reads and deletes. That code is not
touched; its tests already cover quotes, `;`, `$( )` and backticks.

**Old and new together.** A computer that does not know `launch` ignores the capability and the message (unknown types are
ignored since v1), and the phone says "Your computer doesn't offer this yet". An older phone never asks for `launch`, so a
newer computer sends it nothing new and everything else works as before.

### What is off by default

The computer's switch. Without it the phone is offered nothing and can start nothing. On the phone there is no setting:
the row is there when a computer is paired, and says what is missing.

### What is not included

- Any folder that is not in the computer's list (no typed path, no "Choose a folder…" from the phone).
- Any agent but Claude Code; any option of `claude` (model, permission mode, flags).
- Dictating the prompt. The text field takes whatever keyboard the phone has; Coucou adds no microphone.
- Seeing the terminal, or typing into the session afterwards. The session shows on Home like any other, and its requests
  arrive as usual.
- The Mac: Windows and Linux only, as agreed. The relay needs nothing new: the same messages travel through it.

### Where the code is

- Computer (Windows and Linux): `phone_link/hub.rs` (the list, the checks, the answer), `server.rs` (the capability and the
  message), `mod.rs` (the switch, and the one call into `launch.rs`), `settings.rs` (`phoneLaunch`),
  `src/island/phone-link.ts` (publishes the island's projects), `src/settings/phone.ts` (the switch, added under the
  weekly recap, nothing else on the page changes). Tests through the real TLS server: `phone_link/tests.rs`, `mod launch`.
- Phone: `link/Protocol.kt` and `LinkClient.kt` (the messages), `core/LaunchFlow.kt` (the states, pure, tested),
  `ui/LaunchSheet.kt`, one row on Home.
- `docs/ANDROID_LINK.md` describes the capability.

### Decisions you may want changed

1. **The row shows on Home for every paired phone**, also when the computer does not offer the feature (it then explains
   how to turn it on). The other optional features stay hidden until offered. It can be hidden until offered too; the
   "doesn't offer this yet" state would then only be seen on a Mac or after the switch goes off.
2. **An empty prompt is refused.** The island accepts one (it just opens Claude Code); from a phone, nobody is at the
   terminal to type.
3. **Decided (Louis, 19 November): a session started from the phone always starts in the standard permission mode**,
   with `--permission-mode default`, whatever the computer's own Claude Code settings say, so it always asks for approval
   and the requests arrive on the phone as usual. On Linux it runs as `command claude`, so a shell alias or function cannot
   add a flag (Louis, 20 November). The island's own launch is unchanged. In `launch.rs` this is
   `Origin::Phone` and `launch_from_phone`, tested in `a_session_from_the_phone_always_starts_in_the_standard_permission_mode`.
4. **The list is the island's whole list**, including a folder the user picked by hand there, not only folders sessions ran in.
5. **Two folders with the same name look the same on the phone** (the path is never sent). Rare with ten projects.
6. **The limits**: 4000 characters, 6 starts per 10 minutes for all phones together, 10 seconds before "No answer".
7. **The phone always needs its lock to send**; with no screen lock set up, sending is refused, like Allow.
8. **Through the relay too**: a phone away from home can start a session, with the same checks.
9. The computer shows nothing special when a phone starts a session: the terminal opens and the session appears on the island.
