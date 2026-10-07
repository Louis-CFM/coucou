// One conversation, every window: Rust already holds a single chat history
// (the `Chat` state), so the island and the quick chat window only need to
// show the same log. Each change is broadcast; other pages replace theirs.

import { Bridge, onEvent } from "./bridge";
import { State, type ChatMessage } from "./state";
import { resetMemoryStatuses } from "./memory-status";

const PAGE_ID = `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;

export function publishChat() {
  void Bridge.chatHistoryChanged(State.chatHistory, PAGE_ID);
}

export function resetChat() {
  State.chatHistory = [];
  resetMemoryStatuses(State.pendingMemoryStatuses);
  void Bridge.chatReset();
  publishChat();
}

/** Next free message id after a history came in from another window. */
export function nextChatId(history: ChatMessage[]): number {
  return history.reduce((max, m) => Math.max(max, m.id), 0) + 1;
}

export async function followChat(onChange: () => void) {
  await onEvent<{ history: ChatMessage[]; from: string }>("chat-history", ({ history, from }) => {
    if (from === PAGE_ID || !Array.isArray(history)) return;
    State.chatHistory = history;
    if (history.length === 0) resetMemoryStatuses(State.pendingMemoryStatuses);
    State.notify();
    onChange();
  });
}
