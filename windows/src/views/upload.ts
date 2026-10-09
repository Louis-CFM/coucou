// Drop zone, upload progress, the "what do you want to do with it" card and
// the mail sheet — ports of UploadView / UploadingView / ChooseView / MailView
// from IslandViewContent.swift.

import { h, clear } from "./dom";
import { State } from "../core/state";
import { Bridge, IS_TAURI } from "../core/bridge";
import type { ViewActions, ViewHost } from "./views";
import { N_, t, tl, type Msg } from "../i18n/i18n";

/** Dashed rounded rect drawn as SVG so the dashes can march like on macOS. */
function dashedFrame(): SVGSVGElement {
  const ns = "http://www.w3.org/2000/svg";
  const el = document.createElementNS(ns, "svg");
  el.setAttribute("class", "drop-frame");
  el.setAttribute("preserveAspectRatio", "none");
  const rect = document.createElementNS(ns, "rect");
  rect.setAttribute("x", "0.75");
  rect.setAttribute("y", "0.75");
  rect.setAttribute("width", "calc(100% - 1.5px)");
  rect.setAttribute("height", "calc(100% - 1.5px)");
  rect.setAttribute("rx", "20");
  rect.setAttribute("fill", "none");
  rect.setAttribute("stroke-width", "1.5");
  rect.setAttribute("stroke-dasharray", "6 5");
  el.append(rect);
  return el;
}

export function buildUpload(): ViewHost {
  const frame = dashedFrame();
  const title = h("div", { class: "drop-title", text: tl("Drop your files here") });
  const tags = h(
    "div",
    { class: "drop-tags" },
    ...[N_("PDF"), N_("Images"), N_("Code"), N_("Docs")].map((chip) => h("span", { text: tl(chip) })),
  );
  const card = h(
    "div",
    { class: "card drop-card" },
    frame,
    h("div", { class: "drop-body" }, title, tags),
  );
  const el = h("div", { class: "view" }, card);

  return {
    el,
    sync() {
      card.classList.toggle("over", State.fileDragOver);
    },
  };
}

export function buildUploading(): ViewHost {
  const label = h("span", { class: "up-name" });
  const percent = h("span", { class: "up-pct" });
  const fill = h("div", { class: "up-fill" });
  const glow = h("div", { class: "up-glow" });
  const card = h(
    "div",
    { class: "card up-card" },
    h("div", { class: "up-row" }, label, percent),
    h("div", { class: "up-track" }, fill, glow),
  );
  const el = h("div", { class: "view" }, card);

  return {
    el,
    sync() {
      const done = State.uploadProgress >= 0.999;
      const pct = Math.round(State.uploadProgress * 100);
      label.textContent = done
        ? `✓  ${State.droppedFile?.name ?? t("File")}`
        : t("Uploading {name}", { name: State.droppedFile?.name ?? t("file") });
      label.classList.toggle("done", done);
      percent.textContent = done ? "" : `${pct} %`;
      const w = State.uploadProgress * 526;
      fill.style.width = `${w}px`;
      glow.style.transform = `translateX(${Math.max(0, w - 14)}px)`;
      glow.style.opacity = State.uploadProgress > 0.01 ? "1" : "0";
      card.classList.toggle("done", done);
    },
  };
}

export function buildChoose(actions: ViewActions): ViewHost {
  const title = h("div", { class: "title" });
  const sub = h("div", { class: "sub", text: tl("What do you want to do with it?") });
  const row = h(
    "div",
    { class: "actions" },
    h("button", {
      class: "btn primary",
      text: tl("Ask a question"),
      onclick: () => actions.setView("prompt"),
    }),
    h("button", {
      class: "btn secondary",
      text: tl("Send by email"),
      onclick: () => actions.setView("mail"),
    }),
    h("button", {
      class: "btn secondary",
      text: tl("Cancel"),
      onclick: () => actions.cancelDrop(),
    }),
  );
  const el = h(
    "div",
    { class: "view" },
    h(
      "div",
      { class: "card" },
      h("div", { class: "stack", style: "padding:0 18px 0 98px" }, title, sub, row),
    ),
  );

  return {
    el,
    sync() {
      clear(title);
      title.append(
        h("b", { text: State.droppedFile?.name ?? t("file") }),
        document.createTextNode(t(" is ready.")),
      );
    },
  };
}

// ── Mail ──────────────────────────────────────────────────────────────────────
// MailView on the Mac: To / Subject / body + Send, Resend when it is configured
// (API key AND a sender address), the mail app otherwise — `mailto:` there is a
// draft, not a send, so the note says to attach the file instead of claiming
// it went out.

export function buildMail(actions: ViewActions): ViewHost {
  const toInput = h("input", {
    class: "mail-input",
    type: "email",
    placeholder: "address@example.com",
    spellcheck: "false",
  }) as HTMLInputElement;
  const subjectInput = h("input", { class: "mail-input", type: "text" }) as HTMLInputElement;
  const bodyInput = h("textarea", { class: "mail-input mail-area", rows: 2 }) as HTMLTextAreaElement;
  const status = h("div", { class: "mail-status" });
  const sendBtn = h("button", { class: "btn primary" }) as HTMLButtonElement;
  const fileName = h("span", { class: "sub" });

  let sending = false;
  let prefilled = false;

  const send = async () => {
    if (sending) return;
    const recipient = toInput.value.trim();
    if (!recipient) {
      status.textContent = t("Missing recipient.");
      return;
    }
    const subject = subjectInput.value.trim() || State.droppedFile?.name || t("File");
    const path = State.droppedFile?.path ?? null;

    const [hasKey, hasFrom] = IS_TAURI
      ? await Promise.all([
          Bridge.secretPresent("resend-api-key"),
          Bridge.secretPresent("resend-from"),
        ])
      : [false, false];

    if (hasKey && !hasFrom) {
      status.textContent = t("Set sender address in Settings.");
      return;
    }
    if (!hasKey) {
      const url = `mailto:${encodeURIComponent(recipient)}` +
        `?subject=${encodeURIComponent(subject)}&body=${encodeURIComponent(bodyInput.value)}`;
      void actions.openUrl(url);
      actions.mailDone(t("Draft opened in your mail app — attach the file there."));
      return;
    }

    sending = true;
    sendBtn.textContent = t("Sending…");
    status.textContent = "";
    try {
      await Bridge.resendSend(recipient, subject, bodyInput.value, path);
      actions.mailDone(t("Email sent to {recipient}.", { recipient }));
    } catch (e) {
      const code = String(e);
      status.textContent =
        code === "no-from" ? t("Set sender address in Settings.")
        : code === "too-big" ? t("The file is too large to email.")
        : t("Resend error — check the API key and the sender.");
    } finally {
      sending = false;
      sendBtn.textContent = t("Send");
    }
  };
  sendBtn.onclick = () => void send();

  const field = (label: Msg, input: HTMLElement) =>
    h("div", { class: "mail-row" }, h("span", { class: "mail-label", text: label }), input);

  const el = h(
    "div",
    { class: "view" },
    h(
      "div",
      { class: "card" },
      h(
        "div",
        { class: "stack mail-stack" },
        h("div", { class: "mail-head" }, h("b", { text: tl("New email") }), fileName),
        field(tl("To"), toInput),
        field(tl("Subject"), subjectInput),
        bodyInput,
        status,
        h(
          "div",
          { class: "actions" },
          sendBtn,
          h("button", {
            class: "btn secondary",
            text: tl("Cancel"),
            onclick: () => actions.setView("choose"),
          }),
        ),
      ),
    ),
  );

  return {
    el,
    focus() {
      toInput.focus();
    },
    sync() {
      fileName.textContent = State.droppedFile
        ? t("with {name}", { name: State.droppedFile.name })
        : "";
      // The Mac pre-fills the subject with the file name — once, so typing is
      // never clobbered by a later sync.
      if (!prefilled) {
        prefilled = true;
        subjectInput.value = State.droppedFile?.name ?? "";
        sendBtn.textContent = t("Send");
      }
    },
  };
}
