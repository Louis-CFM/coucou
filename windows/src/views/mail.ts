// Mail view — DOM port of MailView from IslandViewContent.swift.
// Sends the dropped file via Resend API (if configured) or opens Gmail Web composer.

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

  const resendNotice = h("div", { class: "mail-notice", style: "display:none" });
  const statusMsg = h("div", { class: "mail-status" });

  let isSending = false;
  let hasResendKey = false;

  const sendBtnLabel = h("span", { text: tl("Open in Gmail") });
  const sendBtn = h("button", { class: "btn primary" }, sendBtnLabel);
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
      resendNotice,
      statusMsg,
      actionsRow,
    ),
  );
  const el = h("div", { class: "view" }, card);

  async function updateResendStatus() {
    try {
      hasResendKey = (await Bridge.secretPresent("resend-api-key")) ?? false;
    } catch {
      hasResendKey = false;
    }
    clear(resendNotice);
    if (!hasResendKey) {
      resendNotice.style.display = "flex";
      resendNotice.append(
        h("span", {
          class: "mail-notice-text",
          text: tl("Resend not set: opens Gmail. For direct send with file attachment:"),
        }),
        h("button", {
          class: "mail-notice-link",
          text: tl("Settings → Resend"),
          onclick: (e: Event) => {
            e.stopPropagation();
            actions.openSettingsWindow();
          },
        }),
      );
      if (!isSending) sendBtnLabel.textContent = t("Open in Gmail");
    } else {
      resendNotice.style.display = "none";
      if (!isSending) sendBtnLabel.textContent = t("Send");
    }
  }

  void updateResendStatus();

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
    sendBtnLabel.textContent = hasResendKey ? t("Sending…") : t("Opening…");
    statusMsg.textContent = "";
    statusMsg.className = "mail-status";
    Sound.play("send");

    try {
      const res = await Bridge.sendEmail({ to, subject: subj, body, filePath });
      const isGmail = res?.method === "gmail" || !hasResendKey;

      if (isGmail) {
        if (filePath && typeof navigator !== "undefined" && navigator.clipboard?.writeText) {
          try {
            await navigator.clipboard.writeText(filePath);
          } catch {
            // Ignore clipboard errors
          }
        }
        statusMsg.textContent = filePath
          ? t("✓ Opened in Gmail (file path copied to clipboard)")
          : t("✓ Opened in Gmail");
        statusMsg.className = "mail-status success";
        Sound.play("finish");
        setTimeout(() => {
          actions.cancelDrop();
        }, 1800);
      } else {
        statusMsg.textContent = t("✓ Email sent");
        statusMsg.className = "mail-status success";
        Sound.play("finish");
        setTimeout(() => {
          actions.cancelDrop();
        }, 1200);
      }
    } catch (err) {
      statusMsg.textContent = String(err).replace(/^Error:\s*/, "");
      statusMsg.className = "mail-status error";
      Sound.play("error");
    } finally {
      isSending = false;
      sendBtn.disabled = false;
      sendBtnLabel.textContent = hasResendKey ? t("Send") : t("Open in Gmail");
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
      void updateResendStatus();
    },
    focus() {
      if (!toInput.value) toInput.focus();
      else bodyInput.focus();
    },
  };
}
