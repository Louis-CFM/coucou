// "Send by email" for a dropped file — DOM port of MailView and MailField
// (IslandViewContent.swift). Sent by src-tauri/src/send_mail.rs: through Resend when
// it is set up, else the default mail app opens, filled in.

import { h } from "./dom";
import { Bridge } from "../core/bridge";
import { Sound } from "../core/sound";
import { State } from "../core/state";
import type { ViewActions, ViewHost } from "./views";
import { t, tl } from "../i18n/i18n";

function field(label: string, placeholder: string): { row: HTMLElement; input: HTMLInputElement } {
  const input = h("input", { type: "text", class: "sendmail-input", placeholder, spellcheck: "false" }) as HTMLInputElement;
  const row = h("label", { class: "sendmail-field" }, h("span", { class: "sendmail-label", text: label }), input);
  return { row, input };
}

export function buildSendMail(actions: ViewActions): ViewHost {
  const heading = h("b", { text: tl("New email") });
  const withFile = h("span", { class: "sendmail-with" });
  const to = field(t("To"), "address@example.com");
  to.input.type = "email";
  const subject = field(t("Subject"), "");
  const body = h("textarea", { class: "sendmail-body", rows: "2" }) as HTMLTextAreaElement;
  const status = h("div", { class: "sendmail-status" });
  const send = h("button", { class: "btn primary" }) as HTMLButtonElement;
  const cancel = h("button", { class: "btn secondary", text: tl("Cancel"), onclick: () => actions.setView("choose") });
  let sending = false;
  let shownFor: string | null = null;

  for (const el of [to.input, subject.input, body]) {
    // Escape and the island's own keys stay out of the fields.
    el.addEventListener("keydown", (ev) => {
      const e = ev as KeyboardEvent;
      if (e.key === "Escape") {
        e.preventDefault();
        actions.setView("choose");
      }
      if (e.key === "Enter" && el !== body) {
        e.preventDefault();
        void submit();
      }
      e.stopPropagation();
    });
  }

  async function submit() {
    if (sending) return;
    const recipient = to.input.value.trim();
    if (!recipient) {
      status.textContent = t("Missing recipient.");
      return;
    }
    sending = true;
    status.textContent = "";
    paint();
    try {
      const how = await Bridge.mailSend(recipient, subject.input.value, body.value, State.droppedFile?.path ?? null);
      Sound.play("send");
      State.noteMessage = how === "resend" ? t("Email sent to {0}.", { 0: recipient }) : t("Your mail app is open: check the email and send it from there.");
      State.view = "note";
      State.notify();
      window.setTimeout(() => {
        if (State.view === "note") actions.collapse();
      }, 2000);
    } catch (err) {
      status.textContent = String(err).replace(/^Error:\s*/, "");
    } finally {
      sending = false;
      paint();
    }
  }
  send.addEventListener("click", () => void submit());

  function paint() {
    send.textContent = sending ? t("Sending…") : t("Send");
    send.disabled = sending;
  }

  const el = h("div", { class: "view" },
    h("div", { class: "card" },
      h("div", { class: "sendmail-stack" },
        h("div", { class: "sendmail-head" }, heading, withFile),
        to.row,
        subject.row,
        body,
        status,
        h("div", { class: "actions" }, send, cancel),
      ),
    ),
  );

  return {
    el,
    sync() {
      const name = State.droppedFile?.name ?? null;
      withFile.textContent = name ? t("with {name}", { name }) : "";
      subject.input.placeholder = name ?? t("Subject");
      // A new file starts a new email.
      if (shownFor !== name) {
        shownFor = name;
        subject.input.value = name ?? "";
        body.value = "";
        status.textContent = "";
      }
      paint();
    },
    focus() {
      to.input.focus();
    },
  };
}
