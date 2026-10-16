// The editors the buttons can open things in (src/core/editors.ts).

import { test } from "node:test";
import assert from "node:assert/strict";
import { DEFAULT_EDITOR, EDITORS, OPEN_IN, editorOf } from "../src/core/editors.ts";
import { DEFAULT_SETTINGS } from "../src/core/state.ts";

test("VS Code is the default, and a value that names no editor means it", () => {
  assert.equal(DEFAULT_EDITOR, "vscode");
  assert.equal(DEFAULT_SETTINGS.editor, "vscode");
  assert.equal(editorOf("phpstorm"), "phpstorm");
  for (const bad of ["", "PhpStorm", "emacs", null, undefined, 3, ["phpstorm"]]) assert.equal(editorOf(bad), "vscode");
});

test("every editor is named and has a tooltip for the diff's ↗", () => {
  assert.deepEqual(EDITORS.map((e) => [e.id, e.name]), [["vscode", "VS Code"], ["phpstorm", "PhpStorm"]]);
  assert.equal(OPEN_IN.vscode, "Open in VS Code");
  assert.equal(OPEN_IN.phpstorm, "Open in PhpStorm");
});
