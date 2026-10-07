// Model picker on the left of the chat bar. A native <select> opens an OS
// popup outside the island's hit area, where the click-through gate drops the
// click, so the list is drawn inside the island instead (opening upward over
// the chat log). Keyboard: Enter/Space/ArrowUp opens, arrows move, Enter picks,
// Escape closes.

import { h, clear } from "./dom";
import { Bridge } from "../core/bridge";
import { State } from "../core/state";
import { ANTHROPIC_MODELS } from "../core/models";

interface Item {
  value: string;
  label: string;
  disabled?: boolean;
}

export function modelPicker() {
  const button = h("button", {
    type: "button",
    class: "model-picker",
    "aria-label": "Chat model",
    "aria-haspopup": "listbox",
    "aria-expanded": "false",
  }) as HTMLButtonElement;
  const list = h("div", { class: "model-menu", role: "listbox", hidden: "" });
  const el = h("div", { class: "model-picker-wrap" }, button, list);

  let key = "";
  let loading = false;
  let routerIds: string[] | null = null;
  let routerError: string | null = null;
  let loadedFor: string | null = null;
  let open = false;
  let active = -1;
  let items: Item[] = [];

  async function loadRouter(refresh: boolean) {
    if (loading) return;
    loading = true;
    loadedFor = State.settings.routerBaseUrl;
    routerError = null;
    render();
    try {
      routerIds = await Bridge.routerModels(refresh);
      const s = State.settings;
      if (s.chatProvider === "router" && routerIds.length && !routerIds.includes(s.model)) {
        choose(routerIds[0]);
      }
    } catch (err) {
      routerIds = null;
      routerError = String(err).replace(/^Error:\s*/, "");
    } finally {
      loading = false;
      render();
    }
  }

  function buildItems(): Item[] {
    const s = State.settings;
    if (s.chatProvider !== "router") {
      const out: Item[] = ANTHROPIC_MODELS.map(([value, label]) => ({ value, label }));
      if (!ANTHROPIC_MODELS.some(([id]) => id === s.model)) out.push({ value: s.model, label: s.model });
      return out;
    }
    const ids = routerIds ?? [];
    const out: Item[] = [];
    if (s.model && !ids.includes(s.model) && !(loading || routerError)) {
      out.push({ value: s.model, label: s.model });
    }
    for (const id of ids) out.push({ value: id, label: id });
    if (loading) out.push({ value: "", label: "Loading models…", disabled: true });
    else if (routerError) out.push({ value: "", label: `⚠ ${routerError}`, disabled: true });
    else if (ids.length === 0) out.push({ value: "", label: "No models", disabled: true });
    out.push({ value: "__refresh", label: "↻ Refresh list" });
    return out;
  }

  function labelFor(value: string): string {
    const anth = ANTHROPIC_MODELS.find(([id]) => id === value);
    return anth && State.settings.chatProvider !== "router" ? anth[1] : value || "Pick model";
  }

  function drawList() {
    clear(list);
    items.forEach((item, index) => {
      const row = h("div", {
        class: "model-option",
        role: "option",
        title: item.value && item.value !== "__refresh" ? item.value : item.label,
        text: item.label,
      });
      row.setAttribute("aria-selected", String(item.value === State.settings.model));
      if (item.value === State.settings.model) row.classList.add("selected");
      if (index === active) row.classList.add("active");
      if (item.disabled) row.classList.add("disabled");
      row.addEventListener("mousedown", (e) => {
        e.preventDefault();
        e.stopPropagation();
        pick(index);
      });
      list.append(row);
    });
    const current = list.children[active] as HTMLElement | undefined;
    current?.scrollIntoView({ block: "nearest" });
  }

  function render() {
    const s = State.settings;
    items = buildItems();
    const next = [s.chatProvider, s.model, loading, routerError, routerIds?.join("\n"), open, active].join("|");
    if (next === key) return;
    key = next;
    const router = s.chatProvider === "router";
    button.textContent = loading && router && !routerIds ? "Loading…" : labelFor(s.model);
    button.title = routerError && router ? `${s.model}\n${routerError}` : s.model;
    button.classList.toggle("error", router && !!routerError);
    button.setAttribute("aria-expanded", String(open));
    list.hidden = !open;
    if (open) drawList();
  }

  function choose(value: string) {
    if (!value || value === State.settings.model) return;
    State.settings.model = value;
    void Bridge.saveSettings(State.settings);
    State.notify();
  }

  function pick(index: number) {
    const item = items[index];
    if (!item || item.disabled) return;
    if (item.value === "__refresh") {
      void loadRouter(true);
      return;
    }
    choose(item.value);
    setOpen(false);
    button.focus();
  }

  function setOpen(next: boolean) {
    if (open === next) return;
    open = next;
    if (open) {
      if (State.settings.chatProvider === "router" && !routerIds && !loading) void loadRouter(false);
      items = buildItems();
      active = Math.max(0, items.findIndex((i) => i.value === State.settings.model));
    }
    render();
  }

  function move(delta: number) {
    if (!items.length) return;
    let i = active;
    for (let n = 0; n < items.length; n++) {
      i = (i + delta + items.length) % items.length;
      if (!items[i].disabled) break;
    }
    active = i;
    render();
  }

  button.addEventListener("mousedown", (e) => {
    e.preventDefault();
    e.stopPropagation();
    if (button.disabled) return;
    setOpen(!open);
    button.focus();
  });
  button.addEventListener("keydown", (e) => {
    const k = e.key;
    e.stopPropagation();
    if (!open) {
      if (k === "Enter" || k === " " || k === "ArrowUp" || k === "ArrowDown") {
        e.preventDefault();
        setOpen(true);
      }
      return;
    }
    if (k === "Escape") { e.preventDefault(); setOpen(false); }
    else if (k === "ArrowDown") { e.preventDefault(); move(1); }
    else if (k === "ArrowUp") { e.preventDefault(); move(-1); }
    else if (k === "Enter" || k === " ") { e.preventDefault(); pick(active); }
    else if (k === "Tab") setOpen(false);
  });
  button.addEventListener("blur", () => setOpen(false));
  list.addEventListener("mousedown", (e) => { e.preventDefault(); e.stopPropagation(); });

  return {
    el,
    get disabled() { return button.disabled; },
    set disabled(value: boolean) {
      button.disabled = value;
      if (value) setOpen(false);
    },
    sync() {
      const s = State.settings;
      if (s.chatProvider === "router" && loadedFor !== s.routerBaseUrl && !loading) {
        void loadRouter(false);
      }
      render();
    },
    refresh() {
      if (State.settings.chatProvider === "router") void loadRouter(false);
    },
  };
}
