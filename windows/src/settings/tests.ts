// Settings → Agents → Test results: dotpals' "Make agents fix failing tests" and
// "Double-check unclear test results" (Off, Laya on this computer, TypeSafe's
// Jev). Laya is set up, started and removed from here; Jev's key goes to the
// credential store and is never read back.

import { Bridge, onEvent, type LayaStatus } from "../core/bridge";
import type { Settings } from "../core/state";
import { h } from "../views/dom";
import { t } from "../i18n/i18n";

const MUTED = "font-size:11px;color:#8E939C;line-height:1.4";

function toggle(on: boolean, change: (v: boolean) => void): HTMLElement {
  const sw = h("button", { class: on ? "switch on" : "switch", "aria-pressed": on });
  sw.addEventListener("click", () => {
    const next = !sw.classList.contains("on");
    sw.classList.toggle("on", next);
    change(next);
  });
  return sw;
}

let listening = false;
let redrawLaya: ((s: LayaStatus) => void) | null = null;

export function testsSection(settings: () => Settings, save: () => void): HTMLElement {
  const box = h("div", { style: "display:flex;flex-direction:column;gap:8px" });
  let laya: LayaStatus | null = null;
  let test: string | null = null;
  let keyStored = false;

  function draw() {
    const s = settings();
    const mode = s.testChecker || "off";
    box.replaceChildren();
    box.append(
      h("div", { class: "hint", style: MUTED, text: t("When an agent runs its tests, Coucou reads the result from the output itself, not from what the agent says: “Tests passed · 48 passed”, “Tests failed · 1 failed”.") }),
      h("div", { class: "row", style: "gap:10px" },
        toggle(s.fixFailingTests === true, (v) => { settings().fixFailingTests = v; save(); }),
        h("span", { style: "font-size:12.5px", text: t("Make Claude fix failing tests") }),
      ),
      h("div", { class: "hint", style: MUTED, text: t("Claude Code is told when a test run fails, and sent back when it tries to finish, commit or push while its tests fail, weren't run after its changes, or were changed just to pass. At most twice per request. Coucou never changes your files itself.") }),
      h("div", { style: "font-size:12.5px;font-weight:500;padding-top:6px", text: t("Double-check unclear test results") }),
    );
    const modes = h("div", { class: "row", style: "gap:4px" });
    for (const [id, label] of [["off", t("Off")], ["local", t("Laya, on this computer")], ["cloud", t("Jev, in the cloud")]] as const) {
      modes.append(h("button", {
        class: mode === id ? "primary" : "",
        text: label,
        onclick: () => {
          settings().testChecker = id;
          test = null;
          save();
          draw();
        },
      }));
    }
    box.append(
      modes,
      h("div", { class: "hint", style: MUTED, text: t("Only when the output can't say whether the tests passed: the checker reads it once and answers how sure it is. It has 5 seconds; without an answer nothing changes.") }),
    );

    if (mode === "local") {
      const st = laya;
      const line = st ? [st.message, st.line].filter(Boolean).join(" — ") : "";
      const buttons = h("div", { class: "row", style: "gap:6px" });
      const busy = st != null && ["python", "venv", "install", "starting"].includes(st.phase);
      const custom = (s.layaDir ?? "").trim() !== "";
      if (st?.external) {
        // Started outside Coucou: used as it is, nothing to start, stop or remove.
      } else if (!st?.installed) {
        if (!custom) buttons.append(h("button", { class: "primary", text: t("Set up Laya"), disabled: busy, onclick: () => void Bridge.layaSetup() }));
      } else {
        if (st.running) buttons.append(h("button", { text: t("Stop"), onclick: () => void Bridge.layaStop() }));
        else buttons.append(h("button", { class: "primary", text: t("Start"), disabled: busy, onclick: () => void Bridge.layaStart() }));
        // Only Coucou's own copy: a Laya picked below is never deleted.
        if (!custom) buttons.append(h("button", { class: "danger", text: t("Remove Laya"), disabled: busy, onclick: () => void Bridge.layaRemove() }));
      }
      const folder = h("input", { type: "text", value: s.layaDir ?? "", placeholder: t("Coucou's own copy"), spellcheck: false, style: "flex:1;min-width:0" }) as HTMLInputElement;
      const use = () => {
        const v = folder.value.trim();
        if (v === (settings().layaDir ?? "").trim()) return;
        settings().layaDir = v;
        test = null;
        save();
        draw();
      };
      folder.addEventListener("keydown", (e) => { if (e.key === "Enter") use(); });
      buttons.append(testButton("local"));
      box.append(
        h("div", { class: "hint", style: MUTED, text: t("Laya (by Convai Innovations) runs on this computer only: nothing leaves it. Setting it up installs Python packages and PyTorch in Coucou's folder (a few GB, once), then its model (about 850 MB). It needs Python 3.10 to 3.13.") }),
        h("div", { class: "row", style: "gap:6px" },
          h("span", { style: "font-size:12.5px;white-space:nowrap", text: t("Laya folder") }),
          folder,
          h("button", { text: t("Use"), onclick: use }),
        ),
        h("div", { class: "hint", style: MUTED, text: t("Already have Laya? Enter its folder (the one with its .venv). Coucou starts it from there and never changes or removes it. A Laya that is already running is used as it is.") }),
        buttons,
      );
      if (line) box.append(h("div", { style: `${MUTED};color:${st?.phase === "error" ? "#F4505E" : "#8E939C"}`, text: line }));
    }

    if (mode === "cloud") {
      const input = h("input", { type: "password", placeholder: keyStored ? "••••••••" : t("TypeSafe API key"), autocomplete: "off", style: "flex:1;min-width:0" }) as HTMLInputElement;
      const saveKey = h("button", { text: t("Save") });
      saveKey.addEventListener("click", async () => {
        const v = input.value.trim();
        if (!v) return;
        await Bridge.secretSet("typesafe-api-key", v);
        keyStored = true;
        input.value = "";
        draw();
      });
      box.append(
        h("div", { class: "row", style: "gap:6px" }, input, saveKey, testButton("cloud")),
        h("div", { class: "hint", style: MUTED, text: t("Jev is TypeSafe's service (typesafe.ai), with your own API key. Only the end of an unclear test run's output is sent, after removing anything that looks like a password, key, email, IP address or your user folder.") }),
      );
    }
    if (test) box.append(h("div", { style: MUTED, text: test }));
  }

  function testButton(mode: "local" | "cloud"): HTMLElement {
    return h("button", {
      text: t("Test connection"),
      onclick: async () => {
        test = "…";
        draw();
        const a = await Bridge.testsCheckPing(mode);
        test = a && !a.error ? t("It answers ({ms} ms).", { ms: a.ms }) : (a?.error ?? t("No answer."));
        draw();
      },
    });
  }

  redrawLaya = (s) => {
    laya = s;
    draw();
  };
  if (!listening) {
    listening = true;
    void onEvent<LayaStatus>("laya", (s) => redrawLaya?.(s));
  }
  void Bridge.layaStatus().then((s) => {
    if (s) laya = s;
    draw();
  });
  void Bridge.secretPresent("typesafe-api-key").then((on) => {
    keyStored = on === true;
    draw();
  });
  draw();
  return h("section", {}, h("h2", {}, h("span", { text: t("Test results") })), box);
}
