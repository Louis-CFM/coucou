// Browser-only visual fixture. Excluded from the application bundle by Vite's
// explicit entry points. The real hook handler and views receive synthetic data.
import "../src/style.css";
import { State } from "../src/core/state";
import { Island } from "../src/island/island";
import { createHookHandlers } from "../src/island/hooks";

document.body.style.background = "#24272d";
State.settings.soundEnabled = false;
State.settings.activeIntegrations = [];
State.loadIntegrationTasks();
State.setFocus("integration_codex");
const island = new Island(document.getElementById("root")!);
island.applySettings();
island.launch();
const handlers = createHookHandlers(island);
let turn = 0;
const status = () => {
  document.getElementById("preview-status")!.textContent =
    State.pendingApproval ? "Synthetic permission request is active" : `Preview: ${State.view}`;
};
const send = (event: string, fields = {}) => handlers.handle({
  coucou_agent: "codex", session_id: "preview-session", turn_id: `preview-${turn}`,
  cwd: "C:/demo/coucou", hook_event_name: event, ...fields,
});
const activity = () => {
  if (State.pendingApproval) handlers.approvalEnded(State.pendingApproval.requestId);
  turn++;
  send("UserPromptSubmit");
  send("PreToolUse", { tool_name: "Bash" });
  island.alert("overview");
  status();
};
document.getElementById("preview-activity")!.addEventListener("click", activity);
document.getElementById("preview-approval")!.addEventListener("click", () => {
  activity();
  const input = { command: "npm run test:hooks", description: "Run local hook integration tests" };
  send("PermissionRequest", { request_id: `preview-request-${turn}`, tool_name: "Bash",
    tool_input: input, coucou_tool_input_json: JSON.stringify(input, null, 2) });
  status();
});
document.getElementById("preview-finished")!.addEventListener("click", () => { activity(); send("Stop"); status(); });
document.getElementById("preview-interrupt")!.addEventListener("click", () => { send("Interrupt"); island.alert("overview"); status(); });
status();
window.setTimeout(activity, 1800);
