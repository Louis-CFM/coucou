// Behavioral tests for Settings → Android phone (src/settings/phone.ts).
// Verifies hero status states, QR pairing expand/collapse, Copy link, Pair again,
// network disclosure, privacy toggles, service visibility checkboxes, AI chat models, and CouDrop links.

import { beforeEach, test } from "node:test";
import assert from "node:assert/strict";
import { installFakeDom } from "./fakedom.mjs";
import { calls, internals, sent } from "./tauri.mjs";

const dom = installFakeDom();
document.visibilityState = "visible";
Object.defineProperty(globalThis, "navigator", {
  value: {
    clipboard: {
      writeText: async () => {},
    },
  },
  configurable: true,
});

let linkStatus = {
  enabled: false,
  running: false,
  port: 47821,
  host: "192.168.1.50",
  name: "TestPC",
  clients: 0,
  error: null,
  relayState: "off",
};
let pairingCount = 0;
let detailsEnabled = false;
let answersEnabled = false;
let diffsEnabled = false;
let usageEnabled = false;
let recapEnabled = false;
let servicesList = ["integration_github", "integration_notion"];
let chatStatus = { enabled: true, models: ["google/gemini-2.5-flash"] };

const originalInvoke = internals.invoke;
internals.invoke = async (cmd, args) => {
  await originalInvoke(cmd, args);
  switch (cmd) {
    case "phone_link_status":
      return linkStatus;
    case "phone_link_set_enabled":
      linkStatus = { ...linkStatus, enabled: args.enabled, running: args.enabled };
      return linkStatus;
    case "phone_link_pairing":
      return {
        link: `coucou://pair?v=1&host=192.168.1.50&port=47821&token=tok${pairingCount}`,
        qrSvg: "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>",
        host: "192.168.1.50",
        port: 47821,
        name: "TestPC",
        relay: null,
      };
    case "phone_link_new_pairing":
      pairingCount += 1;
      return {
        link: `coucou://pair?v=1&host=192.168.1.50&port=47821&token=tok${pairingCount}`,
        qrSvg: "<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>",
        host: "192.168.1.50",
        port: 47821,
        name: "TestPC",
        relay: null,
      };
    case "phone_relay_status":
      return { enabled: false, url: "", hasAccess: false, state: "off", shown: false };
    case "phone_details_status":
      return { enabled: detailsEnabled };
    case "phone_details_set_enabled":
      detailsEnabled = args.enabled;
      return { enabled: detailsEnabled };
    case "phone_answers_status":
      return { enabled: answersEnabled };
    case "phone_answers_set_enabled":
      answersEnabled = args.enabled;
      return { enabled: answersEnabled };
    case "phone_diffs_status":
      return { enabled: diffsEnabled };
    case "phone_diffs_set_enabled":
      diffsEnabled = args.enabled;
      return { enabled: diffsEnabled };
    case "phone_usage_status":
      return { enabled: usageEnabled };
    case "phone_usage_set_enabled":
      usageEnabled = args.enabled;
      return { enabled: usageEnabled };
    case "phone_recap_status":
      return { enabled: recapEnabled };
    case "phone_recap_set_enabled":
      recapEnabled = args.enabled;
      return { enabled: recapEnabled };
    case "phone_services_status":
      return { services: servicesList };
    case "phone_services_set":
      servicesList = args.services;
      return { services: servicesList };
    case "phone_chat_status":
      return chatStatus;
    case "phone_chat_set_enabled":
      chatStatus = { ...chatStatus, enabled: args.enabled };
      return chatStatus;
    case "phone_chat_set_models":
      chatStatus = { ...chatStatus, models: args.models };
      return chatStatus;
    case "secret_present":
      return args.key === "google-api-key" || args.key === "openai-api-key";
    case "chat_models":
      if (args.provider === "google") return [{ id: "gemini-2.5-flash" }, { id: "gemini-2.5-pro" }];
      if (args.provider === "openai") return [{ id: "gpt-4o" }];
      return [];
    case "coudrop_open_folder":
      return null;
    default:
      return originalInvoke(cmd, args);
  }
};

const { h } = await import("../src/views/dom.ts");
const { DEFAULT_SETTINGS } = await import("../src/core/state.ts");
const { phoneSection } = await import("../src/settings/phone.ts");

const settle = () => new Promise((resolve) => setImmediate(resolve));

function makeToggle(on, onChange) {
  const el = h("button", { class: on ? "switch on" : "switch", "aria-pressed": on, type: "button" });
  el.addEventListener("click", () => {
    const next = !el.classList.contains("on");
    el.classList.toggle("on", next);
    el.setAttribute("aria-pressed", String(next));
    onChange(next);
  });
  return el;
}

beforeEach(() => {
  calls.length = 0;
  pairingCount = 0;
  linkStatus = {
    enabled: false,
    running: false,
    port: 47821,
    host: "192.168.1.50",
    name: "TestPC",
    clients: 0,
    error: null,
    relayState: "off",
  };
  detailsEnabled = false;
  answersEnabled = false;
  diffsEnabled = false;
  usageEnabled = false;
  recapEnabled = false;
  servicesList = ["integration_github", "integration_notion"];
  chatStatus = { enabled: true, models: ["google/gemini-2.5-flash"] };
  globalThis.window.location = { hash: "" };
});

test("renders compact hero status and expands full controls when Phone link is enabled", async () => {
  const settings = { ...DEFAULT_SETTINGS, ollamaUrl: "" };
  const el = phoneSection(false, makeToggle, settings);
  await settle();

  const heroTitle = el.querySelector(".phone-hero-title");
  assert.equal(heroTitle?.textContent, "Android phone");
  const pill = el.querySelector(".phone-status-pill");
  assert.equal(pill?.textContent, "Off");

  // Detail sections are hidden when off
  assert.equal(el.querySelector(".phone-services-grid"), null);

  // Turn Phone link ON
  const switches = el.find(".switch");
  switches[0].fire("click");
  await settle();
  await settle();

  assert.equal(sent("phone_link_set_enabled").at(-1).enabled, true);
  assert.equal(pill?.textContent, "Enabled · Listening");
  assert.ok(pill?.classList.contains("listening"));

  // Detail sections now exist
  assert.ok(el.querySelector(".phone-services-grid"), "service visibility grid rendered");
  const allSwitches = el.find(".switch");
  // 1 (Phone link) + 5 (Privacy & approvals) + 1 (AI chat) = 7 switches
  assert.equal(allSwitches.length, 7);
});

test("pairing drawer expands, toggles, copies link with hint, and regenerates code", async () => {
  linkStatus = { ...linkStatus, enabled: true, running: true, clients: 1 };
  const el = phoneSection(true, makeToggle, { ...DEFAULT_SETTINGS, ollamaUrl: "" });
  await settle();
  await settle();

  const pill = el.querySelector(".phone-status-pill");
  assert.equal(pill?.textContent, "Connected · 1");
  assert.ok(pill?.classList.contains("connected"));

  const pairBtn = el.find("button").find((b) => b.textContent === "Show pairing code");
  assert.ok(pairBtn, "Show pairing code button exists");
  assert.equal(el.querySelector(".phone-qr-panel"), null, "QR collapsed by default");

  // Expand QR
  pairBtn.fire("click");
  await settle();
  assert.ok(el.querySelector(".phone-qr-panel"), "QR panel expanded");
  assert.equal(pairBtn.textContent, "Hide pairing code");
  assert.equal(el.querySelector(".qr")?.getAttribute("data-qr"), "ready");

  // Copy link reveals copy warning
  const copyBtn = el.find("button").find((b) => b.textContent === "Copy link");
  const copyWarning = el.querySelector(".phone-copy-warning");
  assert.equal(copyWarning?.hidden, true);
  copyBtn.fire("click");
  await settle();
  assert.equal(copyWarning?.hidden, false);

  // Pair again issues new pairing token
  const repairBtn = el.find("button").find((b) => b.textContent === "Pair again");
  repairBtn.fire("click");
  await settle();
  assert.equal(sent("phone_link_new_pairing").length, 1);
  assert.match(el.querySelector(".phone-link-input")?.getAttribute("value") ?? "", /token=tok1/);

  // Clicking Hide collapses cleanly
  pairBtn.fire("click");
  assert.equal(el.querySelector(".phone-qr-panel"), null);
  assert.equal(pairBtn.textContent, "Show pairing code");
});

test("network disclosure, privacy toggles, service checkboxes, AI providers, and Coudrop actions all work", async () => {
  linkStatus = { ...linkStatus, enabled: true, running: true };
  const el = phoneSection(true, makeToggle, { ...DEFAULT_SETTINGS, ollamaUrl: "http://127.0.0.1:11434" });
  await settle();
  await settle();

  // 1. Network disclosure
  const discBtn = el.querySelector(".phone-disclosure-btn");
  const discBody = el.querySelector(".phone-disclosure-body");
  assert.equal(discBody?.hidden, true);
  discBtn.fire("click");
  assert.equal(discBody?.hidden, false);
  assert.equal(discBtn.getAttribute("aria-expanded"), "true");

  // 2. Privacy toggles
  const switches = el.find(".switch");
  switches[1].fire("click"); // details
  switches[2].fire("click"); // answers
  switches[3].fire("click"); // diffs
  switches[4].fire("click"); // usage
  switches[5].fire("click"); // recap
  await settle();
  assert.equal(sent("phone_details_set_enabled").at(-1).enabled, true);
  assert.equal(sent("phone_answers_set_enabled").at(-1).enabled, true);
  assert.equal(sent("phone_diffs_set_enabled").at(-1).enabled, true);
  assert.equal(sent("phone_usage_set_enabled").at(-1).enabled, true);
  assert.equal(sent("phone_recap_set_enabled").at(-1).enabled, true);

  // 3. Service checkboxes
  const serviceInputs = el.querySelector(".phone-services-grid").find("input");
  assert.equal(serviceInputs.length, 7);
  assert.equal(serviceInputs[0].checked, false); // Stripe
  assert.equal(serviceInputs[1].checked, true); // GitHub
  serviceInputs[0].checked = true;
  serviceInputs[0].fire("change");
  await settle();
  assert.ok(sent("phone_services_set").at(-1).services.includes("integration_stripe"));

  // 4. AI Providers & model picker
  const providerRows = el.find(".phone-provider-row");
  assert.equal(providerRows.length, 3, "Google, OpenAI, Ollama shown");
  const summaries = el.find(".phone-provider-models-summary");
  assert.match(summaries[0].textContent, /1 allowed/);
  assert.equal(summaries[1].textContent, "No models selected");

  const chooseGoogle = providerRows[0].find("button")[0];
  chooseGoogle.fire("click");
  await settle();
  const modelBoxes = el.find(".phone-model-option").map((o) => o.find("input")[0]);
  assert.equal(modelBoxes.length, 2);
  modelBoxes[1].checked = true; // gemini-2.5-pro
  modelBoxes[1].fire("change");
  await settle();
  assert.deepEqual(sent("phone_chat_set_models").at(-1).models, ["google/gemini-2.5-flash", "google/gemini-2.5-pro"]);
  assert.match(summaries[0].textContent, /2 allowed/);

  // 5. CouDrop actions
  const downloadsBtn = el.find("button").find((b) => b.textContent === "Downloads");
  const openCoudropBtn = el.find("button").find((b) => b.textContent === "Open Coudrop settings");
  downloadsBtn.fire("click");
  assert.equal(sent("coudrop_open_folder").length, 1);
  openCoudropBtn.fire("click");
  assert.equal(globalThis.window.location.hash, "#coudrop");
});
