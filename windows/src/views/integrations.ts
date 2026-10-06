// Integration cards shown in the overview's left card — DOM ports of
// IntegrationCardView and friends from IslandViewContent.swift.
//
// Cal.com is the one simplification: macOS shows a three-level calendar
// (month → day → booking); here it is the list of upcoming bookings.

import { h, svg, clear, dot } from "./dom";
import { ICONS } from "./icons";
import { COLOR } from "./palette";
import { State, type AgentTask } from "../core/state";
import { Bridge, type GithubActivityKind, type GithubData, type GithubTarget } from "../core/bridge";

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
  // The Claude Code pill is about hooks, not a key — the macOS wording would be
  // misleading here.
  const missing = task.id === "integration_claude" ? "Hooks not installed" : "Key not configured";
  const label = error ?? (configured ? "Connected · loading…" : missing);
  const statusColor = error || !configured ? "#F4505E" : "#22C55E";

  const actions = h("div", { class: "int-actions" });
  if (task.id === "integration_claude") {
    actions.append(
      h("button", {
        class: "link-btn",
        style: `color:${task.color}b3`,
        // The app the last session ran in; Visual Studio Code until one has.
        text: State.session.client === "desktop" ? "Open Claude" : "Open Visual Studio Code",
        onclick: () =>
          void (State.session.client === "desktop" ? Bridge.openClaudeApp() : Bridge.openInVSCode(task.sessionCwd ?? null)),
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
    header(task.color, task.id === "integration_claude" ? State.clientName : task.name, "Integration"),
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

/**
 * GitHub's dark-theme contribution colours, level 0 to 4 (Primer's
 * contribution-default-bgColor-*). The empty day is lifted a shade, since the
 * island's card is a little lighter than GitHub's page and #151B23 would
 * vanish on it.
 */
export const GITHUB_LEVELS = ["#1C2128", "#033A16", "#196C2E", "#2EA043", "#56D364"];

/** The GitHub pill's data, or null before the first answer. */
export function githubData(): GithubData | null {
  const d = get("integration_github") as Partial<GithubData>;
  return typeof d.login === "string" ? (d as GithubData) : null;
}

/**
 * Icon and colour of each kind of activity. The colours are Mochi's own state
 * colours rather than GitHub's: a merged PR is green like `finished`, a push
 * blue like `working`, an open issue amber like `approval`.
 */
export const ACTIVITY_STYLE: Record<GithubActivityKind | "review", { icon: string; color: string }> = {
  push: { icon: ICONS.commit, color: COLOR.blue },
  pr_opened: { icon: ICONS.pullRequest, color: COLOR.indigo },
  pr_merged: { icon: ICONS.merge, color: COLOR.green },
  pr_closed: { icon: ICONS.pullRequest, color: COLOR.grey },
  issue_opened: { icon: ICONS.issue, color: COLOR.amber },
  issue_closed: { icon: ICONS.issue, color: COLOR.grey },
  release: { icon: ICONS.tag, color: COLOR.cyan },
  create: { icon: ICONS.add, color: COLOR.dim },
  // A review asked for your eyes, like a question: Mochi's `question` cyan.
  review: { icon: ICONS.pullRequest, color: COLOR.cyan },
};

/** "edu/coucou" → "coucou" for your own repositories, the full name otherwise. */
export function repoName(repo: string, login: string): string {
  const [owner, name] = repo.split("/");
  return name && owner.toLowerCase() === login.toLowerCase() ? name : repo;
}

/** 1284 → "1.3k", as the macOS card writes star counts. */
export const compact = (n: number) => (n >= 1000 ? `${(n / 1000).toFixed(1)}k` : String(n));

/** Days of the year's graph the card shows beside its figure: the last week. */
const CARD_DAYS = 7;
/** Lines of activity the card carries; it shows as many as its height allows. */
const CARD_LINES = 4;

/** What the panel is asked to open on: a line of activity's sheet, or nothing — its lists. */
export interface GithubOpening {
  target?: GithubTarget;
  label?: string;
  url?: string;
}

/**
 * What a line of the card says after its title: a fact of its own — "#12",
 * "v0.3.0", "3 commits" — or, failing one, the project it happened in. A
 * push's branch says less than its project.
 */
function activityWhere(a: GithubData["activity"][number], login: string): { text: string; fact: boolean } {
  const first = a.detail?.split(" · ")[0] ?? "";
  return /^(#\d+|v?\d)/.test(first) ? { text: first, fact: true } : { text: repoName(a.repo, login), fact: false };
}

/**
 * The summary in the overview, laid out like the Stripe card: one figure, then
 * what happened lately. The figure is the year's contributions, with the last
 * seven days as the squares GitHub draws them; it opens the panel. Each line
 * under it opens the panel on its own sheet.
 */
function githubCard(onPanel: (open?: GithubOpening) => void): HTMLElement {
  const d = githubData()!;
  const error = State.integrations.integration_github?.error ?? null;
  const c = d.contributions;

  const week = c
    ? h(
        "span",
        { class: "int-week", title: `The last ${CARD_DAYS} days` },
        ...c.levels.slice(-CARD_DAYS).map((level) => h("i", { style: `background:${GITHUB_LEVELS[level] ?? GITHUB_LEVELS[0]}` })),
      )
    : null;
  // Without the year (the token may not read it), the stars are the figure.
  // While the pill has news, the way in leads to what the news is about.
  const news = State.integrations.integration_github?.news?.open;
  const figure = h(
    "button",
    { class: "int-balance int-figure", title: news?.title ?? "Open the GitHub panel", onclick: () => onPanel() },
    h("span", { text: c ? c.total.toLocaleString("en-US") : compact(d.totalStars) }),
    h("i", { text: c ? "contributions" : "stars" }),
    week,
  );

  const rows = h("div", { class: "int-rows tight" });
  for (const a of d.activity.slice(0, CARD_LINES)) {
    const style = ACTIVITY_STYLE[a.kind];
    const where = activityWhere(a, d.login);
    rows.append(
      h(
        "button",
        {
          class: "int-row int-go",
          // The whole of what the line cuts short.
          title: [a.title, repoName(a.repo, d.login), a.detail].filter(Boolean).join(" · "),
          onclick: () => onPanel({ target: a.target ?? undefined, label: a.title, url: a.url }),
        },
        dot(style.color, 5),
        h("span", { class: "int-name", text: a.title }),
        // A fact wears the line's colour, like an amount; a project is where, in grey.
        where.fact
          ? h("span", { class: "int-amount", style: `color:${style.color}`, text: where.text })
          : h("span", { class: "int-where", text: where.text }),
        h("span", { class: "int-ago", text: timeAgo(a.at) }),
      ),
    );
  }
  if (d.activity.length === 0) rows.append(h("div", { class: "int-empty", text: "Nothing in the last 30 days" }));

  const stars = c && d.totalStars > 0
    ? h("span", { class: "int-total", title: "Stars across your repositories" },
        h("i", { class: "int-star" }, svg(ICONS.star, 9)), h("span", { text: compact(d.totalStars) }))
    : undefined;
  const card = h("div", { class: "int-card" }, header(COLOR.red, "GitHub", `@${d.login}`, stars));
  // What's shown is the last good answer; say why it isn't fresher.
  if (error) card.append(h("div", { class: "int-status" }, dot(COLOR.red, 5), h("span", { text: error })));
  card.append(figure, rows);
  return card;
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
  /** A view of its own, for the pills that outgrew the card (GitHub) — on a sheet, or on its lists. */
  openPanel(open?: GithubOpening): void;
}

/** True when this integration has data worth showing instead of the idle card. */
export function hasIntegrationData(id: string): boolean {
  const info = State.integrations[id];
  // GitHub keeps its last good snapshot through an error and says so itself;
  // a removed token, though, must not leave the old account on screen.
  if (id === "integration_github") return info?.configured !== false && githubData() != null;
  if (!info || info.error) return false;
  switch (id) {
    case "integration_vercel":
      return arr(id, "deployments").length > 0;
    case "integration_resend":
      return arr(id, "emails").length > 0;
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
      return githubCard(hooks.openPanel);
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
