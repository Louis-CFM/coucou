// Dictionary (names Coucou always spells right, and replacements) and
// Snippets (say a short phrase, paste a whole text). Port of FlowHubWords.swift.

import { h, clear } from "../../views/dom";
import { t } from "../../i18n/i18n";
import { FlowBridge, type Replacement, type Snippet } from "../../core/flow";
import type { HubContext } from "../shell";
import { emptyState } from "../hero";
import { button, card, icon, iconButton, label } from "../ui";

function newId(): string {
  return `${Date.now().toString(16)}-${Math.random().toString(16).slice(2, 8)}`;
}

function input(placeholder: string, onEnter?: () => void): HTMLInputElement {
  const el = h("input", { class: "hub-input", placeholder }) as HTMLInputElement;
  if (onEnter) el.addEventListener("keydown", (e) => e.key === "Enter" && onEnter());
  return el;
}

export async function dictionaryPage(page: HTMLElement, ctx: HubContext) {
  const data = (await FlowBridge.words()) ?? { words: [], replacements: [] };
  let words = data.words;
  let replacements: Replacement[] = data.replacements;
  const save = () => void FlowBridge.setWords({ words, replacements });
  page.append(ctx.hero("dictionary", t("Dictionary"), t("Names and words Coucou must always spell right.")));

  // ── Words ──
  const chips = h("div", { class: "hub-chips" });
  const wordInput = input(t("Add a word, e.g. Supabase"), () => addWord());
  const addWord = () => {
    const w = wordInput.value.trim();
    if (!w || words.some((x) => x.toLowerCase() === w.toLowerCase())) return;
    words = [...words, w];
    wordInput.value = "";
    save();
    drawWords();
  };
  const drawWords = () => {
    clear(chips);
    if (words.length === 0) {
      chips.append(h("div", { class: "hub-note", text: t("No word yet. Add the names, brands and jargon Coucou gets wrong.") }));
      return;
    }
    for (const w of words) {
      const remove = h("button", { title: t("Delete"), "aria-label": t("Delete") });
      remove.append(icon("x"));
      remove.addEventListener("click", () => {
        words = words.filter((x) => x !== w);
        save();
        drawWords();
      });
      chips.append(h("span", { class: "hub-chip" }, h("span", { text: w }), remove));
    }
  };
  wordInput.style.flex = "1";
  page.append(card(h("div", { class: "hub-row" }, wordInput, button(t("Add"), addWord, "primary")), chips));
  drawWords();

  // ── Replacements ──
  page.append(label(t("Replacements")), h("div", { class: "hub-note", style: "margin-top:-10px", text: t("When Coucou hears the words on the left, it writes the ones on the right.") }));
  const list = h("div", {});
  const from = input(t("Heard, e.g. cloud code"));
  const to = input(t("Written, e.g. Claude Code"), () => addReplacement());
  const addReplacement = () => {
    const f = from.value.trim();
    const w = to.value.trim();
    if (!f || !w) return;
    replacements = [...replacements.filter((r) => r.from.toLowerCase() !== f.toLowerCase()), { id: newId(), from: f, to: w }];
    from.value = "";
    to.value = "";
    save();
    drawReplacements();
  };
  const drawReplacements = () => {
    clear(list);
    for (const r of replacements) {
      list.append(h("div", { class: "hub-list-row" },
        h("div", { class: "grow hub-pair" },
          h("span", { text: r.from }),
          h("span", { class: "arrow", text: "→" }),
          h("b", { text: r.to, style: "font-weight:600" }),
          iconButton("trash", t("Delete"), () => {
            replacements = replacements.filter((x) => x.id !== r.id);
            save();
            drawReplacements();
          }),
        ),
      ));
    }
  };
  page.append(card(h("div", { class: "hub-pair" }, from, h("span", { class: "arrow", text: "→" }), to, button(t("Add"), addReplacement)), list));
  drawReplacements();
}

export async function snippetsPage(page: HTMLElement, ctx: HubContext) {
  let snippets: Snippet[] = (await FlowBridge.snippets()) ?? [];
  const save = () => void FlowBridge.setSnippets(snippets);
  page.append(ctx.hero("snippets", t("Snippets"), t("Say the trigger while dictating: Coucou pastes the whole text in its place.")));

  let editing: Snippet | null = null;
  const formTitle = h("div", { style: "font:700 14px var(--font)" });
  const trigger = h("input", { class: "hub-input", placeholder: t("What you say, e.g. my signature") }) as HTMLInputElement;
  const text = h("textarea", { class: "hub-textarea", placeholder: t("The text Coucou pastes") }) as HTMLTextAreaElement;
  const cancel = button(t("Cancel"), () => edit(null));
  const saveButton = button(t("Save"), () => {
    const tr = trigger.value.trim();
    const tx = text.value;
    if (!tr || !tx.trim()) return;
    if (editing) {
      snippets = snippets.map((s) => (s.id === editing!.id ? { ...s, trigger: tr, text: tx } : s));
    } else {
      snippets = [...snippets, { id: newId(), trigger: tr, text: tx }];
    }
    save();
    edit(null);
    draw();
  }, "primary");
  const edit = (s: Snippet | null) => {
    editing = s;
    formTitle.textContent = s ? t("Edit the snippet") : t("New snippet");
    trigger.value = s?.trigger ?? "";
    text.value = s?.text ?? "";
    cancel.style.display = s ? "" : "none";
  };
  page.append(card(formTitle, h("div", { class: "hub-row" }, h("span", { class: "hub-note", style: "width:80px", text: t("You say") }), trigger), text, h("div", { class: "hub-row", style: "justify-content:flex-end" }, cancel, saveButton)));
  trigger.style.flex = "1";
  edit(null);

  const list = h("div", {});
  const listCard = card(list);
  page.append(listCard);
  const draw = () => {
    clear(list);
    if (snippets.length === 0) {
      list.append(emptyState(t("No snippet yet. Your booking link, your signature, your address: say a few words, get the whole text."), "idle", "#F7B32B"));
      return;
    }
    for (const s of snippets) {
      list.append(h("div", { class: "hub-list-row" },
        h("div", { class: "grow" }, h("div", { style: "font:600 13.5px var(--font)", text: `« ${s.trigger} »` }), h("div", { class: "hub-snippet-text", text: s.text })),
        iconButton("pencil", t("Edit"), () => {
          edit(s);
          trigger.focus();
        }),
        iconButton("trash", t("Delete"), () => {
          snippets = snippets.filter((x) => x.id !== s.id);
          save();
          draw();
        }),
      ));
    }
  };
  draw();
}
