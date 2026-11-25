// Tests for Coucou Notch companion naming onboarding (src/views/onboarding.ts),
// layout & update guards (src/core/layout.ts, src/core/update.ts), and
// personalized Notch messages across launch/poke/welcome banners (src/core/welcome.ts).

import { afterEach, beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { VIEW_LAYOUTS, botPosition, islandSize } from "../src/core/layout.ts";
import { mayOffer } from "../src/core/update.ts";
import { DEFAULT_SETTINGS, State } from "../src/core/state.ts";
import {
  COMPANION_NAME_MAX_LENGTH,
  DEFAULT_COMPANION_NAME,
  companionPossessive,
  needsCompanionOnboarding,
  resolveCompanionName,
} from "../src/core/companion-identity.ts";
import { buildOnboarding, formatNotchOnboardingPreview } from "../src/views/onboarding.ts";
import { GlobalWelcomeMessages } from "../src/core/welcome.ts";
import { setLanguage } from "../src/i18n/i18n.ts";

installFakeDom();

const settle = (ms = 20) => new Promise((resolve) => setTimeout(resolve, ms));

const makeActions = (overrides = {}) => ({
  setView() {},
  cancelDrop() {},
  collapse() {},
  foldApproval() {},
  setFocus() {},
  openTerminal() {},
  openTarget() {},
  openUrl() {},
  decide() {},
  answer() {},
  answerInTerminal() {},
  toggleSound() {},
  setVolume() {},
  setAutoClose() {},
  openSettingsWindow() {},
  blip() {},
  chooseOutfit() {},
  previewOutfit() {},
  keyboard() {},
  launched() {},
  holdOpen() {},
  completeOnboarding: async () => {},
  ...overrides,
});

beforeEach(() => {
  setLanguage("en");
  State.settings = {
    ...DEFAULT_SETTINGS,
    companionName: DEFAULT_COMPANION_NAME,
    companionSetupCompleted: true,
  };
  State.mode = "hidden";
  State.view = "overview";
  GlobalWelcomeMessages.enabled = true;
  GlobalWelcomeMessages.preferredName = "";
  GlobalWelcomeMessages.detectedGreetingName = "";
  GlobalWelcomeMessages.dismiss();
});

afterEach(() => {
  GlobalWelcomeMessages.dismiss();
  GlobalWelcomeMessages.hasGreetedOnLaunch = false;
  State.settings = { ...DEFAULT_SETTINGS };
});

test("Notch onboarding layout centers Mochi beside the card with zero header chrome", () => {
  const layout = VIEW_LAYOUTS.onboarding;
  assert.equal(layout.agentMode, "none");
  assert.equal(layout.height, 196);
  assert.equal(layout.botX, 68);
  assert.equal(layout.botY, 97);
  assert.equal(layout.botDiameter, 62);

  assert.deepEqual(islandSize("expanded", "onboarding"), { w: 640, h: 196 });
  assert.deepEqual(botPosition("expanded", "onboarding", 196), {
    cx: 68,
    cy: 97,
    diameter: 62,
    opacity: 1,
  });
});

test("Notch onboarding card displays exact copy, empty non-preselected input, and live dynamic greeting preview", () => {
  const host = buildOnboarding(makeActions());
  host.el.classList.add("on");
  host.sync();

  const title = host.el.find(".onboard-notch-title")[0];
  const desc = host.el.find(".onboard-notch-desc")[0];
  const input = host.el.find(".onboard-notch-input")[0];
  const counter = host.el.find(".onboard-notch-counter")[0];
  const preview = host.el.find(".onboard-notch-preview-text")[0];

  assert.equal(title.textContent, "Let's give your companion a name.");
  assert.equal(
    desc.textContent,
    "Your little companion lives in your Notch, keeps you company and makes your desktop feel a little more personal.",
  );
  assert.equal(input.value, "");
  assert.equal(input.getAttribute("placeholder"), "What should I call your companion?");
  assert.equal(counter.textContent, `0/${COMPANION_NAME_MAX_LENGTH}`);
  assert.equal(preview.textContent, "Your companion is waiting for a name.");

  assert.equal(formatNotchOnboardingPreview("Luna", 9), "Good morning! I'm Luna.");
  assert.equal(formatNotchOnboardingPreview("Luna", 14), "Good afternoon! I'm Luna.");
  assert.equal(formatNotchOnboardingPreview("Luna", 20), "Good evening! I'm Luna.");

  input.value = "  Luna  ";
  input.fire("input");
  assert.equal(counter.textContent, `4/${COMPANION_NAME_MAX_LENGTH}`);
  assert.ok(preview.textContent.includes("I'm Luna."));
  assert.equal(preview.classList.contains("placeholder"), false);
});

test("Notch onboarding rejects blank or overly long names, accepts Unicode/emojis, and isolates key events", async () => {
  const submissions = [];
  const host = buildOnboarding(
    makeActions({
      completeOnboarding: async (name, skipped) => {
        submissions.push({ name, skipped });
      },
    }),
  );
  host.el.classList.add("on");
  host.sync();

  const form = host.el.find(".onboard-notch-stack")[0];
  const input = host.el.find(".onboard-notch-input")[0];
  const counter = host.el.find(".onboard-notch-counter")[0];
  const errorEl = host.el.find(".onboard-notch-error")[0];

  // Key events inside input must stop bubbling so Notch Escape/navigation never steals focus.
  let parentSawKey = false;
  host.el.addEventListener("keydown", () => {
    parentSawKey = true;
  });
  input.fire("keydown", { key: "Escape" });
  assert.equal(parentSawKey, false);

  // Empty / whitespace submit blocked
  input.value = "   \t  ";
  form.fire("submit", { preventDefault() {} });
  await settle();
  assert.equal(submissions.length, 0);
  assert.equal(input.classList.contains("invalid"), true);
  assert.ok(errorEl.textContent.length > 0);

  // Over max grapheme limit blocked
  input.value = "A".repeat(COMPANION_NAME_MAX_LENGTH + 1);
  input.fire("input");
  assert.equal(counter.classList.contains("over"), true);
  form.fire("submit", { preventDefault() {} });
  await settle();
  assert.equal(submissions.length, 0);

  // Multi-codepoint ZWJ emojis at exact 24 grapheme clusters succeed
  const emoji24 = "👩‍🚀".repeat(COMPANION_NAME_MAX_LENGTH);
  input.value = emoji24;
  input.fire("input");
  assert.equal(counter.textContent, `24/${COMPANION_NAME_MAX_LENGTH}`);
  assert.equal(counter.classList.contains("over"), false);
  form.fire("submit", { preventDefault() {} });
  await settle();
  assert.deepEqual(submissions, [{ name: emoji24, skipped: false }]);
});

test("Notch onboarding prevents duplicate submissions, supports Skip default, and recovers from save failure", async () => {
  const calls = [];
  let shouldFail = true;
  const host = buildOnboarding(
    makeActions({
      completeOnboarding: async (name, skipped) => {
        calls.push({ name, skipped });
        await settle(15);
        if (shouldFail) throw new Error("Disk write failed");
      },
    }),
  );
  host.el.classList.add("on");
  host.sync();

  const form = host.el.find(".onboard-notch-stack")[0];
  const input = host.el.find(".onboard-notch-input")[0];
  const continueBtn = host.el.find(".primary")[0];
  const skipBtn = host.el.find(".secondary")[0];
  const errorEl = host.el.find(".onboard-notch-error")[0];

  // Error recovers cleanly and re-enables buttons
  input.value = "Nova";
  form.fire("submit", { preventDefault() {} });
  form.fire("submit", { preventDefault() {} });
  assert.equal(continueBtn.disabled, true);
  assert.equal(skipBtn.disabled, true);
  await settle(30);
  assert.equal(calls.length, 1);
  assert.equal(errorEl.textContent, "Disk write failed");
  assert.equal(continueBtn.disabled, false);
  assert.equal(skipBtn.disabled, false);

  // Skip commits default name cleanly with skipped=true
  shouldFail = false;
  skipBtn.fire("click");
  skipBtn.fire("click");
  await settle(30);
  assert.equal(calls.length, 2);
  assert.deepEqual(calls[1], { name: DEFAULT_COMPANION_NAME, skipped: true });
});

test("update banner offers wait until Notch onboarding finishes", () => {
  const onboardingCtx = { paused: false, pending: false, mode: "expanded", view: "onboarding" };
  assert.equal(mayOffer("ask", onboardingCtx), false);
  assert.equal(mayOffer("announce", onboardingCtx), false);
});

test("personalized Notch greetings, welcome toast, and poke adapt dynamically after naming and rename", () => {
  assert.equal(needsCompanionOnboarding({ companionName: "", companionSetupCompleted: false }), true);
  assert.equal(needsCompanionOnboarding({ companionName: "Kiki", companionSetupCompleted: true }), false);
  assert.equal(resolveCompanionName({ companionName: "  Kiki  " }), "Kiki");
  assert.equal(companionPossessive("Alex"), "Alex's");
  assert.equal(companionPossessive("James"), "James'");

  State.settings = {
    ...DEFAULT_SETTINGS,
    companionName: "Kiki",
    companionSetupCompleted: true,
  };
  GlobalWelcomeMessages.preferredName = "Sam";
  GlobalWelcomeMessages.triggerOnboardingWelcome("Kiki", false);
  const welcome = GlobalWelcomeMessages.active();
  assert.ok(welcome);
  assert.equal(welcome.id, "onboarding_welcome");
  assert.equal(welcome.bot, true);
  assert.ok(welcome.text.includes("Kiki"));
  assert.ok(welcome.text.includes("Sam"));

  // Skip onboarding welcome uses default companion name safely even with empty user greeting name
  GlobalWelcomeMessages.preferredName = "";
  GlobalWelcomeMessages.triggerOnboardingWelcome(DEFAULT_COMPANION_NAME, true);
  const skippedWelcome = GlobalWelcomeMessages.active();
  assert.ok(skippedWelcome);
  assert.ok(skippedWelcome.text.includes(DEFAULT_COMPANION_NAME));
  assert.equal(skippedWelcome.text.includes("undefined"), false);
  assert.equal(skippedWelcome.text.includes("null"), false);

  // Rename companion and verify live invalidation + updated messages across launch and poke
  State.settings = {
    ...DEFAULT_SETTINGS,
    companionName: "Atlas",
    companionSetupCompleted: true,
  };
  GlobalWelcomeMessages.invalidateForCompanionRename();
  assert.equal(GlobalWelcomeMessages.active(), null);

  let foundAtlasOnLaunch = false;
  for (let i = 0; i < 8; i++) {
    GlobalWelcomeMessages.hasGreetedOnLaunch = false;
    GlobalWelcomeMessages.onAppLaunch();
    const msg = GlobalWelcomeMessages.active();
    assert.ok(msg && msg.text.length > 0);
    if (msg.text.includes("Atlas")) {
      foundAtlasOnLaunch = true;
      break;
    }
  }
  assert.equal(foundAtlasOnLaunch, true, "onAppLaunch should surface the customized companion name naturally");

  let foundAtlasOnPoke = false;
  for (let i = 0; i < 20; i++) {
    GlobalWelcomeMessages.poke();
    const poked = GlobalWelcomeMessages.active();
    assert.ok(poked && poked.text.length > 0);
    assert.equal(poked.text.includes("Mochi"), false);
    if (poked.text.includes("Atlas")) {
      foundAtlasOnPoke = true;
      break;
    }
  }
  assert.equal(foundAtlasOnPoke, true, "poke should reflect renamed companion");
});
