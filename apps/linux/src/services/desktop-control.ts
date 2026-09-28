/** Desktop control planner + executor (Shift+M). */

import {
  desktopKey,
  desktopMedia,
  desktopOpen,
  desktopScreenshot,
  desktopTypeText,
  isTauri,
  secretsGet,
  type DesktopActionResult,
} from "../bridge/tauri.js";

export type DesktopPlanAction =
  | { type: "open"; target: string }
  | { type: "type"; text: string }
  | { type: "key"; keys: string }
  | { type: "media"; action: string }
  | { type: "wait"; ms: number }
  | { type: "say"; text: string };

export interface DesktopPlan {
  summary: string;
  actions: DesktopPlanAction[];
  needsScreen?: boolean;
}

function norm(s: string): string {
  return s.trim().toLowerCase();
}

/** Fast local planner for common Arabic/English desktop intents. */
export function planDesktopCommand(input: string): DesktopPlan {
  const raw = input.trim();
  const q = norm(raw);
  const actions: DesktopPlanAction[] = [];

  // Media
  if (
    /(?:next|التالية|التالي|غير\s*اغني|غير\s*الأغني|skip)/i.test(q) &&
    /(?:song|music|اغني|موسيقى|track)/i.test(q)
  ) {
    actions.push({ type: "media", action: "next" });
    return { summary: "Next track", actions };
  }
  if (/(?:pause|وقف|اوقف).*(?:music|اغني|موسيقى)|(?:music|اغني).*(?:pause|وقف)/i.test(q)) {
    actions.push({ type: "media", action: "pause" });
    return { summary: "Pause media", actions };
  }
  if (/(?:play|شغل).*(?:music|اغني|موسيقى)|(?:music|اغني).*(?:play|شغل)/i.test(q)) {
    actions.push({ type: "media", action: "play" });
    return { summary: "Play media", actions };
  }
  if (/(?:previous|السابق|ارجع).*(?:song|track|اغني)/i.test(q)) {
    actions.push({ type: "media", action: "previous" });
    return { summary: "Previous track", actions };
  }

  // YouTube search
  const yt =
    q.match(/(?:youtube|يوتيوب).*?(?:search|ابحث|عن)\s+(.+)/i) ||
    q.match(/(?:ابحث|search).*?(?:youtube|يوتيوب).*?(?:عن|:)?\s*(.+)/i) ||
    q.match(/(?:open|افتح)\s+(?:youtube|يوتيوب)(?:\s+(?:and\s+)?(?:search|ابحث)(?:\s+عن)?\s+(.+))?/i);
  if (yt) {
    const term = (yt[1] || "").trim();
    if (term) {
      const url = `https://www.youtube.com/results?search_query=${encodeURIComponent(term)}`;
      actions.push({ type: "open", target: url });
      return { summary: `YouTube: ${term}`, actions };
    }
    actions.push({ type: "open", target: "https://www.youtube.com" });
    return { summary: "Open YouTube", actions };
  }

  // ChatGPT
  if (/(?:chatgpt|شات\s*جبت|شاتجيبت|chat\s*gpt)/i.test(q)) {
    actions.push({ type: "open", target: "https://chatgpt.com" });
    const say = raw
      .replace(/.*(?:chatgpt|شات\s*جبت|شاتجيبت|chat\s*gpt)\s*(?:و|and|,)?\s*(?:قل|قول|tell|say)?\s*/i, "")
      .trim();
    if (say && say.length > 2 && !/^افتح|^open/i.test(say)) {
      actions.push({ type: "wait", ms: 1800 });
      actions.push({ type: "type", text: say });
      if (/(?:enter|ارسال|أرسل|send)/i.test(q)) {
        actions.push({ type: "wait", ms: 200 });
        actions.push({ type: "key", keys: "Return" });
      }
    }
    return { summary: "Open ChatGPT", actions };
  }

  // Generic open URL / app
  const openM = q.match(/(?:open|افتح)\s+(.+)/i);
  if (openM) {
    let target = openM[1].trim();
    target = target.replace(/\s+(ثم|and then|and|و)\s+.*/i, "").trim();
    if (/^https?:\/\//i.test(target)) {
      actions.push({ type: "open", target });
    } else if (/youtube|يوتيوب/i.test(target)) {
      actions.push({ type: "open", target: "https://www.youtube.com" });
    } else if (/spotify/i.test(target)) {
      actions.push({ type: "open", target: "spotify:" });
    } else if (/chrome|كروم/i.test(target)) {
      actions.push({ type: "open", target: "google-chrome" });
    } else if (/firefox|فايرفوكس/i.test(target)) {
      actions.push({ type: "open", target: "firefox" });
    } else if (/terminal|ترمنال/i.test(target)) {
      actions.push({ type: "open", target: "x-terminal-emulator" });
    } else {
      actions.push({ type: "open", target: target.split(/\s+/)[0] });
    }
  }

  // Press enter / keys
  if (/(?:press|اضغط)\s*(?:enter|الادخال|إدخال)/i.test(q) || /^enter$/i.test(q)) {
    actions.push({ type: "key", keys: "Return" });
  }
  if (/(?:press|اضغط)\s*(?:esc|escape)/i.test(q)) {
    actions.push({ type: "key", keys: "Escape" });
  }

  // Analyze screen
  if (
    /(?:حلل|analyze|analyse|what.*(on|in).*screen|شنو موجود|شو في الشاش|look at.*(screen|display))/i.test(
      q,
    )
  ) {
    return {
      summary: "Analyze screen",
      actions: [{ type: "say", text: "Capturing screen…" }],
      needsScreen: true,
    };
  }

  if (actions.length === 0) {
    // Fallback: treat as type-into-focused + optional enter
    if (/(?:type|اكتب)\s+(.+)/i.test(raw)) {
      const m = raw.match(/(?:type|اكتب)\s+(.+)/i);
      if (m) actions.push({ type: "type", text: m[1].trim() });
    } else {
      return {
        summary: "Need screen context",
        actions: [],
        needsScreen: true,
      };
    }
  }

  return { summary: actions.map((a) => a.type).join(" → ") || "OK", actions };
}

export async function executeDesktopPlan(
  plan: DesktopPlan,
  onSay?: (text: string) => void,
): Promise<DesktopActionResult[]> {
  const results: DesktopActionResult[] = [];
  for (const step of plan.actions) {
    switch (step.type) {
      case "wait":
        await new Promise((r) => setTimeout(r, step.ms));
        results.push({ ok: true, message: `wait ${step.ms}ms` });
        break;
      case "say":
        onSay?.(step.text);
        results.push({ ok: true, message: step.text });
        break;
      case "open":
        results.push(await desktopOpen(step.target));
        break;
      case "type":
        results.push(await desktopTypeText(step.text));
        break;
      case "key":
        results.push(await desktopKey(step.keys));
        break;
      case "media":
        results.push(await desktopMedia(step.action));
        break;
    }
  }
  return results;
}

/** Optional vision pass via Anthropic when analyzing the screen. */
export async function analyzeScreenWithVision(
  userPrompt: string,
  dataUrl: string,
): Promise<string> {
  const key = await secretsGet("anthropic-api-key");
  if (!key) {
    return "Screen captured. Add an Anthropic API key in Settings to get a full analysis, or ask me to open/click something specific.";
  }

  const b64 = dataUrl.replace(/^data:image\/\w+;base64,/, "");
  const res = await fetch("https://api.anthropic.com/v1/messages", {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "x-api-key": key,
      "anthropic-version": "2023-06-01",
    },
    body: JSON.stringify({
      model: "claude-sonnet-4-20250514",
      max_tokens: 800,
      messages: [
        {
          role: "user",
          content: [
            {
              type: "image",
              source: { type: "base64", media_type: "image/png", data: b64 },
            },
            {
              type: "text",
              text: `You are Coucou, a desktop companion. The user asked: ${userPrompt}\nDescribe what is on screen briefly, then suggest concrete next actions (open, type, key, media). Reply in the user's language.`,
            },
          ],
        },
      ],
    }),
  });

  if (!res.ok) {
    const t = await res.text();
    throw new Error(`Vision API ${res.status}: ${t.slice(0, 200)}`);
  }
  const json = (await res.json()) as {
    content?: Array<{ type: string; text?: string }>;
  };
  return json.content?.find((c) => c.type === "text")?.text ?? "No analysis.";
}

export async function runDesktopRequest(
  input: string,
  onSay?: (text: string) => void,
): Promise<{ plan: DesktopPlan; analysis?: string; results: DesktopActionResult[] }> {
  if (!isTauri()) {
    return {
      plan: { summary: "Desktop control needs the Coucou app", actions: [] },
      results: [{ ok: false, message: "Run npm run tauri:dev (not Vite-only)." }],
    };
  }

  const plan = planDesktopCommand(input);
  let analysis: string | undefined;

  if (plan.needsScreen) {
    onSay?.("Looking at your screen…");
    const shot = await desktopScreenshot();
    if (!shot.ok || !shot.data) {
      return { plan, results: [shot] };
    }
    try {
      analysis = await analyzeScreenWithVision(input, shot.data);
      onSay?.(analysis);
    } catch (e) {
      analysis = e instanceof Error ? e.message : String(e);
      onSay?.(analysis);
    }
  }

  const results = await executeDesktopPlan(plan, onSay);
  return { plan, analysis, results };
}
