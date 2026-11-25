/**
 * First-run companion naming experience rendered inside the Hub window on initial launch.
 * Reuses Coucou's dark-glass surface system and the live Mochi canvas avatar without
 * adding external UI dependencies or extra WebView windows.
 */

import { Bridge } from "../core/bridge";
import {
  COMPANION_NAME_MAX_LENGTH,
  DEFAULT_COMPANION_NAME,
  countCompanionGraphemes,
  normalizeCompanionName,
  validateCompanionName,
} from "../core/companion-identity";
import { DEFAULT_SETTINGS, type Settings } from "../core/state";
import { t } from "../i18n/i18n";
import { clear, h } from "../views/dom";
import { liveMochi } from "./hero";

export interface OnboardingOptions {
  initialSettings?: Settings;
  onComplete: (nextSettings: Settings) => Promise<void> | void;
}

function formatPreviewGreeting(name: string, hour = new Date().getHours()): string {
  if (hour >= 5 && hour < 12) return t("Good morning — {name} is ready to help.", { name });
  if (hour >= 12 && hour < 17) return t("Good afternoon — {name} is ready to help.", { name });
  return t("Good evening — {name} is ready to help.", { name });
}

export function renderCompanionOnboarding(
  container: HTMLElement,
  opts: OnboardingOptions,
): { destroy(): void } {
  const baseSettings: Settings = { ...DEFAULT_SETTINGS, ...(opts.initialSettings ?? {}) };
  let submitting = false;
  let destroyed = false;

  clear(container);

  const avatarCanvas = h("canvas", {
    class: "onboard-avatar",
    width: "184",
    height: "184",
    "aria-hidden": "true",
  }) as HTMLCanvasElement;
  try {
    liveMochi(avatarCanvas, "#F5F6F8", "idle");
  } catch {
    // Non-canvas test environments (fakedom) skip 2D rendering cleanly.
  }

  const title = h("h1", {
    class: "onboard-title",
    text: t("Let's give your companion a name."),
  });
  const desc = h("p", {
    class: "onboard-desc",
    text: t("Your little companion lives in your Notch, keeps you company and makes your desktop feel a little more personal."),
  });

  const input = h("input", {
    class: "onboard-input",
    type: "text",
    value: "",
    autocomplete: "off",
    spellcheck: "false",
    maxlength: "64",
    placeholder: t("What should I call your companion?"),
    "aria-label": t("Companion name"),
  }) as HTMLInputElement;
  input.value = "";

  const counter = h("span", {
    class: "onboard-counter",
    text: `0/${COMPANION_NAME_MAX_LENGTH}`,
  });

  const errorBox = h("div", {
    class: "onboard-error",
    role: "alert",
    "aria-live": "polite",
  });

  const previewText = h("span", {
    class: "onboard-preview-text placeholder",
    text: t("Your companion is waiting for a name."),
  });
  const previewPill = h(
    "div",
    { class: "onboard-preview", "aria-live": "polite" },
    h("span", { class: "onboard-preview-dot", "aria-hidden": "true" }),
    previewText,
  );

  const continueBtn = h("button", {
    type: "submit",
    class: "onboard-btn primary",
    text: t("Continue"),
  }) as HTMLButtonElement;

  const skipBtn = h("button", {
    type: "button",
    class: "onboard-btn ghost",
    text: t("Skip for now"),
    title: t("Use default ({name})", { name: DEFAULT_COMPANION_NAME }),
    "aria-label": t("Use default ({name})", { name: DEFAULT_COMPANION_NAME }),
  }) as HTMLButtonElement;

  const syncLivePreview = () => {
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

    if (normalized.length > 0 && count <= COMPANION_NAME_MAX_LENGTH) {
      previewText.textContent = formatPreviewGreeting(normalized);
      previewText.classList.remove("placeholder");
    } else if (normalized.length > 0) {
      const check = validateCompanionName(input.value, t);
      previewText.textContent = check.valid
        ? formatPreviewGreeting(check.normalized)
        : t("Your companion is waiting for a name.");
      previewText.classList.add("placeholder");
    } else {
      previewText.textContent = t("Your companion is waiting for a name.");
      previewText.classList.add("placeholder");
    }
  };

  const setBusy = (busy: boolean) => {
    submitting = busy;
    continueBtn.disabled = busy;
    skipBtn.disabled = busy;
    input.disabled = busy;
  };

  const commitName = async (chosenName: string) => {
    if (submitting || destroyed) return;
    setBusy(true);
    try {
      const nextSettings: Settings = {
        ...baseSettings,
        companionName: chosenName,
        companionSetupCompleted: true,
      };
      await Bridge.saveSettings(nextSettings);
      await opts.onComplete(nextSettings);
    } catch (err) {
      if (!destroyed) {
        setBusy(false);
        errorBox.textContent = err instanceof Error && err.message ? err.message : t("Could not save settings.");
      }
    }
  };

  input.addEventListener("input", syncLivePreview);

  const onSubmit = (e: Event) => {
    e.preventDefault();
    if (submitting || destroyed) return;
    const result = validateCompanionName(input.value, t);
    if (!result.valid) {
      input.classList.add("invalid");
      errorBox.textContent = result.error ?? t("Please enter a name for your companion.");
      input.focus?.();
      return;
    }
    void commitName(result.normalized);
  };

  const onSkip = () => {
    if (submitting || destroyed) return;
    void commitName(DEFAULT_COMPANION_NAME);
  };

  skipBtn.addEventListener("click", onSkip);

  const form = h(
    "form",
    { class: "onboard-card", novalidate: "true" },
    h("div", { class: "onboard-avatar-wrap" }, avatarCanvas),
    title,
    desc,
    h(
      "div",
      { class: "onboard-field-wrap" },
      h("div", { class: "onboard-input-row" }, input, counter),
      errorBox,
    ),
    previewPill,
    h("div", { class: "onboard-actions" }, continueBtn, skipBtn),
  ) as HTMLFormElement;
  form.addEventListener("submit", onSubmit);

  const shell = h("div", { class: "onboard-shell" }, form);
  container.append(shell);

  if (typeof requestAnimationFrame === "function") {
    requestAnimationFrame(() => {
      if (!destroyed) input.focus?.();
    });
  }

  return {
    destroy() {
      destroyed = true;
      form.removeEventListener?.("submit", onSubmit);
      skipBtn.removeEventListener?.("click", onSkip);
      input.removeEventListener?.("input", syncLivePreview);
    },
  };
}
