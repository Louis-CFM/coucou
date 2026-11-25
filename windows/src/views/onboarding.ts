/**
 * First-run companion naming onboarding view rendered natively inside the Coucou Notch.
 * Reuses the live `#bot-canvas` companion avatar on the left and Coucou's dark-glass
 * card surface without introducing a separate window or duplicate companion state.
 */

import { h } from "./dom";
import type { ViewActions, ViewHost } from "./views";
import { washRGBA } from "../core/layout";
import {
  COMPANION_NAME_MAX_LENGTH,
  DEFAULT_COMPANION_NAME,
  countCompanionGraphemes,
  normalizeCompanionName,
  validateCompanionName,
} from "../core/companion-identity";
import { t, tl } from "../i18n/i18n";

export function formatNotchOnboardingPreview(name: string, hour = new Date().getHours()): string {
  if (hour >= 5 && hour < 12) return t("Good morning! I'm {name}.", { name });
  if (hour >= 12 && hour < 17) return t("Good afternoon! I'm {name}.", { name });
  return t("Good evening! I'm {name}.", { name });
}

export function buildOnboarding(actions: ViewActions): ViewHost {
  let submitting = false;
  let wasOpen = false;

  const title = h("div", {
    class: "onboard-notch-title",
    text: tl("Let's give your companion a name."),
  });
  const desc = h("p", {
    class: "onboard-notch-desc",
    text: tl("Your little companion lives in your Notch, keeps you company and makes your desktop feel a little more personal."),
  });

  const input = h("input", {
    type: "text",
    class: "onboard-notch-input",
    value: "",
    autocomplete: "off",
    spellcheck: "false",
    maxlength: "64",
    placeholder: tl("What should I call your companion?"),
    "aria-label": tl("Companion name"),
  }) as HTMLInputElement;
  input.value = "";

  const counter = h("span", {
    class: "onboard-notch-counter",
    text: `0/${COMPANION_NAME_MAX_LENGTH}`,
  });

  const errorBox = h("div", {
    class: "onboard-notch-error",
    role: "alert",
    "aria-live": "polite",
  });

  const previewText = h("span", {
    class: "onboard-notch-preview-text placeholder",
    text: t("Your companion is waiting for a name."),
  });
  const previewDot = h("span", {
    class: "onboard-notch-dot",
    "aria-hidden": "true",
  });
  const preview = h(
    "div",
    { class: "onboard-notch-preview", "aria-live": "polite" },
    previewDot,
    previewText,
  );

  const continueBtn = h("button", {
    type: "submit",
    class: "btn primary onboard-notch-btn",
    text: tl("Continue"),
  }) as HTMLButtonElement;

  const skipBtn = h("button", {
    type: "button",
    class: "btn secondary onboard-notch-btn",
    text: tl("Skip for now"),
    title: t("Use default ({name})", { name: DEFAULT_COMPANION_NAME }),
    "aria-label": t("Use default ({name})", { name: DEFAULT_COMPANION_NAME }),
  }) as HTMLButtonElement;

  const setBusy = (busy: boolean) => {
    submitting = busy;
    continueBtn.disabled = busy;
    skipBtn.disabled = busy;
    input.disabled = busy;
  };

  const syncPreview = () => {
    const normalized = normalizeCompanionName(input.value);
    const count = countCompanionGraphemes(normalized);
    counter.textContent = `${count}/${COMPANION_NAME_MAX_LENGTH}`;
    counter.classList.toggle("over", count > COMPANION_NAME_MAX_LENGTH);

    if (count > COMPANION_NAME_MAX_LENGTH) {
      input.classList.add("invalid");
      errorBox.textContent = t("Companion name must be {max} characters or fewer.", {
        max: COMPANION_NAME_MAX_LENGTH,
      });
    } else {
      input.classList.remove("invalid");
      errorBox.textContent = "";
    }

    const ready = normalized.length > 0 && count <= COMPANION_NAME_MAX_LENGTH;
    previewDot.classList.toggle("active", ready);
    if (ready) {
      previewText.textContent = formatNotchOnboardingPreview(normalized);
      previewText.classList.remove("placeholder");
    } else {
      previewText.textContent = t("Your companion is waiting for a name.");
      previewText.classList.add("placeholder");
    }
  };

  const commit = async (chosenName: string, skipped: boolean) => {
    if (submitting) return;
    setBusy(true);
    try {
      await actions.completeOnboarding?.(chosenName, skipped);
    } catch (err) {
      setBusy(false);
      errorBox.textContent = err instanceof Error && err.message ? err.message : t("Could not save settings.");
      input.focus?.();
    }
  };

  input.addEventListener("input", syncPreview);
  input.addEventListener("keydown", (e: KeyboardEvent) => {
    // Keep typing isolated inside the onboarding input so Escape/pill keys never interrupt it.
    e.stopPropagation();
  });

  const form = h(
    "form",
    { class: "stack onboard-notch-stack", novalidate: "true" },
    h("div", { class: "onboard-notch-head" }, title, desc),
    h(
      "div",
      { class: "onboard-notch-field" },
      h("div", { class: "onboard-notch-input-row" }, input, counter),
      errorBox,
    ),
    h(
      "div",
      { class: "onboard-notch-footer" },
      preview,
      h("div", { class: "actions onboard-notch-actions" }, skipBtn, continueBtn),
    ),
  ) as HTMLFormElement;

  form.addEventListener("submit", (e: Event) => {
    e.preventDefault();
    if (submitting) return;
    const result = validateCompanionName(input.value, t);
    if (!result.valid) {
      input.classList.add("invalid");
      errorBox.textContent = result.error ?? t("Please enter a name for your companion.");
      input.focus?.();
      return;
    }
    void commit(result.normalized, false);
  });

  skipBtn.addEventListener("click", () => {
    if (submitting) return;
    void commit(DEFAULT_COMPANION_NAME, true);
  });

  const card = h("div", { class: "card wash onboard-notch-card" }, form);
  card.style.setProperty("--wash", washRGBA("indigo"));

  const el = h("div", { class: "view onboard-view" }, card);

  return {
    el,
    focus() {
      input.focus?.();
    },
    sync() {
      const openNow = el.classList.contains("on");
      if (openNow && !wasOpen) {
        setBusy(false);
        input.value = "";
        input.classList.remove("invalid");
        errorBox.textContent = "";
        syncPreview();
      }
      wasOpen = openNow;
    },
  };
}
