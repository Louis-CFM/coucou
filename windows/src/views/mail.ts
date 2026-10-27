// Mail view — DOM port of MailView from IslandViewContent.swift.
// Sends the dropped file via Resend API (if configured) or opens the system email client.

import { h, clear } from "./dom";
import { Bridge } from "../core/bridge";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import type { ViewActions, ViewHost } from "./views";
import { t, tl } from "../i18n/i18n";

export function buildMail(actions: ViewActions): ViewHost {
  const title = h("span", { class: "mail-title", text: tl("New email") });
  const subtitle = h("span", { class: "mail-sub" });
  const head = h("div", { class: "mail-head" }, title, subtitle);

  const toInput = h("input", {
    class: "mail-input",
    type: "email",
    placeholder: "address@example.com",
    spellcheck: "false",
  });
  const toRow = h(
    "label",
    { class: "mail-field" },
    h("span", { class: "mail-label", text: tl("To") }),
    toInput,
  );

  const subjInput = h("input", {
    class: "mail-input",
    type: "text",
    placeholder: tl("Subject"),
  });
  const subjRow = h(
    "label",
    { class: "mail-field" },
    h("span", { class: "mail-label", text: tl("Subject") }),
    subjInput,
  );

  const bodyInput = h("textarea", {
    class: "mail-body",
    rows: "2",
    placeholder: tl("Write a message…"),
  });

  const statusMsg = h("div", { class: "mail-status" });

  let isSending = false;

  const sendBtn = h("button", { class: "btn primary" }, h("span", { text: tl("Send") }));
  const cancelBtn = h("button", {
    class: "btn secondary",
    text: tl("Cancel"),
    onclick: () => {
      actions.setView("choose");
    },
  });
  const actionsRow = h("div", { class: "actions mail-actions" }, sendBtn, cancelBtn);

  const card = h(
    "div",
    { class: "card mail-card" },
    h(
      "div",
      { class: "stack mail-stack" },
      head,
      toRow,
      subjRow,
      bodyInput,
      statusMsg,
      actionsRow,
    ),
  );
  const el = h("div", { class: "view" }, card);

  async function send() {
    const to = (toInput.value || "").trim();
    if (!to) {
      statusMsg.textContent = t("Missing recipient.");
      statusMsg.className = "mail-status error";
      toInput.focus?.();
      return;
    }

    const subj = (subjInput.value || "").trim() || State.droppedFile?.name || t("File");
    const body = bodyInput.value || "";
    const filePath = State.droppedFile?.path;

    isSending = true;
    sendBtn.disabled = true;
    clear(sendBtn);
    sendBtn.append(h("span", { text: t("Sending…") }));
    statusMsg.textContent = "";
    statusMsg.className = "mail-status";
    Sound.play("send");

    try {
      await Bridge.sendEmail({ to, subject: subj, body, filePath });
      statusMsg.textContent = t("✓ Email sent");
      statusMsg.className = "mail-status success";
      Sound.play("finish");
      setTimeout(() => {
        actions.cancelDrop();
      }, 1200);
    } catch (err) {
      statusMsg.textContent = String(err).replace(/^Error:\s*/, "");
      statusMsg.className = "mail-status error";
      Sound.play("error");
    } finally {
      isSending = false;
      sendBtn.disabled = false;
      clear(sendBtn);
      sendBtn.append(h("span", { text: t("Send") }));
    }
  }

  sendBtn.addEventListener("click", () => {
    if (!isSending) void send();
  });

  const handleKey = (e: KeyboardEvent) => {
    if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
      e.preventDefault();
      if (!isSending) void send();
    }
    e.stopPropagation();
  };
  toInput.addEventListener("keydown", handleKey);
  subjInput.addEventListener("keydown", handleKey);
  bodyInput.addEventListener("keydown", handleKey);

  const onFocus = () => actions.keyboard(true);
  const onBlur = () => actions.keyboard(false);
  toInput.addEventListener("focus", onFocus);
  toInput.addEventListener("blur", onBlur);
  subjInput.addEventListener("focus", onFocus);
  subjInput.addEventListener("blur", onBlur);
  bodyInput.addEventListener("focus", onFocus);
  bodyInput.addEventListener("blur", onBlur);

  return {
    el,
    sync() {
      const file = State.droppedFile;
      subtitle.textContent = file ? ` — ${file.name}` : "";
      if (!subjInput.value && file) {
        subjInput.placeholder = file.name;
      }
    },
    focus() {
      if (!toInput.value) toInput.focus();
      else bodyInput.focus();
    },
  };
}
