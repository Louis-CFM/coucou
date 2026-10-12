// What a spoken command means: the Windows take on the Mac's IntentParser.
// English, deterministic and instant; anything it doesn't know goes to Claude
// (src/voice/voice.ts). Pure: no DOM, no Tauri, tested on its own.

export type Intent =
  | { kind: "cancel" }
  | { kind: "music"; action: "playPause" | "play" | "pause" | "next" | "previous" }
  | { kind: "volume"; action: "up" | "down" | "mute" | "set"; value?: number }
  | { kind: "pill"; action: "add" | "remove"; name: string }
  | { kind: "focus"; minutes: number }
  | { kind: "focusStop" }
  | { kind: "timer"; minutes: number; label: string }
  | { kind: "todoAdd"; text: string }
  | { kind: "todoList" }
  | { kind: "open"; target: string }
  | { kind: "planUsage" }
  | { kind: "agents" }
  | { kind: "deny" }
  | { kind: "approve" }
  | { kind: "time" }
  | { kind: "ask"; text: string };

const WORD_NUMBERS: Record<string, number> = {
  a: 1, an: 1, one: 1, two: 2, three: 3, four: 4, five: 5, six: 6, seven: 7, eight: 8, nine: 9, ten: 10,
  fifteen: 15, twenty: 20, "twenty five": 25, thirty: 30, forty: 40, "forty five": 45, fifty: 50, sixty: 60, ninety: 90,
};

/** "25", "twenty five", "an" → 25, 25, 1; hours count as 60. */
export function minutesIn(s: string): number | null {
  const m = /(\d+(?:\.\d+)?|twenty five|forty five|[a-z]+)\s*(hours?|hrs?|minutes?|mins?)\b/i.exec(s);
  if (!m) return null;
  const n = /^\d/.test(m[1]) ? Number(m[1]) : WORD_NUMBERS[m[1].toLowerCase()];
  if (n == null || !Number.isFinite(n)) return null;
  return Math.round(/^h/i.test(m[2]) ? n * 60 : n);
}

/** Lower case, no trailing punctuation, no leading "please" / "can you". */
function clean(text: string): string {
  return text
    .toLowerCase()
    .replace(/[.!?,]+$/g, "")
    .replace(/^(please|hey|ok|okay|maki)[, ]+/g, "")
    .replace(/^(can you|could you|would you|will you)\s+/, "")
    .replace(/\s+please$/, "")
    .trim();
}

export function parseIntent(raw: string): Intent | null {
  const t = clean(raw);
  if (!t) return null;
  if (/^(cancel|never ?mind|stop listening|forget it|nothing)$/.test(t)) return { kind: "cancel" };

  // Music.
  if (/^(pause|stop)( the)?( music| song| playback)?$/.test(t)) return { kind: "music", action: "pause" };
  if (/^(play|resume|continue)( the)?( music| song| playback)?$/.test(t)) return { kind: "music", action: "play" };
  if (/^(next|skip)( (song|track|one|this))?$|^play (the )?next( song| track)?$/.test(t)) return { kind: "music", action: "next" };
  if (/^(previous|go back|last)( (song|track))?$|^play (the )?previous( song| track)?$/.test(t)) return { kind: "music", action: "previous" };

  // Volume.
  if (/^(unmute|mute)( (the )?(sound|volume|audio))?$/.test(t)) return { kind: "volume", action: "mute" };
  let m = /^(?:set |turn )?(?:the )?volume (?:to |at )?(\d{1,3})(?: ?%| percent)?$/.exec(t);
  if (m) return { kind: "volume", action: "set", value: Math.min(100, Number(m[1])) };
  if (/^(volume up|turn (it|the volume|the music) up|louder|increase (the )?volume)$/.test(t)) return { kind: "volume", action: "up" };
  if (/^(volume down|turn (it|the volume|the music) down|quieter|softer|decrease (the )?volume|lower (the )?volume)$/.test(t)) return { kind: "volume", action: "down" };

  // Approvals: declining by voice is fine, approving never is (CLAUDE.md).
  if (/^(deny|decline|refuse|reject)( (it|that|this|the request|the permission))?$/.test(t)) return { kind: "deny" };
  if (/^(approve|allow|accept|yes allow)( (it|that|this|the request|the permission))?$/.test(t)) return { kind: "approve" };

  // Focus and timers.
  if (/^(stop|end|cancel) (the )?focus( timer)?$/.test(t)) return { kind: "focusStop" };
  if (/^(start |begin )?(a )?focus/.test(t)) return { kind: "focus", minutes: minutesIn(t) ?? 25 };
  m = /^remind me (?:in|after) (.+?) (?:to|that|about) (.+)$/.exec(t);
  if (m) {
    const mins = minutesIn(m[1]);
    if (mins) return { kind: "timer", minutes: mins, label: m[2] };
  }
  if (/^(set |start )?(a )?timer/.test(t) || /^\S+ (minutes?|mins?|hours?) timer$/.test(t)) {
    const mins = minutesIn(t);
    if (mins) return { kind: "timer", minutes: mins, label: "" };
  }

  // To-do.
  m = /^add (.+?) to (?:my )?(?:to-?do|todo|to do)(?: list)?$/.exec(t) ?? /^(?:add (?:a )?(?:to-?do|todo|to do)|remind me to|note to self)[:, ]+(.+)$/.exec(t);
  if (m) return { kind: "todoAdd", text: m[1].trim() };
  if (/(what('s| is)|read|show) (on )?my (to-?do|todo|to do)( list)?|my (to-?dos|todos)/.test(t)) return { kind: "todoList" };

  // Pills.
  m = /^(add|show|enable|turn on) (?:the )?(.+?)(?: pill)?$/.exec(t);
  if (m && !/ to /.test(m[2])) return { kind: "pill", action: "add", name: m[2] };
  m = /^(remove|hide|disable|turn off) (?:the )?(.+?)(?: pill)?$/.exec(t);
  if (m) return { kind: "pill", action: "remove", name: m[2] };

  // Questions Coucou answers from what it already knows.
  if (/(claude|plan|usage|limit|credits)/.test(t) && /(how much|left|usage|used|limit|reset|remaining)/.test(t)) return { kind: "planUsage" };
  if (/^(what|how)('s| is| are)? (claude|codex|my agents?|the agents?|cursor)( doing| up to)?/.test(t)) return { kind: "agents" };
  if (/^what('s| is) the time$|^what time is it$/.test(t)) return { kind: "time" };

  // Open.
  m = /^(?:open|launch|go to|start) (.+)$/.exec(t);
  if (m) return { kind: "open", target: m[1].trim() };

  return { kind: "ask", text: raw.trim() };
}

/** Where "open X" goes: a website when it looks like one, a known site, else a search. */
export function openTarget(target: string): { url: string } | { app: "music" | "spotify" | "phoneLink" | "settings" } {
  const t = target.toLowerCase().replace(/^the /, "").trim();
  if (/^(apple music|music)$/.test(t)) return { app: "music" };
  if (t === "spotify") return { app: "spotify" };
  if (/^(phone link|your phone)$/.test(t)) return { app: "phoneLink" };
  if (/^(coucou )?settings$/.test(t)) return { app: "settings" };
  const sites: Record<string, string> = {
    youtube: "https://www.youtube.com", gmail: "https://mail.google.com", github: "https://github.com",
    "google calendar": "https://calendar.google.com", calendar: "https://calendar.google.com",
    claude: "https://claude.ai", chatgpt: "https://chatgpt.com", whatsapp: "https://web.whatsapp.com",
    google: "https://www.google.com", linkedin: "https://www.linkedin.com", instagram: "https://www.instagram.com",
  };
  if (sites[t]) return { url: sites[t] };
  const host = t.replace(/\s+dot\s+/g, ".").replace(/\s+/g, "");
  if (/^[a-z0-9-]+(\.[a-z0-9-]+)+(\/\S*)?$/.test(host)) return { url: `https://${host}` };
  return { url: `https://www.google.com/search?q=${encodeURIComponent(target)}` };
}

/**
 * Every phrase Maki listens for (src-tauri/src/voice.rs): the speech engine
 * on the device only hears what's on this list, each one a command
 * parseIntent understands. `pills` are the pill names this build offers.
 */
export function voicePhrases(pills: readonly string[]): string[] {
  const out: string[] = [
    "pause", "pause the music", "stop the music", "play", "play the music", "resume", "resume the music",
    "next", "next song", "next track", "skip", "skip this", "previous", "previous song", "go back",
    "volume up", "volume down", "louder", "quieter", "turn it up", "turn it down", "mute", "unmute",
    "start focus", "start a focus", "focus", "stop focus", "end focus",
    "what's on my to do list", "read my to do list",
    "how much of my claude plan is left", "what's my claude usage", "how much claude usage is left",
    "what is claude doing", "what are my agents doing", "what time is it",
    "deny", "decline", "deny it", "approve", "allow it", "cancel", "never mind",
  ];
  for (let v = 0; v <= 100; v += 10) out.push(`set volume to ${v}`, `volume ${v}`);
  for (const n of [5, 10, 15, 20, 25, 30, 40, 45, 50, 60, 90, 120]) out.push(`start a focus for ${n} minutes`, `focus for ${n} minutes`);
  for (const n of [1, 2, 3, 4, 5, 10, 15, 20, 25, 30, 45, 60]) out.push(`set a timer for ${n} minutes`, `${n} minute timer`);
  for (const site of ["youtube", "gmail", "github", "calendar", "claude", "chatgpt", "whatsapp", "google", "linkedin", "instagram",
    "spotify", "apple music", "phone link", "settings"]) out.push(`open ${site}`);
  for (const p of pills) {
    const name = p.toLowerCase();
    out.push(`add the ${name} pill`, `remove the ${name} pill`, `add ${name}`, `remove ${name}`);
  }
  return out;
}
