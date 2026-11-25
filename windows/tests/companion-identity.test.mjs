import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { registerHooks } from "node:module";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import ts from "typescript";
import { installFakeDom } from "./fakedom.mjs";
import { calls } from "./tauri.mjs";

registerHooks({
  resolve(specifier, context, nextResolve) {
    if (specifier.endsWith(".css")) {
      return { url: new URL(specifier, context.parentURL).href, shortCircuit: true };
    }
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (url.endsWith(".css")) return { format: "module", source: "", shortCircuit: true };
    if (url.endsWith("/hub/hero.ts")) {
      const { outputText } = ts.transpileModule(readFileSync(fileURLToPath(url), "utf8"), {
        compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.ESNext },
      });
      return { format: "module", source: outputText, shortCircuit: true };
    }
    return nextLoad(url, context);
  },
});

const dom = installFakeDom();
document.visibilityState = "hidden";
document.addEventListener = () => {};
document.documentElement = { dataset: {} };
window.addEventListener = () => {};

const {
  COMPANION_NAME_MAX_LENGTH,
  DEFAULT_COMPANION_NAME,
  companionPossessive,
  needsCompanionOnboarding,
  normalizeCompanionName,
  resolveCompanionName,
  sanitizeCompanionName,
  validateCompanionName,
} = await import("../src/core/companion-identity.ts");
const { DEFAULT_SETTINGS, State } = await import("../src/core/state.ts");
const { renderCompanionOnboarding } = await import("../src/hub/onboarding.ts");
const { GlobalWelcomeMessages } = await import("../src/core/welcome.ts");
const { PromptBuilder } = await import("../src/companion/prompt.ts");
const { MessageValidator } = await import("../src/companion/validator.ts");
const { ContextIntelligence } = await import("../src/companion/context.ts");
const { NOTCH_PAGES } = await import("../src/hub/shell.ts");
const { buildWhatsNew } = await import("../src/views/whatsnew.ts");
const { buildUpdate } = await import("../src/views/update.ts");
const { Updates } = await import("../src/island/update.ts");
const { appearanceSection } = await import("../src/settings/appearance.ts");
const { buildCompanionNameRow } = await import("../src/settings/companion-name.ts");
const { WhatsNew } = await import("../src/whats-new/controller.ts");

const settle = () => new Promise((r) => setImmediate(r));

beforeEach(() => {
  calls.length = 0;
  State.settings = { ...DEFAULT_SETTINGS, companionName: "", companionSetupCompleted: false };
});

test("companion identity resolution falls back cleanly to default and detects onboarding need", () => {
  assert.equal(resolveCompanionName(null), DEFAULT_COMPANION_NAME);
  assert.equal(resolveCompanionName({ companionName: "", companionSetupCompleted: false }), DEFAULT_COMPANION_NAME);
  assert.equal(resolveCompanionName({ companionName: "   ", companionSetupCompleted: false }), DEFAULT_COMPANION_NAME);
  assert.equal(resolveCompanionName({ companionName: "  Nova  ", companionSetupCompleted: true }), "Nova");

  assert.equal(needsCompanionOnboarding({ companionName: "", companionSetupCompleted: false }), true);
  assert.equal(needsCompanionOnboarding({ companionName: "   ", companionSetupCompleted: false }), true);
  assert.equal(needsCompanionOnboarding({ companionName: "", companionSetupCompleted: true }), false);
  assert.equal(needsCompanionOnboarding({ companionName: "Nova", companionSetupCompleted: false }), false);

  assert.equal(companionPossessive("Mochi"), "Mochi's");
  assert.equal(companionPossessive("Atlas"), "Atlas'");
  assert.equal(companionPossessive("Nova"), "Nova's");
});

test("companion name validation handles empty, whitespace, long names, control chars, Unicode, and compound emojis", () => {
  assert.equal(normalizeCompanionName("  Kira \n\t Fox  "), "Kira Fox");
  assert.equal(normalizeCompanionName("No\u0007va"), "Nova");

  assert.equal(validateCompanionName("").valid, false);
  assert.equal(validateCompanionName("    \t\n").valid, false);
  assert.equal(validateCompanionName("\u0000\u001b").valid, false);

  const ok = validateCompanionName("  José-María  ");
  assert.equal(ok.valid, true);
  assert.equal(ok.normalized, "José-María");

  for (const unicodeName of ["ひかり", "नव्या", "نور", "Аврора", "Kira 🦊"]) {
    const res = validateCompanionName(unicodeName);
    assert.equal(res.valid, true, `Should accept Unicode/emoji name: ${unicodeName}`);
  }

  // Compound ZWJ emoji counts as 1 grapheme cluster
  const exactly24 = "👨‍🚀".repeat(COMPANION_NAME_MAX_LENGTH);
  assert.equal(validateCompanionName(exactly24).valid, true);

  const overLimit = "a".repeat(COMPANION_NAME_MAX_LENGTH + 1);
  const bad = validateCompanionName(overLimit);
  assert.equal(bad.valid, false);
  assert.match(bad.error ?? "", /24/);
  assert.equal(sanitizeCompanionName(overLimit).length, COMPANION_NAME_MAX_LENGTH);
});

test("onboarding UI validates blank input, prevents double submission, saves trimmed name, and supports skip", async () => {
  const root = dom.root();
  let completedWith = null;
  let saveCount = 0;

  const origSave = (await import("../src/core/bridge.ts")).Bridge.saveSettings;
  const { Bridge } = await import("../src/core/bridge.ts");
  Bridge.saveSettings = async (next) => {
    saveCount++;
    await new Promise((r) => setTimeout(r, 15));
    completedWith = { ...next };
  };

  try {
    const handle = renderCompanionOnboarding(root, {
      initialSettings: { ...DEFAULT_SETTINGS, companionName: "", companionSetupCompleted: false },
      onComplete: (s) => {
        State.settings = { ...s };
      },
    });

    const input = root.find(".onboard-input")[0];
    const errorEl = root.find(".onboard-error")[0];
    const form = root.find(".onboard-card")[0];
    const skipBtn = root.find(".ghost")[0];
    assert.ok(skipBtn);

    // Never preselected
    assert.equal(input.value, "");
    assert.equal(input.getAttribute("placeholder"), "What should I call your companion?");

    // Blank submit is rejected cleanly without saving
    input.value = "   ";
    form.fire("submit", { preventDefault() {} });
    await settle();
    assert.equal(saveCount, 0);
    assert.ok(errorEl.textContent.length > 0);

    // Typing updates live preview dynamically
    input.value = "  Aria ✨  ";
    input.fire("input");
    const preview = root.find(".onboard-preview-text")[0];
    assert.ok(preview.textContent.includes("Aria ✨"));

    // Rapid duplicate submit fires only once
    form.fire("submit", { preventDefault() {} });
    form.fire("submit", { preventDefault() {} });
    await new Promise((r) => setTimeout(r, 40));
    assert.equal(saveCount, 1);
    assert.equal(completedWith.companionName, "Aria ✨");
    assert.equal(completedWith.companionSetupCompleted, true);
    assert.equal(State.companionName, "Aria ✨");
    handle.destroy();

    // Skip action falls back to DEFAULT_COMPANION_NAME and marks onboarding completed
    saveCount = 0;
    const root2 = dom.root();
    const handle2 = renderCompanionOnboarding(root2, {
      initialSettings: { ...DEFAULT_SETTINGS, companionName: "", companionSetupCompleted: false },
      onComplete: (s) => { State.settings = { ...s }; },
    });
    const skipBtn2 = root2.find(".ghost")[0];
    skipBtn2.fire("click");
    await new Promise((r) => setTimeout(r, 40));
    assert.equal(saveCount, 1);
    assert.equal(completedWith.companionName, DEFAULT_COMPANION_NAME);
    assert.equal(completedWith.companionSetupCompleted, true);
    assert.equal(State.companionName, DEFAULT_COMPANION_NAME);
    handle2.destroy();
  } finally {
    Bridge.saveSettings = origSave;
  }
});

test("dynamic companion name propagates to greetings, AI prompts, validator, Hub subtitles, and What's New without restart", async () => {
  State.settings = { ...DEFAULT_SETTINGS, companionName: "Nova", companionSetupCompleted: true };
  GlobalWelcomeMessages.detectedGreetingName = "Alex";
  GlobalWelcomeMessages.preferredName = "";

  // Preview & poke use Nova instead of Mochi
  GlobalWelcomeMessages.triggerPreview();
  const preview = GlobalWelcomeMessages.active();
  assert.ok(preview && preview.text.includes("Nova"));
  assert.equal(/\bMochi\b/.test(preview.text), false);

  GlobalWelcomeMessages.poke();
  const poke = GlobalWelcomeMessages.active();
  assert.ok(poke);
  assert.equal(/\bMochi\b/.test(poke.text), false);
  GlobalWelcomeMessages.dismiss();

  // Catalog message that mentions companion uses Nova
  const seatWarm = GlobalWelcomeMessages["getCatalog"]().find((c) => c.id === "core_seat_warm");
  assert.equal(seatWarm.template("Alex"), "Nova kept your seat warm, Alex!");

  // PromptBuilder and ContextIntelligence reflect companion identity
  const snap = ContextIntelligence.capture("greeting_return", 300);
  const payload = PromptBuilder.buildPayload(snap, "warm_playful", [], "ollama", "qwen3.5:4b");
  assert.ok(payload.systemPrompt.startsWith("You are Nova,"));
  assert.equal(JSON.parse(payload.userContextJson).companion_name, "Nova");

  // MessageValidator strips custom companion preamble
  const cleaned = MessageValidator.sanitizeAndValidate('Nova says: "Time for a quick stretch, Alex!"');
  assert.equal(cleaned, "Time for a quick stretch, Alex!");

  // Hub sidebar page subtitles use configured companion name dynamically
  const general = NOTCH_PAGES.find((p) => p.id === "general");
  const appearance = NOTCH_PAGES.find((p) => p.id === "appearance");
  const agents = NOTCH_PAGES.find((p) => p.id === "agents");
  assert.ok(general.subtitle().includes("Nova"));
  assert.ok(appearance.subtitle().includes("Nova"));
  assert.ok(agents.subtitle().includes("Nova"));

  // What's New stepTwo reflects companion name and updates cleanly on rename
  WhatsNew.release = {
    version: "0.6.1",
    items: [{ icon: "sparkles", title: { en: "Title" }, detail: { en: "Detail" } }],
  };
  WhatsNew.step = 2;
  const wn = buildWhatsNew();
  wn.sync();
  const initialText = wn.el.textContent;
  assert.ok(initialText.includes("Nova"), "What's New card should show configured companion name");
  assert.equal(/\bMochi\b/.test(initialText), false);

  // Instant rename sync without restart
  State.settings = { ...State.settings, companionName: "Ori", companionSetupCompleted: true };
  GlobalWelcomeMessages.invalidateForCompanionRename();
  wn.sync();
  assert.ok(wn.el.textContent.includes("Ori"));
  assert.equal(/\bNova\b/.test(wn.el.textContent), false);

  // Update view uses configured companion name when asking permission
  Updates.asking = true;
  const upd = buildUpdate();
  upd.sync();
  assert.ok(upd.el.textContent.includes("Ori checks Coucou's releases"));
  assert.equal(/\bMochi\b/.test(upd.el.textContent), false);
  Updates.asking = false;

  // Appearance settings section reflects configured companion name across wardrobe & resting notch
  const fakeToggle = () => dom.root();
  const appSettings = { ...DEFAULT_SETTINGS, companionName: "Ori", companionSetupCompleted: true, screen: "primary" };
  const appEl = appearanceSection(
    appSettings,
    async () => {},
    fakeToggle,
    () => {},
    () => dom.root(),
    () => {},
  );
  await settle();
  const appText = appEl.textContent;
  assert.ok(appText.includes("Ori's Wardrobe"));
  assert.ok(appText.includes("Select an outfit for Ori"));
  assert.equal(/\bMochi's Wardrobe\b/.test(appText), false);
});

test("Settings companion name editor supports edit, cancel, validation, and synchronized save", async () => {
  const localSettings = { ...DEFAULT_SETTINGS, companionName: "Nova", companionSetupCompleted: true };
  let saves = 0;
  let redraws = 0;
  const row = buildCompanionNameRow({
    settings: localSettings,
    save: async () => { saves++; },
    onRenamed: () => { redraws++; },
  });

  // Displays current name badge
  assert.equal(row.el.find(".companion-name-badge")[0].textContent, "Nova");

  // Click Edit -> cancel restores prior name cleanly without saving
  const editBtn = row.el.find("BUTTON").find((b) => b.textContent === "Edit");
  editBtn.fire("click");
  let input = row.el.find(".companion-name-input")[0];
  assert.equal(input.value, "Nova");
  input.value = "Temporary";
  const cancelBtn = row.el.find("BUTTON").find((b) => b.textContent === "Cancel");
  cancelBtn.fire("click");
  assert.equal(saves, 0);
  assert.equal(localSettings.companionName, "Nova");
  assert.equal(row.el.find(".companion-name-badge")[0].textContent, "Nova");

  // Empty/whitespace save is rejected inline and keeps edit open
  row.el.find("BUTTON").find((b) => b.textContent === "Edit").fire("click");
  input = row.el.find(".companion-name-input")[0];
  input.value = "   ";
  row.el.find("BUTTON").find((b) => b.textContent === "Save").fire("click");
  await settle();
  assert.equal(saves, 0);
  assert.ok(row.el.find(".companion-name-error")[0].textContent.length > 0);

  // Valid trimmed Unicode/emoji save updates settings, State, and triggers redraw immediately
  input.value = "  Solstice 🦊  ";
  row.el.find("BUTTON").find((b) => b.textContent === "Save").fire("click");
  await settle();
  assert.equal(saves, 1);
  assert.equal(redraws, 1);
  assert.equal(localSettings.companionName, "Solstice 🦊");
  assert.equal(State.companionName, "Solstice 🦊");
  assert.equal(row.el.find(".companion-name-badge")[0].textContent, "Solstice 🦊");
});
