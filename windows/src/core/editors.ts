// The editors "Open terminal" and the diff's ↗ can open things in, picked in
// Settings. The ids are what settings.json stores (editor.rs reads them too).

import { N_ } from "../i18n/i18n";

export type EditorId = "vscode" | "phpstorm";

export interface EditorChoice {
  id: EditorId;
  /** Product names are not translated. */
  name: string;
}

export const EDITORS: readonly EditorChoice[] = [
  { id: "vscode", name: "VS Code" },
  { id: "phpstorm", name: "PhpStorm" },
];

export const DEFAULT_EDITOR: EditorId = "vscode";

/** The editor a stored value names; anything else is the default. */
export function editorOf(value: unknown): EditorId {
  return EDITORS.some((e) => e.id === value) ? (value as EditorId) : DEFAULT_EDITOR;
}

/** The diff card's ↗ tooltip, per editor. Keys are literal so they can be found. */
export const OPEN_IN = {
  vscode: N_("Open in VS Code"),
  phpstorm: N_("Open in PhpStorm"),
} as const satisfies Record<EditorId, string>;
