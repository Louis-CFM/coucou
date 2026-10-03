// "Open terminal" and the ↗ on the overview: bring the session's terminal to the
// front when we can reach it, open its folder in an editor otherwise.

import { Bridge } from "../core/bridge";
import { State, type AgentTask } from "../core/state";

/** "Open terminal": the session's own terminal when we can reach it, VS Code otherwise. */
export async function openSession(task: AgentTask | null | undefined) {
  if (task?.terminal && (await Bridge.focusTerminal(task.terminal))) return;
  if ((await Bridge.openInVSCode(task?.sessionCwd ?? null)) === "no-editor") {
    // Say so, or the click looks like it did nothing: the folder opened in the file manager at best.
    State.noteMessage = "No code editor found. Install Visual Studio Code (the `code` command) to open projects from here.";
    State.view = "note";
    State.notify();
  }
}
