// The sessions on the right of the drop card while a file is dragged over the
// island — port of SessionDropTargets in SessionDrop.swift. Letting go over
// one sends the file to that session's prompt (island.ts → Rust's
// drop_into_session); anywhere else on the card the drop goes on as before.
//
// The drop card is drawn on the upload canvas (src/upload); this list is a
// layer above it, placed at the points core/launch.ts hit-tests.

import { h, dot } from "./dom";
import { State } from "../core/state";
import { dropTargets, dropTargetsLayout } from "../core/launch";
import { tl } from "../i18n/i18n";

export interface SessionDropList {
  el: HTMLElement;
  /** Shown while a file is over the drop card and a session can take it. */
  sync(show: boolean): void;
}

export function buildSessionDropList(): SessionDropList {
  const title = h("div", { class: "sd-title", text: tl("Or into a session") });
  const el = h("div", { id: "session-drop" }, title);
  let key = "";
  let rows: HTMLElement[] = [];

  return {
    el,
    sync(show) {
      const targets = show ? dropTargets(State.tasks) : [];
      el.classList.toggle("on", targets.length > 0);
      if (targets.length === 0) return;
      const layout = dropTargetsLayout(targets.length);
      const nextKey = targets.map((t) => `${t.id}\u0000${t.name}\u0000${t.color}`).join("\u0001");
      if (nextKey !== key) {
        key = nextKey;
        rows.forEach((r) => r.remove());
        rows = targets.map((task, i) => {
          const r = layout.rows[i];
          const row = h("div", { class: "sd-row" }, dot(task.color, 7), h("span", { text: task.name }));
          row.style.cssText = `left:${r.x}px;top:${r.y}px;width:${r.w}px;height:${r.h}px`;
          el.append(row);
          return row;
        });
        const t = layout.title;
        title.style.cssText = `left:${t.x}px;top:${t.y}px;width:${t.w}px;height:${t.h}px`;
      }
      rows.forEach((row, i) => row.classList.toggle("over", State.dropSessionTarget === targets[i]?.id));
    },
  };
}
