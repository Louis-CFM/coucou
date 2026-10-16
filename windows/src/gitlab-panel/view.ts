// The GitLab panel (gitlab-panel.html): four folding sections — comments waiting
// for you, merge requests to review, yours, approved — drawn from what Rust reads
// (src-tauri/src/gitlab_panel.rs). A thread opens in place, with the code it is
// about, and can be answered, resolved or opened again from here. Approving is
// left to GitLab, where the code is.

import { clear, dot, h, svg } from "../views/dom";
import { ICONS } from "../views/icons";
import { renderMarkdown } from "../views/markdown";
import { Bridge } from "../core/bridge";
import { CI_COLORS, type CIState } from "../core/github";
import {
  SECTION_ORDER, ageLabel, approvalsLabel, avatarHue, count, emptyState, initials, loadState, newCount, noteUrl,
  preview, receive, safeInstanceUrl, saveState, sectionTitle, sendError, shortProject, toggle, waiting,
  type Dashboard, type DashMr, type PanelState, type PendingThread, type SectionId, type SnippetLine,
} from "../core/gitlab-panel";
import { t } from "../i18n/i18n";

const GITLAB_ORANGE = "#FC6D26";
const ACCENT: Record<SectionId, string> = {
  comments: GITLAB_ORANGE,
  toReview: "#8AB4F8",
  mine: "#B79CFF",
  approved: "#22C55E",
};

/** The little icon in each section's tile: [path, stroked]. */
const SECTION_ICON: Record<SectionId, [string, boolean]> = {
  comments: [ICONS.bubble, false],
  toReview: [ICONS.eye, true],
  mine: [ICONS.pull, true],
  approved: [ICONS.check, true],
};

/** A round icon for a pipeline: ✓ passed, ✕ failed, a clock while it runs, a plain dot when unknown. */
function ciBadge(ci: CIState): HTMLElement {
  const color = CI_COLORS[ci];
  const badge = h("i", { class: `gp-ci ${ci}`, style: `--c:${color}` });
  switch (ci) {
    case "success": badge.append(svg(ICONS.check, 9, { stroke: 3 })); break;
    case "failure": badge.append(svg(ICONS.xmark, 8)); break;
    case "pending": badge.append(svg(ICONS.timer, 9)); break;
    default: break;
  }
  return badge;
}

/** A round avatar: the initials of a person, in a colour that is theirs. */
function avatar(name: string, username: string, size = 22): HTMLElement {
  const hue = avatarHue(username || name);
  return h("i", {
    class: "gp-avatar",
    style: `width:${size}px;height:${size}px;font-size:${Math.round(size * 0.42)}px;--h:${hue}`,
    text: initials(name),
  });
}

function storage(): Storage | undefined {
  try {
    return window.localStorage;
  } catch {
    return undefined;
  }
}

export class PanelView {
  /** How long the pointer rests on the slim bar before it unfolds. */
  hoverDelay = 150;
  private expanded = true;
  private autoCloseMs = 15_000;
  private pointerInside = false;
  private hoverTimer: number | undefined;
  private collapseTimer: number | undefined;
  /** Sections whose tile pulses in the slim bar: something new arrived. */
  private pulsing = new Set<SectionId>();
  private dash: Dashboard | null = null;
  private state: PanelState = emptyState();
  /** The thread open in place, if any. */
  private openThread: string | null = null;
  /** Reply boxes live as long as their thread, so a refresh never eats a draft. */
  private boxes = new Map<string, HTMLTextAreaElement>();
  private errors = new Map<string, string>();
  private sending = new Set<string>();
  /** Threads resolved from here, kept (dimmed) so they can be opened again. */
  private resolved = new Map<string, PendingThread>();
  private snippets = new Map<string, SnippetLine[] | null>();
  private measured = 0;
  private readonly inner = h("div", { class: "gp-inner" });

  private readonly root: HTMLElement;

  constructor(root: HTMLElement) {
    this.root = root;
    root.append(this.inner);
    this.state = loadState(storage());
  }

  /** New data from Rust. */
  setDashboard(dash: Dashboard | null) {
    const before = this.dash ? newCount(this.state, this.dash, "comments") : 0;
    this.dash = dash;
    if (dash) {
      this.state = receive(this.state, dash);
      saveState(storage(), this.state);
      // A new comment while the panel is folded: its tile pulses, nothing unfolds by itself.
      if (!this.expanded && newCount(this.state, dash, "comments") > before) this.pulse("comments");
    }
    this.render();
  }

  /** The panel was closed: what was only kept for a moment goes. */
  closed() {
    this.resolved.clear();
    this.openThread = null;
    this.pointerInside = false;
    this.clearTimers();
    this.render();
  }

  // ── Folded or unfolded ──────────────────────────────────────────────────────

  /** The island's auto-close delay, in seconds: how long the pointer is away before the panel folds. */
  setAutoClose(seconds: number) {
    this.autoCloseMs = Math.max(0, seconds) * 1000;
    if (this.expanded && !this.pointerInside) this.armCollapse();
  }

  /** Rust says how the panel is: the card, or the slim bar. */
  setMode(expanded: boolean) {
    this.expanded = expanded;
    this.measured = 0;
    this.clearTimers();
    if (expanded && !this.pointerInside) this.armCollapse();
    this.render();
  }

  /** The pointer is on the panel: it unfolds if it is the slim bar, and does not fold meanwhile. */
  pointerEnter() {
    this.pointerInside = true;
    window.clearTimeout(this.collapseTimer);
    if (!this.expanded) {
      this.hoverTimer = window.setTimeout(() => this.expand(), this.hoverDelay);
    }
  }

  pointerLeave() {
    this.pointerInside = false;
    window.clearTimeout(this.hoverTimer);
    if (this.expanded) this.armCollapse();
  }

  private clearTimers() {
    window.clearTimeout(this.hoverTimer);
    window.clearTimeout(this.collapseTimer);
  }

  private armCollapse() {
    window.clearTimeout(this.collapseTimer);
    if (this.autoCloseMs <= 0) return;
    this.collapseTimer = window.setTimeout(() => this.tryCollapse(), this.autoCloseMs);
  }

  /** A reply being written is never lost to a fold: it waits for the next delay. */
  private tryCollapse() {
    if (this.pointerInside || !this.expanded) return;
    if (this.hasDraft()) {
      this.armCollapse();
      return;
    }
    this.requestMode(false);
  }

  private hasDraft(): boolean {
    return [...this.boxes.values()].some((box) => box.value.trim() !== "" || box === document.activeElement);
  }

  private expand() {
    if (!this.expanded) this.requestMode(true);
  }

  private requestMode(expanded: boolean) {
    this.setMode(expanded);
    void Bridge.gitlabPanelMode(expanded);
  }

  private pulse(id: SectionId) {
    this.pulsing.add(id);
    window.setTimeout(() => {
      this.pulsing.delete(id);
      this.render();
    }, 3000);
  }

  /** The card or the slim bar (the card always lies flat on the screen's right edge). */
  private applyShape() {
    this.root.className = this.expanded ? "" : "slim";
  }

  /** Redraws everything, keeping the focus and the text of the reply box in use. */
  render() {
    const active = document.activeElement;
    const focusedId = [...this.boxes].find(([, box]) => box === active)?.[0] ?? null;
    const caret = focusedId ? (this.boxes.get(focusedId) as HTMLTextAreaElement).selectionStart : null;
    clear(this.inner);
    this.applyShape();
    if (this.expanded) {
      this.inner.append(this.header());
      this.inner.append(this.dash ? this.body(this.dash) : h("div", { class: "gp-empty", text: t("Loading…") }));
    } else {
      this.inner.append(this.slim());
    }
    if (focusedId) {
      const box = this.boxes.get(focusedId);
      box?.focus();
      if (box && caret != null) box.setSelectionRange(caret, caret);
    }
    this.fit();
  }

  /** Tells Rust how tall the content is: the window follows it. */
  private fit() {
    const content = Math.ceil(this.inner.offsetHeight);
    // The card's 1 px border is outside the content.
    const height = content + 2;
    if (content > 0 && height !== this.measured) {
      this.measured = height;
      void Bridge.gitlabPanelResize(height);
    }
  }

  // ── Pieces ──────────────────────────────────────────────────────────────────

  private header(): HTMLElement {
    const bar = h(
      "div",
      { class: "gp-head" },
      h("i", { class: "gp-logo" }, dot("#0b0b0d", 6)),
      h("b", { text: "GitLab" }),
      h("span", { class: "gp-grow" }),
      h("button", {
        class: "gp-x",
        title: t("Fold the panel"),
        "aria-label": t("Fold the panel"),
        onclick: () => this.requestMode(false),
      }, svg(ICONS.collapse, 11, { stroke: 2.2 })),
      h("button", {
        class: "gp-x",
        title: t("Close"),
        "aria-label": t("Close"),
        onclick: () => void Bridge.gitlabPanelClose(),
      }, svg(ICONS.xmark, 10)),
    );
    return bar;
  }

  /** The slim bar: the logo and one tile per section, with its "+N" and its glow. */
  private slim(): HTMLElement {
    const bar = h("div", { class: "gp-slim" }, h("i", { class: "gp-logo" }, dot("#0b0b0d", 6)));
    const dash = this.dash;
    for (const id of SECTION_ORDER) {
      const total = dash ? count(dash, id) : 0;
      const fresh = dash ? newCount(this.state, dash, id) : 0;
      const cls = ["gp-pill", dash && waiting(dash, id) ? "waiting" : "", this.pulsing.has(id) ? "pulse" : ""]
        .filter(Boolean)
        .join(" ");
      bar.append(
        h(
          "button",
          {
            class: cls,
            style: `--accent:${ACCENT[id]}`,
            title: `${sectionTitle(id)} · ${total}`,
            "aria-label": `${sectionTitle(id)} · ${total}`,
            // A tile unfolds the panel with its section open.
            onclick: () => this.openSection(id),
          },
          svg(SECTION_ICON[id][0], 14, SECTION_ICON[id][1] ? { stroke: 2.2 } : {}),
          fresh > 0 ? h("span", { class: "gp-pbadge", text: `+${fresh}` }) : null,
        ),
      );
    }
    return bar;
  }

  private openSection(id: SectionId) {
    if (!this.state.open[id]) {
      this.state = toggle(this.state, this.dash, id);
      saveState(storage(), this.state);
    }
    this.requestMode(true);
  }

  private body(dash: Dashboard): HTMLElement {
    const body = h("div", { class: "gp-body" });
    for (const id of SECTION_ORDER) body.append(this.section(dash, id));
    return body;
  }

  private section(dash: Dashboard, id: SectionId): HTMLElement {
    const open = this.state.open[id];
    const total = count(dash, id);
    const fresh = newCount(this.state, dash, id);
    const accent = ACCENT[id];
    const head = h(
      "button",
      { class: "gp-sec-head", "aria-expanded": open ? "true" : "false", onclick: () => this.toggleSection(id) },
      h("i", { class: "gp-tile" }, svg(SECTION_ICON[id][0], 12, SECTION_ICON[id][1] ? { stroke: 2.2 } : {})),
      h("span", { class: "gp-sec-title", text: sectionTitle(id) }),
      h("span", { class: "gp-grow" }),
      // "+N": new since this section was last opened.
      fresh > 0 ? h("span", { class: "gp-new", style: `background:${accent}`, text: `+${fresh}` }) : null,
      h("span", { class: "gp-count", text: String(total) }),
      h("i", { class: open ? "gp-chev open" : "gp-chev" }, svg(ICONS.chevronRight, 9, { stroke: 2.6 })),
    );
    const cls = waiting(dash, id) ? "gp-sec waiting" : "gp-sec";
    const sec = h("section", { class: cls, style: `--accent:${accent}` }, head);
    if (open) sec.append(this.list(dash, id));
    return sec;
  }

  private toggleSection(id: SectionId) {
    this.state = toggle(this.state, this.dash, id);
    saveState(storage(), this.state);
    this.render();
  }

  private list(dash: Dashboard, id: SectionId): HTMLElement {
    const list = h("div", { class: "gp-list" });
    if (id === "comments") {
      const rows = [...this.resolved.values(), ...dash.comments.filter((c) => !this.resolved.has(c.id))];
      if (rows.length === 0) list.append(this.empty());
      for (const th of rows) list.append(this.threadRow(dash, th));
      return list;
    }
    const mrs = id === "toReview" ? dash.toReview : id === "mine" ? dash.mine : dash.approved;
    if (mrs.length === 0) list.append(this.empty());
    for (const mr of mrs) list.append(this.mrRow(dash, mr, id === "mine"));
    return list;
  }

  private empty(): HTMLElement {
    return h("div", { class: "gp-empty" }, h("i", {}, svg(ICONS.check, 10, { stroke: 2.6 })), h("span", { text: t("Nothing here") }));
  }

  private open(dash: Dashboard, url: string) {
    const safe = safeInstanceUrl(url, dash.baseUrl);
    if (safe) void Bridge.openUrl(safe);
  }

  private mrRow(dash: Dashboard, mr: DashMr, mine: boolean): HTMLElement {
    const chips: (HTMLElement | null)[] = [
      h("span", { class: "gp-chip proj", title: mr.project, text: shortProject(mr.project) }),
      h("span", { class: "gp-iid", text: `!${mr.iid}` }),
      mr.isDraft ? h("span", { class: "gp-chip draft", text: t("Draft") }) : null,
    ];
    const approvals = approvalsLabel(mr.approvals);
    if (mine && approvals) {
      chips.push(h("span", { class: "gp-chip ok", title: t("Approvals") }, svg(ICONS.check, 8, { stroke: 3 }), approvals));
    }
    if (mine && mr.unresolved) {
      chips.push(h("span", { class: "gp-chip warn", title: t("Unresolved threads") }, svg(ICONS.bubble, 8), String(mr.unresolved)));
    }
    return h(
      "button",
      { class: "gp-row", onclick: () => this.open(dash, mr.url) },
      ciBadge(mr.ci),
      h(
        "span",
        { class: "gp-row-main" },
        h("span", { class: "gp-row-title", text: mr.title }),
        h("span", { class: "gp-meta" }, ...chips),
      ),
      mr.updatedAt ? h("span", { class: "gp-age", text: ageLabel(mr.updatedAt) }) : null,
    );
  }

  private threadRow(dash: Dashboard, th: PendingThread): HTMLElement {
    const done = this.resolved.has(th.id);
    const open = this.openThread === th.id;
    const last = th.notes[th.notes.length - 1];
    const row = h(
      "div",
      { class: `gp-thread${open ? " open" : ""}${done ? " done" : ""}` },
      h(
        "button",
        { class: "gp-row", onclick: () => this.toggleThread(th) },
        last ? avatar(last.author, last.username) : null,
        h(
          "span",
          { class: "gp-row-main" },
          h("span", { class: "gp-row-title", text: preview(th) }),
          h(
            "span",
            { class: "gp-meta" },
            h("span", { class: "gp-chip proj", title: th.project, text: shortProject(th.project) }),
            h("span", { class: "gp-iid", text: `!${th.mrIid}` }),
            done ? h("span", { class: "gp-chip ok" }, svg(ICONS.check, 8, { stroke: 3 }), t("Resolved")) : null,
          ),
        ),
        last ? h("span", { class: "gp-age", text: ageLabel(last.createdAt) }) : null,
      ),
    );
    if (open) row.append(this.threadDetail(dash, th, done));
    return row;
  }

  private toggleThread(th: PendingThread) {
    this.openThread = this.openThread === th.id ? null : th.id;
    this.render();
    if (this.openThread === th.id && th.position && !this.snippets.has(snippetKey(th))) {
      const p = th.position;
      void Bridge.gitlabSnippet(th.projectId, p.file, p.sha, p.line).then((lines) => {
        this.snippets.set(snippetKey(th), lines);
        this.render();
      });
    }
  }

  private threadDetail(dash: Dashboard, th: PendingThread, done: boolean): HTMLElement {
    const detail = h("div", { class: "gp-detail" });
    detail.append(
      h(
        "div",
        { class: "gp-mr" },
        h("span", { class: "gp-mr-ref", text: th.mrRef }),
        h("span", { class: "gp-mr-title", text: th.mrTitle }),
        h("button", {
          class: "gp-link",
          title: t("Open in GitLab"),
          "aria-label": t("Open in GitLab"),
          onclick: () => this.open(dash, noteUrl(th)),
        }, svg(ICONS.arrowUpRight, 11)),
      ),
    );

    if (th.position) {
      const lines = this.snippets.get(snippetKey(th));
      const code = h("div", { class: "gp-code" }, h("div", { class: "gp-code-file", text: `${th.position.file}:${th.position.line}` }));
      for (const l of lines ?? []) {
        code.append(
          h(
            "div",
            { class: l.target ? "gp-code-line target" : "gp-code-line" },
            h("i", { text: String(l.number) }),
            h("code", { text: l.text }),
          ),
        );
      }
      detail.append(code);
    }

    const notes = h("div", { class: "gp-notes" });
    for (const n of th.notes) {
      const body = h("div", { class: "gp-note-body" });
      renderMarkdown(body, n.body);
      notes.append(
        h(
          "div",
          { class: n.isMe ? "gp-note me" : "gp-note" },
          avatar(n.author, n.username, 20),
          h(
            "div",
            { class: "gp-note-main" },
            h("div", { class: "gp-note-head" }, h("b", { text: n.isMe ? t("You") : n.author }), h("span", { text: ageLabel(n.createdAt) })),
            body,
          ),
        ),
      );
    }
    detail.append(notes);
    detail.append(done ? this.reopenBar(th) : this.replyBar(dash, th));
    return detail;
  }

  private reopenBar(th: PendingThread): HTMLElement {
    const error = this.errors.get(th.id);
    return h(
      "div",
      { class: "gp-actions" },
      h("button", {
        class: "gp-btn",
        disabled: this.sending.has(th.id),
        text: t("Reopen"),
        onclick: () => void this.resolve(th, false),
      }),
      error ? h("span", { class: "gp-error", text: error }) : null,
    );
  }

  private replyBar(dash: Dashboard, th: PendingThread): HTMLElement {
    if (dash.canWrite === false) {
      return h("div", { class: "gp-actions" }, h("span", { class: "gp-hint", text: sendError("forbidden") }));
    }
    let box = this.boxes.get(th.id);
    if (!box) {
      box = h("textarea", { class: "gp-box", rows: 3, placeholder: t("Write a reply…") }) as HTMLTextAreaElement;
      box.addEventListener("input", () => this.updateSend(th.id));
      box.addEventListener("keydown", (e) => {
        // Ctrl+Enter sends, like most review tools.
        if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
          e.preventDefault();
          void this.reply(th);
        }
      });
      this.boxes.set(th.id, box);
    }
    const busy = this.sending.has(th.id);
    const send = h("button", {
      class: "gp-btn primary",
      "data-send": th.id,
      disabled: busy || box.value.trim() === "",
      text: t("Send"),
      onclick: () => void this.reply(th),
    });
    const error = this.errors.get(th.id);
    return h(
      "div",
      { class: "gp-reply" },
      box,
      error ? h("div", { class: "gp-error", text: error }) : null,
      h(
        "div",
        { class: "gp-actions" },
        send,
        th.resolvable
          ? h("button", { class: "gp-btn", disabled: busy, text: t("Resolve"), onclick: () => void this.resolve(th, true) })
          : null,
      ),
    );
  }

  /** Enables Send as soon as there is something to send, without redrawing the box. */
  private updateSend(id: string) {
    const box = this.boxes.get(id);
    const send = this.inner.querySelector<HTMLButtonElement>(`[data-send="${CSS.escape(id)}"]`);
    if (box && send) send.disabled = box.value.trim() === "" || this.sending.has(id);
  }

  // ── Actions ─────────────────────────────────────────────────────────────────

  private async reply(th: PendingThread) {
    const box = this.boxes.get(th.id);
    const text = box?.value.trim() ?? "";
    if (!text || this.sending.has(th.id)) return;
    this.sending.add(th.id);
    this.errors.delete(th.id);
    this.render();
    const result = await Bridge.gitlabReply(th.projectId, th.mrIid, th.id, text);
    this.sending.delete(th.id);
    if (result?.ok) {
      // The thread leaves the list; the text goes with it.
      this.boxes.delete(th.id);
      if (this.openThread === th.id) this.openThread = null;
    } else {
      // The draft stays in its box.
      this.errors.set(th.id, sendError(result?.error ?? "error"));
    }
    this.render();
  }

  private async resolve(th: PendingThread, resolved: boolean) {
    if (this.sending.has(th.id)) return;
    this.sending.add(th.id);
    this.errors.delete(th.id);
    this.render();
    const result = await Bridge.gitlabResolve(th.projectId, th.mrIid, th.id, resolved);
    this.sending.delete(th.id);
    if (result?.ok) {
      if (resolved) this.resolved.set(th.id, th);
      else this.resolved.delete(th.id);
    } else {
      this.errors.set(th.id, sendError(result?.error ?? "error"));
    }
    this.render();
  }
}

function snippetKey(th: PendingThread): string {
  return `${th.id}:${th.position?.sha}:${th.position?.line}`;
}
