// The GitLab panel (gitlab-panel.html): four folding sections — comments waiting
// for you, merge requests to review, yours, approved — drawn from what Rust reads
// (src-tauri/src/gitlab_panel.rs). A thread opens in place, with the code it is
// about, and can be answered, resolved or opened again from here. Approving is
// left to GitLab, where the code is.

import { clear, dot, h, svg } from "../views/dom";
import { ICONS } from "../views/icons";
import { renderMarkdown } from "../views/markdown";
import { Bridge } from "../core/bridge";
import { CI_COLORS } from "../core/github";
import {
  SECTION_ORDER, ageLabel, approvalsLabel, count, emptyState, loadState, newCount, noteUrl, preview, receive,
  safeInstanceUrl, saveState, sectionTitle, sendError, shortProject, toggle, waiting,
  type Dashboard, type DashMr, type PanelState, type PendingThread, type SectionId, type SnippetLine,
} from "../core/gitlab-panel";
import { t } from "../i18n/i18n";

const GITLAB_ORANGE = "#FC6D26";
const ACCENT: Record<SectionId, string> = {
  comments: GITLAB_ORANGE,
  toReview: "#8AB4F8",
  mine: "#9398A1",
  approved: "#22C55E",
};

function storage(): Storage | undefined {
  try {
    return window.localStorage;
  } catch {
    return undefined;
  }
}

export class PanelView {
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

  constructor(root: HTMLElement) {
    root.append(this.inner);
    this.state = loadState(storage());
  }

  /** New data from Rust. */
  setDashboard(dash: Dashboard | null) {
    this.dash = dash;
    if (dash) {
      this.state = receive(this.state, dash);
      saveState(storage(), this.state);
    }
    this.render();
  }

  /** The panel was closed: what was only kept for a moment goes. */
  closed() {
    this.resolved.clear();
    this.openThread = null;
    this.render();
  }

  /** Redraws everything, keeping the focus and the text of the reply box in use. */
  render() {
    const active = document.activeElement;
    const focusedId = [...this.boxes].find(([, box]) => box === active)?.[0] ?? null;
    const caret = focusedId ? (this.boxes.get(focusedId) as HTMLTextAreaElement).selectionStart : null;
    clear(this.inner);
    this.inner.append(this.header());
    this.inner.append(this.dash ? this.body(this.dash) : h("div", { class: "gp-empty", text: t("Loading…") }));
    if (focusedId) {
      const box = this.boxes.get(focusedId);
      box?.focus();
      if (box && caret != null) box.setSelectionRange(caret, caret);
    }
    this.fit();
  }

  /** Tells Rust how tall the content is: the window follows it. */
  private fit() {
    const height = Math.ceil(this.inner.offsetHeight);
    if (height > 0 && height !== this.measured) {
      this.measured = height;
      void Bridge.gitlabPanelResize(height);
    }
  }

  // ── Pieces ──────────────────────────────────────────────────────────────────

  private header(): HTMLElement {
    const bar = h(
      "div",
      { class: "gp-head" },
      dot(GITLAB_ORANGE, 8),
      h("b", { text: "GitLab" }),
      h("span", { class: "gp-grow" }),
      h("button", {
        class: "gp-x",
        title: t("Close"),
        "aria-label": t("Close"),
        onclick: () => void Bridge.gitlabPanelClose(),
      }, svg(ICONS.xmark, 10)),
    );
    // Dragging the bar moves the window; the buttons keep their clicks.
    bar.addEventListener("mousedown", (e) => {
      if ((e.target as Element).closest("button")) return;
      void Bridge.gitlabPanelDrag();
    });
    return bar;
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
      h("i", { class: open ? "gp-chev open" : "gp-chev" }, svg(ICONS.chevronRight, 9, { stroke: 2.6 })),
      h("span", { class: "gp-sec-title", text: sectionTitle(id) }),
      h("span", { class: "gp-grow" }),
      // "+N": new since this section was last opened.
      fresh > 0 ? h("span", { class: "gp-new", style: `background:${accent}`, text: `+${fresh}` }) : null,
      h("span", { class: "gp-count", text: String(total) }),
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
      if (rows.length === 0) list.append(h("div", { class: "gp-empty", text: t("Nothing here") }));
      for (const th of rows) list.append(this.threadRow(dash, th));
      return list;
    }
    const mrs = id === "toReview" ? dash.toReview : id === "mine" ? dash.mine : dash.approved;
    if (mrs.length === 0) list.append(h("div", { class: "gp-empty", text: t("Nothing here") }));
    for (const mr of mrs) list.append(this.mrRow(dash, mr, id === "mine"));
    return list;
  }

  private open(dash: Dashboard, url: string) {
    const safe = safeInstanceUrl(url, dash.baseUrl);
    if (safe) void Bridge.openUrl(safe);
  }

  private mrRow(dash: Dashboard, mr: DashMr, mine: boolean): HTMLElement {
    const ci = h("i", { class: "gp-ci", style: `background:${CI_COLORS[mr.ci]}` });
    if (mr.ci === "unknown") ci.style.opacity = "0";
    const meta: (HTMLElement | null)[] = [
      h("span", { class: "gp-proj", title: mr.project, text: shortProject(mr.project) }),
      h("span", { text: `!${mr.iid}` }),
      mr.updatedAt ? h("span", { text: ageLabel(mr.updatedAt) }) : null,
    ];
    const approvals = approvalsLabel(mr.approvals);
    if (mine && approvals) meta.push(h("span", { class: "gp-badge", title: t("Approvals"), text: approvals }));
    if (mine && mr.unresolved) {
      meta.push(h("span", { class: "gp-badge warn", title: t("Unresolved threads"), text: `💬 ${mr.unresolved}` }));
    }
    return h(
      "button",
      { class: "gp-row", onclick: () => this.open(dash, mr.url) },
      ci,
      h(
        "span",
        { class: "gp-row-main" },
        h("span", { class: "gp-row-title" }, mr.title, mr.isDraft ? h("em", { class: "gp-draft", text: t("Draft") }) : null),
        h("span", { class: "gp-meta" }, ...meta),
      ),
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
        h("i", { class: "gp-ci", style: `background:${ACCENT.comments}` }),
        h(
          "span",
          { class: "gp-row-main" },
          h("span", { class: "gp-row-title", text: preview(th) }),
          h(
            "span",
            { class: "gp-meta" },
            h("span", { class: "gp-proj", title: th.project, text: shortProject(th.project) }),
            h("span", { text: `!${th.mrIid}` }),
            last ? h("span", { text: last.author }) : null,
            last ? h("span", { text: ageLabel(last.createdAt) }) : null,
            done ? h("span", { class: "gp-badge", text: t("Resolved") }) : null,
          ),
        ),
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
          h("div", { class: "gp-note-head" }, h("b", { text: n.isMe ? t("You") : n.author }), h("span", { text: ageLabel(n.createdAt) })),
          body,
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
