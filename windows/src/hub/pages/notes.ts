// The Notetaker: your calls, transcribed person by person, with a summary,
// the key points and the to-dos. Port of FlowHubNotes.swift.

import { h, clear } from "../../views/dom";
import { t } from "../../i18n/i18n";
import { onEvent } from "../../core/bridge";
import { FlowBridge, clock, speakerColor, type Note, type NotesState } from "../../core/flow";
import type { HubContext } from "../shell";
import { emptyState, glowCard } from "../hero";
import { button, iconButton, segmented } from "../ui";
import { modelsControl } from "./flowsettings";

const lang = () => document.documentElement.lang || undefined;

function minutes(note: Note): number {
  const end = note.end ?? Date.now();
  return Math.max(1, Math.round((end - note.start) / 60_000));
}

export async function notesPage(page: HTMLElement, ctx: HubContext) {
  let state: NotesState = (await FlowBridge.notes()) ?? { notes: [], recording: null, working: [] };
  let selected: string | null = state.recording ?? state.notes[0]?.id ?? null;
  let tab: "summary" | "transcript" = "summary";
  let startError = "";

  page.append(ctx.hero("notes", t("Notetaker"), t("Your calls transcribed person by person, with a summary and the to-dos. No bot in the meeting."), [], true));
  if (ctx.status.models.parakeet.state !== "ready") {
    page.append(glowCard(
      "#3B9EFF",
      h("div", { style: "font:700 15px var(--font)", text: t("One download, then offline") }),
      h("div", { class: "hub-note", style: "color:#b7bbc2", text: t("Coucou writes your calls on this computer with Parakeet, and tells the voices apart with a second small model. Both are downloaded once (about {0} MB), then everything works offline.", { 0: ctx.status.models.downloadMb }) }),
      modelsControl(ctx, () => ctx.navigate("notes")),
    ));
  }

  const listEl = h("div", { class: "hub-notes-list" });
  const detail = h("div", { class: "hub-note-detail" });
  page.append(h("div", { class: "hub-notes" }, listEl, detail));

  const reload = async () => {
    state = (await FlowBridge.notes()) ?? state;
    if (selected && !state.notes.some((n) => n.id === selected)) selected = state.notes[0]?.id ?? null;
    drawList();
    drawDetail();
  };

  function recordButton(): HTMLElement {
    if (state.recording) {
      const rec = state.notes.find((n) => n.id === state.recording);
      const b = button(`■  ${t("Stop")} · ${clock((Date.now() - (rec?.start ?? Date.now())) / 1000)}`, () => void FlowBridge.stopNote(), "danger");
      b.dataset.ticking = "1";
      return b;
    }
    const b = button(t("Record a call"), () => {
      startError = "";
      FlowBridge.startNote().then((id) => {
        selected = id;
        void reload();
      }, (err) => {
        startError = String(err);
        drawList();
      });
    }, "primary");
    b.prepend(h("span", { class: "hub-rec", style: "background:#170c04;box-shadow:none;margin-inline-end:8px" }));
    return b;
  }

  function drawList() {
    clear(listEl);
    const rb = recordButton();
    rb.style.width = "100%";
    listEl.append(rb);
    if (startError) listEl.append(h("div", { class: "hub-warn", text: startError }));
    if (state.notes.length === 0) {
      listEl.append(h("div", { class: "hub-note", style: "padding:14px 4px", text: t("Your calls will show here. Click Record a call when one starts.") }));
    }
    let day = "";
    for (const n of state.notes) {
      const d = new Date(n.start).toDateString();
      if (d !== day) {
        day = d;
        const isToday = d === new Date().toDateString();
        listEl.append(h("div", { class: "hub-group", style: "padding:10px 6px 2px", text: isToday ? t("Today") : new Date(n.start).toLocaleDateString(lang(), { day: "numeric", month: "long" }) }));
      }
      const meta = n.status === "recording"
        ? t("Recording…")
        : state.working.includes(n.id) || n.status === "processing"
          ? t("writing…")
          : n.status === "failed"
            ? t("failed")
            : `${new Date(n.start).toLocaleTimeString(lang(), { hour: "2-digit", minute: "2-digit" })} · ${t("{0} min", { 0: minutes(n) })}`;
      const item = h("button", { class: n.id === selected ? "hub-note-item on" : "hub-note-item", onclick: () => {
        selected = n.id;
        drawList();
        drawDetail();
      } }, h("span", { class: "t", text: n.title }), h("span", { class: "m", text: meta }));
      if (n.status === "recording") item.querySelector(".m")!.prepend(h("span", { class: "hub-rec", style: "margin-inline-end:6px" }));
      listEl.append(item);
    }
    listEl.append(h("div", { style: "flex:1" }), h("div", { class: "hub-note", style: "padding:10px;border-radius:10px;background:rgba(255,255,255,0.04)", text: t("Everything stays on this computer. Tell the people in the call that you are recording.") }));
  }

  function drawDetail() {
    clear(detail);
    const note = state.notes.find((n) => n.id === selected);
    if (!note) {
      detail.append(emptyState(t("Your calls will show here. Click Record a call when one starts."), "sleeping", "#3B9EFF"));
      return;
    }
    // Title, renamed in place.
    const title = h("h2", { text: note.title, title: t("Edit"), style: "cursor:text" });
    title.addEventListener("click", () => {
      const input = h("input", { class: "hub-input", style: "font:700 20px var(--font);width:100%" }) as HTMLInputElement;
      input.value = note.title;
      const done = () => void FlowBridge.renameNote(note.id, input.value);
      input.addEventListener("keydown", (e) => {
        if (e.key === "Enter") done();
        if (e.key === "Escape") drawDetail();
      });
      input.addEventListener("blur", done);
      title.replaceWith(input);
      input.focus();
      input.select();
    });
    const when = new Date(note.start).toLocaleString(lang(), { weekday: "long", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit" });
    const copied = h("span", { class: "hub-note" });
    const tools = h("div", { class: "hub-row", style: "gap:8px" });
    const confirm = h("div", {});
    if (note.status === "ready") {
      tools.append(button(t("Copy as Markdown"), async () => {
        const md = await FlowBridge.markdown(note.id);
        if (md && (await FlowBridge.copy(md))) {
          copied.textContent = t("Copied");
          setTimeout(() => (copied.textContent = ""), 1500);
        }
      }, "", true));
      tools.append(button(t("Export as Markdown…"), () => void FlowBridge.exportNote(note.id).catch(() => {}), "", true));
    }
    if (note.status !== "recording") {
      tools.append(iconButton("trash", t("Delete"), () => {
        clear(confirm);
        confirm.append(h("div", { class: "hub-warn", style: "display:flex;align-items:center;gap:10px" },
          h("span", { style: "flex:1", text: t("Delete this call and its notes?") }),
          button(t("Delete"), () => void FlowBridge.deleteNote(note.id), "danger", true),
          button(t("Cancel"), () => clear(confirm), "", true),
        ));
      }));
    }
    tools.append(copied);
    detail.append(
      h("div", { style: "display:flex;flex-direction:column;gap:4px;min-width:0" }, title, h("div", { class: "hub-note", text: note.app ? `${when} · ${note.app}` : when })),
      tools,
      confirm,
    );

    // The people, renamed with a click.
    if (note.speakers.length) {
      const people = h("div", { class: "hub-speakers" });
      for (const s of note.speakers) {
        const chip = h("button", { class: "hub-speaker", title: t("Who is it?") },
          h("span", { class: "av", style: `background:${speakerColor(s.color)}`, text: s.name.slice(0, 1).toUpperCase() }),
          h("span", { text: s.name }),
        );
        chip.addEventListener("click", () => {
          const input = h("input", { class: "hub-input", placeholder: t("Name"), style: "width:150px" }) as HTMLInputElement;
          input.value = s.name;
          const done = () => void FlowBridge.renameSpeaker(note.id, s.id, input.value);
          input.addEventListener("keydown", (e) => e.key === "Enter" && done());
          input.addEventListener("blur", done);
          chip.replaceWith(input);
          input.focus();
          input.select();
        });
        people.append(chip);
      }
      detail.append(people);
    }

    if (note.status === "recording") {
      detail.append(h("div", { class: "hub-row" }, h("span", { class: "hub-rec" }), h("b", { text: t("Live") })));
      detail.append(transcript(note, t("The words show up here as people speak.")));
      return;
    }
    if (note.status === "processing" || state.working.includes(note.id) && note.lines.length === 0) {
      detail.append(emptyState(t("Coucou is writing the transcript, person by person…"), "working", "#3B9EFF"));
      return;
    }
    if (note.status === "failed") {
      detail.append(h("div", { class: "hub-warn", text: `${t("The transcript could not be written.")} ${note.error ?? ""}` }));
      detail.append(button(t("Retry"), () => void FlowBridge.retryNote(note.id)));
      return;
    }
    if (note.lines.length === 0) {
      detail.append(emptyState(t("Nobody was heard in this recording."), "idle", "#3B9EFF"));
      return;
    }
    const tabs = segmented<"summary" | "transcript">([["summary", t("Summary")], ["transcript", t("Transcript")]], tab, (next) => {
      tab = next;
      drawDetail();
    });
    detail.append(h("div", {}, tabs));
    detail.append(tab === "summary" ? summary(note) : transcript(note, ""));
  }

  function summary(note: Note): HTMLElement {
    const el = h("div", { style: "display:flex;flex-direction:column;gap:14px;align-items:flex-start" });
    const busy = state.working.includes(note.id);
    if (!note.summary && note.keyPoints.length === 0 && note.todos.length === 0) {
      el.append(h("div", { class: "hub-note", text: busy ? t("Writing the summary…") : t("No summary yet.") }));
      if (!busy) el.append(button(t("Write the summary"), () => void FlowBridge.summarize(note.id), "primary", true));
      return el;
    }
    if (note.summary) el.append(h("div", { class: "hub-card", style: "font-size:14px;line-height:1.55;color:var(--hub-body);align-self:stretch", text: note.summary }));
    if (note.keyPoints.length) {
      const ul = h("ul", { style: "margin:0;padding-inline-start:20px;display:flex;flex-direction:column;gap:6px;font-size:13.5px" });
      for (const p of note.keyPoints) ul.append(h("li", { text: p }));
      el.append(h("div", { class: "hub-label", text: t("Key points") }), ul);
    }
    if (note.todos.length) {
      el.append(h("div", { class: "hub-label", text: t("To do") }));
      for (const todo of note.todos) {
        const box = h("input", { type: "checkbox" }) as HTMLInputElement;
        box.checked = todo.done;
        box.addEventListener("change", () => void FlowBridge.toggleTodo(note.id, todo.id));
        const extra = [todo.owner, todo.due].filter(Boolean).join(" · ");
        el.append(h("label", { class: "hub-todo" }, box, h("span", {}, h("span", { text: todo.text, style: todo.done ? "text-decoration:line-through;opacity:.6" : "" }), extra ? h("div", { class: "who", text: extra }) : null)));
      }
    }
    el.append(button(busy ? t("Writing the summary…") : t("Write the summary again"), () => void FlowBridge.summarize(note.id), "", true));
    return el;
  }

  function transcript(note: Note, empty: string): HTMLElement {
    const el = h("div", { style: "display:flex;flex-direction:column" });
    if (note.lines.length === 0 && empty) el.append(h("div", { class: "hub-note", text: empty }));
    for (const line of note.lines) {
      const s = note.speakers.find((x) => x.id === line.speaker);
      const name = s?.name ?? (line.speaker === "me" ? t("Me") : t("Others"));
      const color = s ? speakerColor(s.color) : line.speaker === "me" ? speakerColor(0) : speakerColor(1);
      el.append(h("div", { class: "hub-line" },
        h("span", { class: "ts", text: clock(line.start) }),
        h("div", {}, h("div", { class: "who", style: `color:${color}`, text: name }), h("div", { class: "said", text: line.text })),
      ));
    }
    return el;
  }

  drawList();
  drawDetail();
  const unlisten = await onEvent<string>("notes-changed", () => void reload());
  // The recording's clock in the list.
  const timer = window.setInterval(() => {
    if (!state.recording) return;
    const b = listEl.querySelector<HTMLElement>("[data-ticking]");
    if (!b) return;
    const next = recordButton();
    next.style.width = "100%";
    b.replaceWith(next);
  }, 1000);
  ctx.onLeave = () => {
    unlisten();
    window.clearInterval(timer);
  };
}
