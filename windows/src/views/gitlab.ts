// The GitLab card once the pulse is in: views/github.ts's card for the GitLab
// pill — same markup and classes (so same look and same Ctrl+↓/↑/O keys), with
// GitLab's wording, its merge requests and pipelines, and links that may only
// point at the configured instance. The logic lives in core/github.ts and
// core/gitlab.ts.
//
// Without a pulse the card stays the projects + stars overview in integrations.ts.

import { h, svg, dot } from "./dom";
import { tl } from "../i18n/i18n";
import { ICONS } from "./icons";
import { rowOpens } from "./github";
import { Bridge } from "../core/bridge";
import {
  CI_COLORS, GH_STRINGS, GRID_WEEKS, activityHeader, ciWord, contributionColor,
  formatCount, lastDays, lastWeeks, mainCISummary, myPRsValue, shortRepo, weekColumn, worstCI,
  type ContributionDay, type GitHubActivity, type GitHubPR, type GitHubPulse, type GitHubRepoCI,
  type GitHubStats,
} from "../core/github";
import { GL_STRINGS, glSectionTitle, gitlabProfileUrl, pipelinesUrl, safeGitLabUrl, type GitLabSection } from "../core/gitlab";

const GITLAB_ORANGE = "#FC6D26";

/** Which list the detail view shows; kept across re-renders of the card. */
let openSection: GitLabSection = "myPRs";

/** Opens `url` if it points at `baseUrl`, the instance the token belongs to. */
function open(url: string, baseUrl: string) {
  const safe = safeGitLabUrl(url, baseUrl);
  if (safe) void Bridge.openUrl(safe);
}

/** Seven small squares: the last week of activity. */
function miniRow(activity: GitHubActivity): HTMLElement {
  const row = h("span", { class: "gh-mini" });
  for (const day of lastDays(activity, 7)) {
    row.append(h("i", { style: `background:${contributionColor(day.level)}` }));
  }
  return row;
}

function statButton(icon: SVGSVGElement, color: string, label: string, value: string, onClick: () => void): HTMLElement {
  return h(
    "button",
    { class: "int-stat gh-stat", onclick: onClick },
    h("i", { class: "int-stat-icon", style: `color:${color}` }, icon),
    h("span", { class: "int-stat-label", text: label }),
    h("span", { class: "int-stat-value", text: value }),
  );
}

// ── Card ──────────────────────────────────────────────────────────────────────

export function gitlabPulseCard(
  pulse: GitHubPulse,
  stats: GitHubStats | null,
  activity: GitHubActivity | null,
  openDetail: () => void,
): HTMLElement {
  const show = (section: GitLabSection) => {
    openSection = section;
    void Bridge.gitlabRefresh(section === "activity" ? "activity" : "pulse");
    openDetail();
  };

  const head = h("div", { class: "int-head" }, dot(GITLAB_ORANGE, 7), h("b", { text: GL_STRINGS.title }));
  if (stats || activity) {
    const spark = h("button", { class: "gh-spark", onclick: () => show("activity") });
    if (stats) spark.append(h("span", { text: `★ ${formatCount(stats.totalStars)}` }));
    if (activity) spark.append(miniRow(activity));
    head.append(spark);
  } else {
    head.append(h("span", { text: GH_STRINGS.overview }));
  }
  // The panel with every merge request and the threads waiting for you.
  head.append(h("button", {
    class: "gl-expand",
    title: tl("Open the merge request panel"),
    "aria-label": tl("Open the merge request panel"),
    onclick: () => void Bridge.gitlabPanelToggle(),
  }, svg(ICONS.panel, 10, { stroke: 2.2 })));

  const mrColor = CI_COLORS[worstCI(pulse.myPRs.map((p) => p.ci))];
  const reviews = pulse.toReview.length;
  const main = mainCISummary(pulse.mainCI);

  return h(
    "div",
    { class: "int-card" },
    head,
    h(
      "div",
      { class: "int-stats gh-rows" },
      statButton(svg(ICONS.pull, 10, { stroke: 2.2 }), mrColor, GL_STRINGS.myPRs, myPRsValue(pulse.myPRs),
        () => show("myPRs")),
      statButton(svg(ICONS.eye, 10, { stroke: 2.2 }), reviews > 0 ? "#8AB4F8" : "#6B7079", GH_STRINGS.toReview,
        String(reviews), () => show("toReview")),
      statButton(svg(main.failing ? ICONS.octagonX : ICONS.seal, 10, { evenOdd: true }), main.color,
        GL_STRINGS.mainCI, main.value, () => show("mainCI")),
    ),
  );
}

// ── Detail: lists ─────────────────────────────────────────────────────────────

function backButton(title: string, onBack: () => void): HTMLElement {
  return h(
    "button",
    { class: "gh-back", onclick: onBack },
    svg(ICONS.chevronLeft, 9, { stroke: 2.6 }),
    h("span", { text: title }),
  );
}

function ciDot(ci: GitHubPR["ci"]): HTMLElement {
  const el = dot(CI_COLORS[ci], 5);
  if (ci === "unknown") el.style.opacity = "0";
  return el;
}

/** A list row; Ctrl+O does what its click does (views/github.ts keeps the registry). */
function row(onOpen: () => void, ...children: (HTMLElement | null)[]): HTMLElement {
  const el = h("button", { class: "gh-row", onclick: onOpen }, ...children);
  rowOpens.set(el, onOpen);
  return el;
}

function mrRow(mr: GitHubPR, showCI: boolean, baseUrl: string): HTMLElement {
  return row(
    () => open(mr.url, baseUrl),
    showCI ? ciDot(mr.ci) : h("i", { class: "gh-gap" }),
    h("span", { class: "gh-ref", text: `${shortRepo(mr.repo)}!${mr.number}` }),
    h("span", { class: "gh-title", text: mr.title }),
    mr.isDraft ? h("span", { class: "gh-draft", text: GH_STRINGS.draft }) : null,
  );
}

function repoRow(repo: GitHubRepoCI, baseUrl: string): HTMLElement {
  const word = ciWord(repo.ci);
  return row(
    () => open(pipelinesUrl(repo.url), baseUrl),
    ciDot(repo.ci),
    h("span", { class: "gh-ref", text: shortRepo(repo.repo) }),
    h("span", { class: "gh-title", text: repo.branch }),
    word ? h("span", { class: "gh-word", style: `color:${CI_COLORS[repo.ci]}`, text: word }) : null,
  );
}

function listDetail(
  section: Exclude<GitLabSection, "activity">,
  pulse: GitHubPulse,
  baseUrl: string,
  onBack: () => void,
): HTMLElement {
  const rows: HTMLElement[] =
    section === "mainCI"
      ? pulse.mainCI.map((r) => repoRow(r, baseUrl))
      : (section === "myPRs" ? pulse.myPRs : pulse.toReview).map((mr) => mrRow(mr, section === "myPRs", baseUrl));
  const body =
    rows.length === 0
      ? h("div", { class: "gh-empty", text: GH_STRINGS.nothingHere })
      : h("div", { class: rows.length > 3 ? "gh-list fade" : "gh-list" }, ...rows);

  return h(
    "div",
    { class: "int-card" },
    h("div", { class: "gh-detail-head" }, backButton(glSectionTitle(section), onBack)),
    body,
  );
}

// ── Detail: activity grid ─────────────────────────────────────────────────────

function activityDetail(
  activity: GitHubActivity | null,
  stats: GitHubStats | null,
  login: string,
  baseUrl: string,
  onBack: () => void,
): HTMLElement {
  const right = h("button", {
    class: "gh-head-right",
    text: activityHeader(activity, stats, null),
    onclick: () => open(gitlabProfileUrl(baseUrl, login), baseUrl),
  });

  let picked: ContributionDay | null = null;
  const show = (day: ContributionDay | null) => {
    picked = day;
    right.textContent = activityHeader(activity, stats, day);
  };

  const head = h("div", { class: "gh-detail-head" }, backButton(GH_STRINGS.activity, onBack));
  if (activity) head.append(right);

  if (!activity) {
    return h("div", { class: "int-card" }, head, h("div", { class: "gh-empty", text: GH_STRINGS.loading }));
  }

  const grid = h("div", { class: "gh-grid" });
  for (const week of lastWeeks(activity, GRID_WEEKS)) {
    const column = h("div", { class: "gh-week" });
    for (const day of weekColumn(week)) {
      if (!day) {
        column.append(h("i", { class: "gh-cell empty" }));
        continue;
      }
      const cell = h("i", { class: "gh-cell", style: `background:${contributionColor(day.level)}` });
      cell.addEventListener("mouseenter", () => show(day));
      cell.addEventListener("mouseleave", () => show(null));
      cell.addEventListener("click", () => show(picked?.date === day.date ? null : day));
      column.append(cell);
    }
    grid.append(column);
  }
  return h("div", { class: "int-card" }, head, grid);
}

export function gitlabDetail(
  pulse: GitHubPulse,
  stats: GitHubStats | null,
  activity: GitHubActivity | null,
  baseUrl: string,
  onBack: () => void,
): HTMLElement {
  return openSection === "activity"
    ? activityDetail(activity, stats, pulse.login, baseUrl, onBack)
    : listDetail(openSection, pulse, baseUrl, onBack);
}
