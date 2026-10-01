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
  const row = h("div", { class: "int-head" }, dot(color, 7), h("b", { text: name }), h("span", { text: kind }));
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

/** Where "Open …" and the card's ↗ button go. */
export const OPEN_URLS: Record<string, string> = {
  integration_resend: "https://resend.com/emails",
  integration_vercel: "https://vercel.com/dashboard",
  integration_github: "https://github.com/pulls",
  integration_stripe: "https://dashboard.stripe.com/payments",
  integration_notion: "https://notion.so",
  integration_calcom: "https://app.cal.com/bookings",
  integration_gcal: "https://calendar.google.com",
};

function idleCard(task: AgentTask, openSettings: () => void): HTMLElement {
  const info = State.integrations[task.id];
  const configured = info?.configured ?? false;
  const error = info?.error ?? null;
  // The Claude Code pill is about hooks, not a key — the macOS wording would be
  // misleading here.
  const missing =
    task.id === "integration_claude"
      ? "Hooks not installed"
      : task.id === "integration_gcal"
        ? "Google account not connected"
        : "Key not configured";
  const label = error ?? (configured ? "Connected · loading…" : missing);
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

const GREEN = "#22C55E";
const RED = "#F4505E";
const AMBER = "#F5A524";
const GREY = "#6B7079";

/** A list row that opens `url` — the GitHub and Calendar cards are all links. */
function linkRow(accent: string, first: boolean, url: string, ...children: Node[]): HTMLElement {
  const row = h(
    "button",
    {
      class: first ? "int-row int-go first" : "int-row int-go",
      onclick: () => {
        if (url) void Bridge.openUrl(url);
      },
    },
    dot(accent, 5),
    ...children,
  );
  if (first) row.style.background = `${accent}14`;
  return row;
}

function trailing(text: string, color: string): HTMLElement {
  return h("span", { class: "int-state", style: `color:${color}`, text });
}

/** CI of the Claude Code session's branch: what its last commit's checks say. */
function ciRow(b: Record<string, unknown>, first: boolean): HTMLElement {
  const state = b.state as string | null;
  const [accent, label] = !b.pushed
    ? [GREY, "not pushed"]
    : state === "SUCCESS"
      ? [GREEN, "passing"]
      : state === "FAILURE" || state === "ERROR"
        ? [RED, "failing"]
        : state === "PENDING" || state === "EXPECTED"
          ? [AMBER, "running"]
          : [GREY, "no checks"];
  const failing = Array.isArray(b.failing) ? (b.failing as string[]) : [];
  const cells: Node[] = [h("span", { class: "int-name", text: String(b.branch ?? "") })];
  // The branch name is what gets ellipsized; the PR number stays whole.
  if (b.pr != null) cells.push(h("span", { class: "int-sub", style: "flex:0 0 auto", text: `#${b.pr}` }));
  else if (failing.length) cells.push(h("span", { class: "int-sub", text: failing[0] }));
  cells.push(trailing(label, accent));
  const url = String(b.url ?? "") || `https://github.com/${b.repo}/tree/${b.branch}`;
  const row = linkRow(accent, first, url, ...cells);
  row.title = `${b.repo} · ${b.branch}${failing.length ? `\nFailing: ${failing.join(", ")}` : ""}`;
  return row;
}

function githubCard(): HTMLElement {
  const d = get("integration_github");
  const stars = Number(d.totalStars ?? 0);
  const repos = Number(d.totalRepos ?? 0);
  const fmt = (n: number) => (n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n));

  const branch = d.branch as Record<string, unknown> | null | undefined;
  const requests = arr("integration_github", "requests");
  const pulls = arr("integration_github", "pulls").filter(
    // The branch row already stands for its own pull request — unless a
    // reviewer has had their say, which the CI row doesn't show.
    (p) =>
      !(branch && branch.pr === p.number && p.repo === branch.repo) ||
      p.decision === "APPROVED" || p.decision === "CHANGES_REQUESTED",
  );

  // Three rows at most, most pressing first: your branch's CI, reviews people
  // are waiting on from you, then your own pull requests.
  const rows: HTMLElement[] = [];
  if (branch) rows.push(ciRow(branch, true));
  for (const r of requests) {
    if (rows.length >= 3) break;
    rows.push(
      linkRow(
        AMBER, rows.length === 0, String(r.url ?? ""),
        h("span", { class: "int-name", text: `#${r.number} ${r.title}` }),
        trailing("review", AMBER),
      ),
    );
  }
  for (const p of pulls) {
    if (rows.length >= 3) break;
    const [accent, label] = p.draft
      ? [GREY, "draft"]
      : p.decision === "APPROVED"
        ? [GREEN, "approved"]
        : p.decision === "CHANGES_REQUESTED"
          ? [RED, "changes"]
          : [GREY, "waiting"];
    rows.push(
      linkRow(
        accent, rows.length === 0, String(p.url ?? ""),
        h("span", { class: "int-name", text: `#${p.number} ${p.title}` }),
        trailing(label, accent),
      ),
    );
  }

  const starCount = h(
    "span",
    { class: "int-total", title: `${repos} repositories` },
    h("i", { class: "int-star" }, svg(ICONS.star, 9)),
    h("span", { text: fmt(stars) }),
  );

  // Nothing on the go: the old overview, so the card is never empty.
  if (rows.length === 0) {
    return h(
      "div",
      { class: "int-card" },
      header(RED, "GitHub", "Overview"),
      h(
        "div",
        { class: "int-stats" },
        statRow(ICONS.star, AMBER, "Total stars", fmt(stars)),
        statRow(ICONS.stack, GREY, "Repositories", String(repos)),
      ),
    );
  }
  return h(
    "div",
    { class: "int-card" },
    header(RED, "GitHub", "Activity", starCount),
    h("div", { class: "int-rows" }, ...rows),
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

// ── Google Calendar ───────────────────────────────────────────────────────────

const GCAL = "#4285F4";

/** All-day events carry a bare YYYY-MM-DD: that day, at local midnight. */
function eventStart(e: Record<string, unknown>): Date {
  if (typeof e.startMs === "number") return new Date(e.startMs);
  const [y, m, d] = String(e.start).split("-").map(Number);
  return new Date(y, (m ?? 1) - 1, d ?? 1);
}

function sameDay(a: Date, b: Date): boolean {
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

/** "14:30" today, "Fri 09:00" later in the week, "All day" / "Fri" for all-day. */
function eventWhen(e: Record<string, unknown>, now: Date): string {
  const start = eventStart(e);
  const today = sameDay(start, now);
  const weekday = start.toLocaleDateString(undefined, { weekday: "short" });
  if (e.allDay) return today ? "All day" : weekday;
  const time = start.toLocaleTimeString(undefined, { hour: "2-digit", minute: "2-digit" });
  return today ? time : `${weekday} ${time}`;
}

function gcalCard(): HTMLElement {
  const now = new Date();
  const events = arr("integration_gcal", "events");
  // Meetings first; all-day events only fill what's left.
  const ordered = [...events.filter((e) => !e.allDay), ...events.filter((e) => e.allDay)].slice(0, 3);

  const rows = h("div", { class: "int-rows tight" });
  if (ordered.length === 0) {
    rows.append(h("div", { class: "int-empty", text: "Nothing on the calendar this week" }));
  }
  ordered.forEach((e, i) => {
    const startMs = typeof e.startMs === "number" ? e.startMs : null;
    const endMs = typeof e.endMs === "number" ? e.endMs : null;
    const ongoing = startMs != null && endMs != null && startMs <= now.getTime() && now.getTime() < endMs;
    const minutes = startMs != null ? Math.ceil((startMs - now.getTime()) / 60_000) : null;
    const soon = minutes != null && minutes > 0 && minutes <= 60;
    // Otherwise the calendar's own colour, as in Google Calendar.
    const calColor = typeof e.color === "string" && /^#[0-9a-f]{6}$/i.test(e.color) ? e.color : GCAL;
    const accent = ongoing ? GREEN : soon && minutes <= 5 ? AMBER : calColor;

    const cells: Node[] = [
      h("span", { class: "int-time", style: `color:${ongoing ? GREEN : "#8AB4F8"}`, text: ongoing ? "now" : eventWhen(e, now) }),
      h("span", { class: "int-name", text: String(e.title ?? "") }),
    ];
    // Join, for the meeting that is on or about to be: the one click that matters.
    if (i === 0 && typeof e.meetUrl === "string" && (ongoing || (minutes != null && minutes <= 15))) {
      const url = e.meetUrl;
      cells.push(
        h("span", {
          class: "int-join",
          role: "button",
          style: `color:${accent};background:${accent}24`,
          text: "Join",
          onclick: (ev: Event) => {
            ev.stopPropagation();
            void Bridge.openUrl(url);
          },
        }),
      );
    } else if (soon && !ongoing) {
      cells.push(trailing(`in ${minutes}m`, minutes <= 5 ? AMBER : "#6B7079"));
    }
    rows.append(linkRow(accent, i === 0, String(e.url ?? ""), ...cells));
  });

  const first = ordered[0];
  const kind = first && sameDay(eventStart(first), now) ? "Today" : "Upcoming";
  return h("div", { class: "int-card" }, header(GCAL, "Calendar", kind), rows);
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
    case "integration_gcal":
      // Disconnecting sends `{}`: back to the idle card, not an empty agenda.
      return Array.isArray(get(id).events);
    default:
      return false;
  }
}

export function renderIntegrationCard(task: AgentTask, hooks: IntegrationCardHooks): HTMLElement {
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
    case "integration_gcal":
      return gcalCard();
    default:
      return idleCard(task, hooks.openSettings);
  }
}

export { clear };
