/**
 * Settings -> General -> Companion Name inline editor row.
 * Supports display badge, inline edit/save/cancel, Enter/Escape keyboard flow,
 * grapheme validation, duplicate-submit guard, and instant Hub redraw propagation.
 */

import {
  COMPANION_NAME_MAX_LENGTH,
  resolveCompanionName,
  validateCompanionName,
} from "../core/companion-identity";
import { State, type Settings } from "../core/state";
import { GlobalWelcomeMessages } from "../core/welcome";
import { t } from "../i18n/i18n";
import { clear, h } from "../views/dom";

export interface CompanionNameRowOptions {
  settings: Settings;
  save: () => Promise<void>;
  onRenamed: () => void;
}

export interface CompanionNameRowHandle {
  el: HTMLElement;
  sync: () => void;
}

export function buildCompanionNameRow(opts: CompanionNameRowOptions): CompanionNameRowHandle {
  let editing = false;
  let savingName = false;

  const currentName = () => resolveCompanionName(opts.settings);

  const badge = h("span", {
    class: "companion-name-badge",
    text: currentName(),
  });
  const editBtn = h("button", {
    text: t("Edit"),
  }) as HTMLButtonElement;

  const input = h("input", {
    type: "text",
    class: "companion-name-input",
    value: currentName(),
    maxlength: "64",
    placeholder: t("Give your companion a name..."),
    "aria-label": t("Companion name"),
  }) as HTMLInputElement;
  const countEl = h("span", { class: "companion-name-count" });
  const saveBtn = h("button", {
    class: "primary",
    text: t("Save"),
  }) as HTMLButtonElement;
  const cancelBtn = h("button", {
    text: t("Cancel"),
  }) as HTMLButtonElement;
  const errorEl = h("div", {
    class: "companion-name-error",
    role: "alert",
    "aria-live": "polite",
  });
  const bar = h("div", { class: "companion-name-bar" });
  const control = h("div", { class: "companion-name-control" }, bar, errorEl);

  const updateCounter = () => {
    const check = validateCompanionName(input.value, t);
    countEl.textContent = `${check.length}/${COMPANION_NAME_MAX_LENGTH}`;
    countEl.classList.toggle("over", check.length > COMPANION_NAME_MAX_LENGTH);
    if (check.length <= COMPANION_NAME_MAX_LENGTH && errorEl.textContent) {
      input.classList.remove("invalid");
      errorEl.textContent = "";
    }
  };

  const renderControl = () => {
    clear(bar);
    if (!editing) {
      badge.textContent = currentName();
      errorEl.textContent = "";
      bar.append(badge, editBtn);
    } else {
      updateCounter();
      bar.append(input, countEl, saveBtn, cancelBtn);
    }
  };

  const cancelEdit = () => {
    editing = false;
    input.value = currentName();
    input.classList.remove("invalid");
    errorEl.textContent = "";
    renderControl();
  };

  const commitEdit = async () => {
    if (savingName) return;
    const validation = validateCompanionName(input.value, t);
    if (!validation.valid) {
      input.classList.add("invalid");
      errorEl.textContent = validation.error ?? t("Please enter a name for your companion.");
      input.focus?.();
      return;
    }
    savingName = true;
    saveBtn.disabled = true;
    cancelBtn.disabled = true;
    try {
      opts.settings.companionName = validation.normalized;
      opts.settings.companionSetupCompleted = true;
      State.settings = { ...State.settings, ...opts.settings };
      await opts.save();
      GlobalWelcomeMessages.invalidateForCompanionRename();
      editing = false;
      renderControl();
      opts.onRenamed();
    } catch (err) {
      errorEl.textContent = err instanceof Error && err.message ? err.message : t("Could not save settings.");
    } finally {
      savingName = false;
      saveBtn.disabled = false;
      cancelBtn.disabled = false;
    }
  };

  editBtn.addEventListener("click", () => {
    editing = true;
    input.value = currentName();
    input.classList.remove("invalid");
    errorEl.textContent = "";
    renderControl();
    input.focus?.();
    input.select?.();
  });
  input.addEventListener("input", updateCounter);
  input.addEventListener("keydown", (e: KeyboardEvent) => {
    if (e.key === "Enter") {
      e.preventDefault();
      void commitEdit();
    } else if (e.key === "Escape") {
      e.preventDefault();
      cancelEdit();
    }
  });
  saveBtn.addEventListener("click", () => { void commitEdit(); });
  cancelBtn.addEventListener("click", cancelEdit);

  renderControl();

  const el = h(
    "div",
    { class: "coudrop-group" },
    h(
      "div",
      { class: "coudrop-group-row" },
      h(
        "div",
        { class: "coudrop-row-label-group" },
        h("span", { class: "coudrop-row-title", text: t("Companion name") }),
        h("span", {
          class: "coudrop-row-desc",
          text: t("Choose what to call your desktop companion across greetings, chat, and notifications."),
        }),
      ),
      control,
    ),
  );

  return {
    el,
    sync() {
      if (!editing) {
        renderControl();
      }
    },
  };
}
