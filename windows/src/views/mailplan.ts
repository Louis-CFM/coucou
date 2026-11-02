// A plan of the chat, under the answer that wrote it: what it will do, the mails it will send
// (the ones that can't be sent in red), Send me a test, and Run, which starts a 5-second
// countdown before anything happens. Port of MailPlanCard (MailAgentViews.swift).
//
// The plan is prepared and run by Rust (src-tauri/src/mail): the PDF saved from Outlook and
// cut page by page, each page given to its recipient. Rust tells the card as it goes
// (`mail-plan` events).

import { h, clear } from "./dom";
import { onEvent } from "../core/bridge";
import { MAIL_BLUE, MailBridge, nameOf, ruleLine, senderName, type PlanRun } from "../core/mail";
import { t } from "../i18n/i18n";

const runs = new Map<string, PlanRun>();
const cards = new Map<string, Set<() => void>>();

void onEvent<{ id: string; run: PlanRun }>("mail-plan", ({ id, run }) => {
  runs.set(id, run);
  cards.get(id)?.forEach((redraw) => redraw());
});

function fileName(path: string): string {
  return path.split(/[\\/]/).pop() ?? path;
}

function noteText(n: PlanRun["notes"][number]): string {
  switch (n.kind) {
    case "missing": return t("Message {0} is not in the list", { 0: n.value });
    case "noPdf": return t("No PDF found in that message");
    case "fileMissing": return t("File not found: {0}", { 0: n.value });
  }
}

/** The card of the chat message `id`, whose answer is `text`. */
export function mailPlanCard(id: string, summary: string, text: string): HTMLElement {
  const el = h("div", { class: "plan-card" });
  const redraw = () => draw(el, id, summary);
  if (!cards.has(id)) cards.set(id, new Set());
  cards.get(id)!.add(redraw);
  if (!runs.has(id)) {
    void MailBridge.planShow(id, text).then((run) => {
      if (run && !runs.has(id)) {
        runs.set(id, run);
        redraw();
      }
    });
  }
  redraw();
  return el;
}

function line(text: string): HTMLElement {
  return h("div", { class: "plan-line" }, h("span", { class: "plan-arrow", text: "→" }), h("span", { text }));
}

function button(text: string, primary: boolean, onclick: () => void): HTMLElement {
  return h("button", { class: primary ? "plan-btn primary" : "plan-btn", text, onclick });
}

function draw(el: HTMLElement, id: string, summary: string) {
  clear(el);
  const run = runs.get(id);
  el.append(h("div", { class: "plan-title" },
    h("i", { class: "plan-icon", text: "✉" }),
    h("b", { text: run?.summary || summary || t("Mail plan") }),
  ));
  if (!run) return;
  for (const s of run.sorts) el.append(line(t("{0}: {1} messages", { 0: ruleLine(s.action), 1: s.messages.length })));
  for (const [m] of run.replies) el.append(line(t("Reply draft to {0}", { 0: senderName(m) })));
  for (const [m, folder] of run.saves) el.append(line(t("Save the attachments of {0} in {1}", { 0: nameOf(senderName(m)), 1: folder })));
  if (run.mails.length > 0) {
    el.append(line(t("{0} mails to send", { 0: run.mails.filter((m) => !m.problem).length })));
    const rows = h("div", { class: "plan-rows" });
    for (const m of run.mails) {
      const r = h("div", { class: m.problem ? "plan-row bad" : "plan-row" },
        h("span", { class: "plan-to", text: m.to.join(", ") }),
        h("span", { class: "plan-subject", text: m.subject }),
      );
      if (m.problem) {
        r.append(h("span", { class: "plan-problem", text: m.problem === "noPage" ? t("no page found") : t("invalid address") }));
      } else if (m.attachments.length > 0) {
        const extra = m.attachments.length > 1 ? ` +${m.attachments.length - 1}` : "";
        r.append(h("span", { class: "plan-file", text: `📎 ${fileName(m.attachments[0])}${extra}` }));
      }
      rows.append(r);
    }
    el.append(rows);
  }
  for (const n of run.notes) el.append(h("div", { class: "plan-note", text: noteText(n) }));

  const controls = h("div", { class: "plan-controls" });
  const p = run.phase;
  switch (p.kind) {
    case "preparing":
      controls.append(h("span", { class: "plan-status", text: t("Preparing…") }));
      break;
    case "ready":
    case "cancelled":
      if (run.stepCount > 0) controls.append(button(t("Run ({0})", { 0: run.stepCount }), true, () => void MailBridge.planStart(id)));
      if (run.mails.length > 0 && run.myAddress) controls.append(button(t("Send me a test"), false, () => void MailBridge.planTest(id)));
      if (p.kind === "cancelled") controls.append(h("span", { class: "plan-status", text: t("Cancelled") }));
      else if (run.testSentTo) controls.append(h("span", { class: "plan-status ok", text: t("Test sent to {0}", { 0: run.testSentTo }) }));
      break;
    case "countdown":
      controls.append(
        h("span", { class: "plan-status amber", text: t("Starting in {0} s", { 0: p.seconds }) }),
        button(t("Cancel"), false, () => void MailBridge.planCancel(id)),
      );
      break;
    case "running": {
      const bar = h("div", { class: "plan-bar" }, h("i", { style: `width:${Math.round((100 * p.done) / Math.max(1, p.total))}%;background:${MAIL_BLUE}` }));
      controls.append(bar, h("span", { class: "plan-status", text: `${p.done}/${p.total}` }),
        button(t("Cancel"), false, () => void MailBridge.planCancel(id)));
      break;
    }
    case "done":
      controls.append(h("span", { class: p.failed === 0 ? "plan-status ok" : "plan-status amber",
        text: (p.failed === 0 ? "✓ " : "⚠ ") + t("{0} done · {1} failed", { 0: p.ok, 1: p.failed }) }));
      break;
  }
  el.append(controls);
}
