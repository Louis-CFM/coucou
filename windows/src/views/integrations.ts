// Integration cards shown in the overview's left card — DOM ports of
// IntegrationCardView and friends from IslandViewContent.swift.
//
// Cal.com is the one simplification: macOS shows a three-level calendar
// (month → day → booking); here it is the list of upcoming bookings.

import { h, svg, clear, dot } from "./dom";
import { ICONS } from "./icons";
import { State, type AgentTask } from "../core/state";
import { Bridge } from "../core/bridge";

/** Same shape as the Swift `timeAgo` computed properties. */
export function timeAgo(value: unknown): string {
  const date = typeof value === "number" ? new Date(value) : new Date(String(value));
  const diff = (Date.now() - date.getTime()) / 1000;
  if (!Number.isFinite(diff)) return "";
  if (diff < 60) return "just now";
  if (diff < 3600) return `${Math.floor(diff / 60)}m`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h`;
  return `${Math.floor(diff / 86400)}d`;
}

function header(color: string, name: string, kind: string, extra?: Node): HTMLElement {
  const row = h("div", { class: "int-head" }, dot(color, 7), h("b", { text: name }));
  // An empty kind would still occupy a flex gap, leaving a phantom indent.
  if (kind) row.append(h("span", { text: kind }));
  if (extra) row.append(extra);
  return row;
}

/** Highlighted first row + plain rows, the layout every list card shares. */
function listRow(accent: string, first: boolean, ...children: Node[]): HTMLElement {
  const row = h("div", { class: first ? "int-row first" : "int-row" }, dot(accent, 5), ...children);
  if (first) row.style.background = `${accent}14`;
  return row;
}

function get(id: string): Record<string, unknown> {
  return (State.integrations[id]?.data ?? {}) as Record<string, unknown>;
}

function arr(id: string, key: string): Record<string, unknown>[] {
  const v = get(id)[key];
  return Array.isArray(v) ? (v as Record<string, unknown>[]) : [];
}

// ── Not configured / idle ─────────────────────────────────────────────────────

const OPEN_URLS: Record<string, string> = {
  integration_resend: "https://resend.com/emails",
  integration_vercel: "https://vercel.com/dashboard",
  integration_github: "https://github.com",
  integration_stripe: "https://dashboard.stripe.com/payments",
  integration_notion: "https://notion.so",
  integration_calcom: "https://app.cal.com/bookings",
};

function idleCard(task: AgentTask, openSettings: () => void): HTMLElement {
  const info = State.integrations[task.id];
  const configured = info?.configured ?? false;
  const error = info?.error ?? null;
  // The Claude Code and agent pills are about hooks, not a key, so the macOS
  // wording would mislead here. `configured` for those comes from the real
  // per-agent hook status (island/integrations.ts), not from an API key — which
  // is why an agent whose hooks were never installed reads "Hooks not installed"
  // here instead of pretending to be ready.
  const isHookPill = task.id === "integration_claude" || task.id.startsWith("agent_");
  const missing = isHookPill ? "Hooks not installed" : "Key not configured";
  const label = error ?? (
    configured
      ? (isHookPill ? "Connected · waiting for events" : "Connected · loading…")
      : missing
  );
  const statusColor = error || !configured ? "#F4505E" : "#22C55E";

  const actions = h("div", { class: "int-actions" });
  if (task.id === "integration_claude") {
    actions.append(
      h("button", {
        class: "link-btn",
        style: `color:${task.color}b3`,
        text: "Open Visual Studio Code",
        onclick: () => void Bridge.openInVSCode(task.sessionCwd ?? null),
      }),
    );
  } else if (task.id === "integration_n8n") {
    actions.append(
      h("button", {
        class: "link-btn",
        style: `color:${task.color}d9`,
        text: "Open n8n",
        onclick: () => void Bridge.openN8n(),
      }),
    );
  } else if (OPEN_URLS[task.id]) {
    actions.append(
      h("button", {
        class: "link-btn",
        style: `color:${task.color}d9`,
        text: `Open ${task.name}`,
        onclick: () => void Bridge.openUrl(OPEN_URLS[task.id]),
      }),
    );
  }
  if (configured) {
    actions.append(
      h("button", {
        class: "link-btn",
        style: `color:${task.color}d9`,
        text: "Refresh",
        onclick: () => void Bridge.refreshIntegration(task.id),
      }),
    );
  } else {
    actions.append(
      h("button", { class: "link-btn", style: "color:#8e939c", text: "Settings…", onclick: openSettings }),
    );
  }

  return h(
    "div",
    { class: "int-card" },
    header(task.color, task.id === "integration_claude" ? "VS Code" : task.name, "Integration"),
    h("div", { class: "int-status" }, dot(statusColor, 5), h("span", { text: label })),
    actions,
  );
}

/**
 * The card an agent pill shows: its live state plus the last few steps it
 * reported. Unlike an integration card there is nothing to poll — this only
 * ever reflects what arrived over the hook relay.
 */
function agentCard(task: AgentTask): HTMLElement {
  const stateLabel =
    task.state === "finished" ? "Finished" :
    task.state === "error" ? "Error" :
    task.state === "approval" ? "Needs permission" :
    task.state === "working" || task.state === "thinking" ? "Working" :
    "Ready";
  const stateColor =
    task.state === "error" ? "#F4505E" :
    task.state === "finished" ? "#22C55E" :
    task.color;
  const rows = h("div", { class: "int-rows agent-rows" });
  // `generating` and `turn_complete` are Pi's keep-alive beats: they would fill
  // the card with two permanent rows that say nothing.
  const steps = task.steps.filter((step) => step !== "generating" && step !== "turn_complete");

  // No rows at all when nothing has been reported. The card's own status line
  // already says "Ready" — this block used to append a second, identical one, so
  // a freshly launched Coucou showed "● Ready" twice on every agent. An empty
  // log is the normal state at startup, which is why it was so easy to miss.
  if (steps.length > 0) {
    steps.slice(-5).forEach((step, index, visible) => {
      rows.append(listRow(stateColor, index === visible.length - 1,
        h("span", { class: "int-name", text: step }),
      ));
    });
    requestAnimationFrame(() => {
      rows.scrollTop = rows.scrollHeight;
    });
  }

  return h(
    "div",
    { class: "int-card" },
    header(task.color, task.name, "Agent"),
    h("div", { class: "int-status" }, dot(stateColor, 5), h("span", { text: stateLabel })),
    rows,
  );
}

// ── Vercel ────────────────────────────────────────────────────────────────────

function vercelCard(onDetail: () => void): HTMLElement {
  const deployments = arr("integration_vercel", "deployments");
  const rows = h("div", { class: "int-rows" });
  deployments.slice(0, 3).forEach((d, i) => {
    const accent = d.state === "READY" ? "#22C55E" : "#F4505E";
    const name = h("span", { class: "int-name", text: String(d.projectName ?? "") });
    const ago = h("span", { class: "int-ago", text: timeAgo(d.createdAt) });
    if (i === 0) {
      const more = h(
        "button",
        { class: "int-more", title: "Details", onclick: onDetail },
        svg(ICONS.ellipsis, 8),
      );
      rows.append(listRow(accent, true, name, ago, more));
    } else {
      rows.append(listRow(accent, false, name, ago));
    }
  });
  return h("div", { class: "int-card" }, header("#7C5CFF", "Vercel", "Deployments"), rows);
}

function vercelDetail(onBack: () => void): HTMLElement {
  const d = arr("integration_vercel", "deployments")[0] ?? {};
  const success = d.state === "READY";
  const accent = success ? "#22C55E" : "#F4505E";
  const status = success ? "Ready" : d.state === "CANCELED" ? "Canceled" : "Error";
  const body = h("div", { class: "int-detail-body" });
  if (d.commitMessage) body.append(h("div", { class: "int-commit", text: String(d.commitMessage) }));
  const meta = h("div", { class: "int-meta" });
  if (d.branch) meta.append(h("span", { text: String(d.branch) }));
  meta.append(h("span", { text: `${timeAgo(d.createdAt)} ago` }));
  body.append(meta);
  if (d.url) {
    body.append(
      h("button", {
        class: "int-link",
        text: String(d.url),
        onclick: () => void Bridge.openUrl(`https://${d.url}`),
      }),
    );
  }
  return h(
    "div",
    { class: "int-card detail" },
    h(
      "div",
      { class: "int-detail-head" },
      h("button", { class: "int-back", onclick: onBack }, svg(ICONS.chevronLeft, 10, { stroke: 2.4 })),
      dot(accent, 6),
      h("b", { text: String(d.projectName ?? "Deployment") }),
      h("span", { class: "int-badge", style: `color:${accent};background:${accent}24`, text: status }),
    ),
    body,
  );
}

// ── Resend ────────────────────────────────────────────────────────────────────

function resendCard(): HTMLElement {
  const emails = arr("integration_resend", "emails");
  const total = get("integration_resend").total;
  const extra =
    total != null
      ? h("span", { class: "int-total" }, h("i", { class: "pulse" }), h("span", { text: String(total) }))
      : undefined;
  const rows = h("div", { class: "int-rows" });
  emails.slice(0, 3).forEach((e, i) => {
    const delivered = e.lastEvent === "delivered";
    const accent = delivered ? "#22C55E" : "#F4505E";
    const to = Array.isArray(e.to) ? String(e.to[0] ?? "?") : "?";
    const short = to.split("@")[0];
    const cells: Node[] = [
      h("span", { class: "int-name", text: short }),
      h("span", { class: "int-ago", text: timeAgo(e.createdAt) }),
    ];
    if (i === 0 && e.subject) cells.push(h("span", { class: "int-sub", text: String(e.subject) }));
    rows.append(listRow(accent, i === 0, ...cells));
  });
  return h("div", { class: "int-card" }, header("#22C55E", "Resend", "Emails", extra), rows);
}

// ── GitHub ────────────────────────────────────────────────────────────────────

function statRow(icon: string, color: string, label: string, value: string): HTMLElement {
  return h(
    "div",
    { class: "int-stat" },
    h("i", { class: "int-stat-icon", style: `color:${color}` }, svg(icon, 10)),
    h("span", { class: "int-stat-label", text: label }),
    h("span", { class: "int-stat-value", text: value }),
  );
}

function githubCard(): HTMLElement {
  const d = get("integration_github");
  const stars = Number(d.totalStars ?? 0);
  const repos = Number(d.totalRepos ?? 0);
  const fmt = (n: number) => (n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n));
  return h(
    "div",
    { class: "int-card" },
    header("#F4505E", "GitHub", "Overview"),
    h(
      "div",
      { class: "int-stats" },
      statRow(ICONS.star, "#F5A524", "Total stars", fmt(stars)),
      statRow(ICONS.stack, "#6B7079", "Repositories", String(repos)),
    ),
  );
}

// ── Music ───────────────────────────────────────────────────────────────────

/**
 * The music pill, fed by Global Media Control.
 *
 * Unlike every other integration here, nothing is polled: Rust pushes
 * `media-changed` whenever the session changes, so this only has to read what
 * it was handed.
 */
function musicCard(task: AgentTask): HTMLElement {
  const d = State.integrations[task.id]?.data ?? {};
  const title = typeof d.title === "string" ? d.title : "";
  const artist = typeof d.artist === "string" ? d.artist : "";
  const album = typeof d.album === "string" ? d.album : "";
  const playing = d.playing === true;
  const idle = d.idle === true || (!title && d.app !== undefined);

  // Transport buttons hide themselves rather than offering controls the player
  // will refuse: GSMTC answers false for anything an app did not advertise, and
  // a row of dead buttons is worse than a shorter row.
  const track = (id: string) =>
    !idle && (typeof d[id] === "boolean" ? d[id] === true : true);

  const control = (cmd: "playPause" | "next" | "previous", icon: string, label: string) =>
    h("button", {
      class: "music-btn",
      title: label,
      "aria-label": label,
      onclick: () => {
        void Bridge.mediaCommand(cmd);
      },
    }, svg(icon, 11));

  // Status sits in the header, right beside the name, instead of claiming a
  // row of its own between the title and the track.
  const status = h(
    "span",
    { class: "music-status" },
    dot(idle ? "#6B7079" : playing ? "#22C55E" : "#FA2D48", 7),
    h("span", { text: idle ? "No media" : playing ? "Playing" : "Paused" }),
  );

  const meta = h("div", { class: "music-meta" });
  if (!idle && title) meta.append(h("div", { class: "music-title", text: title }));
  if (artist) meta.append(h("div", { class: "music-artist", text: artist }));
  // Album is genuinely absent for some players — YouTube Music publishes none —
  // so the line is omitted rather than left blank.
  if (album) meta.append(h("div", { class: "music-album", text: album }));

  const bar = h("div", { class: "music-controls" });
  if (!idle) {
    if (track("canPrevious")) bar.append(control("previous", ICONS.skipBack, "Previous"));
    bar.append(control("playPause", playing ? ICONS.pause : ICONS.play, playing ? "Pause" : "Play"));
    if (track("canNext")) bar.append(control("next", ICONS.skipNext, "Next"));
  }

  return h(
    "div",
    { class: "int-card" },
    header("#FA2D48", "Music", "", status),
    meta,
    bar,
  );
}

// ── Stripe ────────────────────────────────────────────────────────────────────

function stripeCard(): HTMLElement {
  const d = get("integration_stripe");
  const balance = (Number(d.balance ?? 0) / 100).toFixed(2);
  const currency = String(d.currency ?? "eur").toUpperCase();
  const rows = h("div", { class: "int-rows tight" });
  for (const p of arr("integration_stripe", "payments")) {
    const success = p.status === "succeeded";
    const accent = success ? "#22C55E" : "#F4505E";
    rows.append(
      h(
        "div",
        { class: "int-row" },
        dot(accent, 5),
        h("span", { class: "int-name", text: String(p.description ?? "Payment") }),
        h("span", {
          class: "int-amount",
          style: "color:#22c55e",
          text: `+${(Number(p.amount ?? 0) / 100).toFixed(2)}`,
        }),
        h("span", { class: "int-ago", text: timeAgo(p.createdAt) }),
      ),
    );
  }
  return h(
    "div",
    { class: "int-card" },
    header("#0570DE", "Stripe", "Payments"),
    h("div", { class: "int-balance" }, h("span", { text: balance }), h("i", { text: currency })),
    rows,
  );
}

// ── Notion ────────────────────────────────────────────────────────────────────

function notionCard(): HTMLElement {
  const rows = h("div", { class: "int-rows tight" });
  for (const p of arr("integration_notion", "pages").slice(0, 3)) {
    rows.append(
      h(
        "button",
        {
          class: "int-page",
          onclick: () => {
            if (typeof p.url === "string") void Bridge.openUrl(p.url);
          },
        },
        p.emoji
          ? h("span", { class: "int-emoji", text: String(p.emoji) })
          : h("i", { class: "int-emoji" }, svg(ICONS.doc, 9)),
        h("span", { class: "int-name", text: String(p.title ?? "Untitled") }),
        h("span", { class: "int-ago", text: timeAgo(p.lastEditedAt) }),
      ),
    );
  }
  return h("div", { class: "int-card" }, header("#E8E8E8", "Notion", "Recent"), rows);
}

// ── Cal.com ───────────────────────────────────────────────────────────────────

function calcomCard(): HTMLElement {
  const bookings = arr("integration_calcom", "bookings")
    .slice()
    .sort((a, b) => new Date(String(a.start)).getTime() - new Date(String(b.start)).getTime());
  const rows = h("div", { class: "int-rows tight" });
  if (bookings.length === 0) {
    rows.append(h("div", { class: "int-empty", text: "No calls scheduled" }));
  }
  for (const b of bookings.slice(0, 3)) {
    const when = new Date(String(b.start));
    const day = when.toLocaleDateString(undefined, { day: "2-digit", month: "2-digit" });
    const time = when.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
    rows.append(
      h(
        "div",
        { class: "int-row" },
        dot("#C9956A", 4),
        h("span", { class: "int-time", text: `${day} ${time}` }),
        h("span", { class: "int-name", text: String(b.title ?? "Meeting") }),
      ),
    );
  }
  return h("div", { class: "int-card" }, header("#C9956A", "Cal.com", "Schedule"), rows);
}

// ── n8n ───────────────────────────────────────────────────────────────────────

function n8nCard(task: AgentTask, onDetail: () => void, openSettings: () => void): HTMLElement {
  const hasActivity = task.steps.length > 0 && (task.state === "finished" || task.state === "error");
  if (!hasActivity) return idleCard(task, openSettings);
  const success = task.state === "finished";
  const accent = success ? "#22C55E" : "#F4505E";
  return h(
    "div",
    { class: "int-card" },
    header("#F29B38", "n8n", "Workflow"),
    h(
      "div",
      { class: "int-actions" },
      h(
        "button",
        {
          class: "int-pill",
          style: `background:${accent}1a;border-color:${accent}38`,
          onclick: onDetail,
        },
        dot(accent, 5),
        h("span", { class: "int-name", text: task.steps[0] ?? "Workflow" }),
        svg(ICONS.ellipsis, 8),
      ),
    ),
  );
}

function n8nDetail(task: AgentTask, onBack: () => void): HTMLElement {
  const success = task.state === "finished";
  const accent = success ? "#22C55E" : "#F4505E";
  const detail = task.steps[1];
  return h(
    "div",
    { class: "int-card detail" },
    h(
      "div",
      { class: "int-detail-head" },
      h("button", { class: "int-back", onclick: onBack }, svg(ICONS.chevronLeft, 10, { stroke: 2.4 })),
      dot(accent, 6),
      h("b", { text: task.steps[0] ?? "Workflow" }),
      h("span", {
        class: "int-badge",
        style: `color:${accent};background:${accent}24`,
        text: success ? "Success" : "Failed",
      }),
    ),
    detail
      ? h("pre", { class: "int-detail-text", text: detail })
      : h("div", {
          class: "int-status",
          text: success ? "Completed successfully." : "No error details available.",
        }),
  );
}

// ── Dispatch ──────────────────────────────────────────────────────────────────

export interface IntegrationCardHooks {
  detailOpen: boolean;
  openDetail(): void;
  closeDetail(): void;
  openSettings(): void;
}

/** True when this integration has data worth showing instead of the idle card. */
export function hasIntegrationData(id: string): boolean {
  const info = State.integrations[id];
  if (!info || info.error) return false;
  switch (id) {
    case "integration_vercel":
      return arr(id, "deployments").length > 0;
    case "integration_resend":
      return arr(id, "emails").length > 0;
    case "integration_github":
      return get(id).totalRepos != null;
    case "integration_stripe":
      return info.loaded;
    case "integration_notion":
      return arr(id, "pages").length > 0;
    case "integration_calcom":
      return info.loaded;
    default:
      return false;
  }
}

export function renderIntegrationCard(task: AgentTask, hooks: IntegrationCardHooks): HTMLElement {
  // An agent pill has no poller behind it: its card is the hook feed itself.
  if (task.source === "agent") return agentCard(task);
  if (task.id === "integration_music") return musicCard(task);
  if (task.id === "integration_n8n") {
    const hasActivity = task.steps.length > 0 && (task.state === "finished" || task.state === "error");
    return hooks.detailOpen && hasActivity
      ? n8nDetail(task, hooks.closeDetail)
      : n8nCard(task, hooks.openDetail, hooks.openSettings);
  }
  if (task.id === "integration_vercel" && hasIntegrationData(task.id)) {
    return hooks.detailOpen ? vercelDetail(hooks.closeDetail) : vercelCard(hooks.openDetail);
  }
  if (!hasIntegrationData(task.id)) return idleCard(task, hooks.openSettings);

  switch (task.id) {
    case "integration_resend":
      return resendCard();
    case "integration_github":
      return githubCard();
    case "integration_stripe":
      return stripeCard();
    case "integration_notion":
      return notionCard();
    case "integration_calcom":
      return calcomCard();
    default:
      return idleCard(task, hooks.openSettings);
  }
}

export { clear };
