// Quick chat window (global hotkey). Same Rust conversation as the island
// chat; the log is kept in step through the "chat-history" event.

import { onEvent } from "../core/bridge";
import { followChat } from "../core/chat-sync";
import { buildPrompt } from "../views/chat";
import { quickFrame, renderLoop } from "./frame";

async function main() {
  const frame = await quickFrame("quick-chat", "Chat with Mochi");
  const view = buildPrompt(() => {}, { inlineErrors: true });
  view.el.classList.add("on");
  frame.body.append(view.el);
  renderLoop(() => view.sync());

  await followChat(() => view.sync());

  // Shown by a hotkey (chat or voice) or by a click elsewhere.
  await onEvent<string>("quick-shown", () => {
    view.sync();
    window.setTimeout(() => view.focus?.(), 60);
  });
  // Voice hotkey: start recording, or stop and send.
  await onEvent<null>("quick-voice", () => view.toggleVoice());

  document.addEventListener("visibilitychange", () => {
    if (document.hidden) view.cancelVoice();
  });
  view.focus?.();
}

void main();
