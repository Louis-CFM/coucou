// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView from
// IslandViewContent.swift.

import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { Bridge, type ChatContext } from "../core/bridge";
import { Sound } from "../core/sound";
import { State, type ChatMessage } from "../core/state";
import { Voice } from "../core/voice";
import type { ViewHost } from "./views";

let nextId = 1;

function bubble(message: ChatMessage): HTMLElement {
  if (message.role === "user") {
    return h(
      "div",
      { class: "chat-row user" },
      h("div", { class: "bubble", text: message.content }),
    );
  }
  return h("div", { class: "chat-row" }, h("div", { class: "reply", text: message.content }));
}

function typingDots(): HTMLElement {
  return h(
    "div",
    { class: "chat-row" },
    h("div", { class: "typing" }, h("i"), h("i"), h("i")),
  );
}

/** The coloured chip showing what the question is about (a dropped file). */
function contextChip(label: string): HTMLElement {
  const chip = h("div", { class: "chip" }, h("i", { class: "chip-dot" }), h("span", { text: label }));
  requestAnimationFrame(() => chip.classList.add("settled"));
  return chip;
}

export function buildPrompt(onHeightChange: () => void): ViewHost {
  const chipRow = h("div", { class: "chip-row" });
  const log = h("div", { class: "chat-log" });
  const input = h("input", {
    type: "text",
    class: "chat-input",
    placeholder: "Ask me anything…",
    spellcheck: "false",
  }) as HTMLInputElement;
  const webBtn = h(
    "button",
    { class: "web-btn", title: "Toggle web access" },
    svg(ICONS.globe, 14),
  );
  webBtn.addEventListener("click", () => {
    State.settings.webAccessEnabled = !State.settings.webAccessEnabled;
    void Bridge.saveSettings(State.settings);
    State.notify();
  });

  const mic = h("button", { class: "mic-btn", title: "Toggle voice input" }, svg(ICONS.mic, 14));
  mic.addEventListener("click", () => void Voice.toggleListening());

  Voice.setTranscriptionHandler((text) => {
    input.value = text;
    void submit();
  });

  Voice.setLiveTranscriptHandler((text: string, _isFinal: boolean) => {
    input.value = text;
    onHeightChange();
  });

  Voice.setAutoSendHandler((text: string) => {
    input.value = text;
    void submit();
  });

  const send = h("button", { class: "send-btn", title: "Send" }, svg(ICONS.arrowUp, 11));
  const bar = h("div", { class: "chat-bar" }, input, webBtn, mic, send);

  const el = h(
    "div",
    { class: "view" },
    h("div", { class: "card wash chat-card" }, h("div", { class: "chat-body" }, chipRow, log, bar)),
  );
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.5)");

  let sending = false;
  let renderedCount = -1;

    async function submit() {
    Voice.stopSpeaking();
    const query = input.value.trim();
    if (!query || sending) return;
    input.value = "";
    sending = true;
    Sound.play("send");

    State.chatHistory.push({ id: nextId++, role: "user", content: query });
    State.stateOverride = "thinking";
    State.notify();
    onHeightChange();

    const file = State.droppedFile;
    const context: ChatContext | null =
      State.chatHistory.length === 1 && file ? { kind: "file", name: file.name, path: file.path } : null;

    try {
      // Local Intent Parsing
      const openMatch = query.match(/^(?:buka|open|launch|start|tolong buka)\s+(.+)$/i);
      if (openMatch) {
        const appName = openMatch[1].replace(/[.!?]+$/, "").trim();
        try {
          await Bridge.openApp(appName);
          const replyText = `I have successfully opened ${appName} for you.`;
          State.chatHistory.push({ id: nextId++, role: "assistant", content: replyText });
          State.stateOverride = null;
          Sound.play("finish");
          if (State.settings.voiceEnabled) {
            void Voice.speakReply(replyText);
          }
          sending = false;
          State.notify();
          onHeightChange();
          input.focus();
          return;
        } catch (err) {
          const replyText = `I couldn't open ${appName}. Error: ${err}`;
          State.chatHistory.push({ id: nextId++, role: "assistant", content: replyText });
          State.stateOverride = null;
          Sound.play("error");
          if (State.settings.voiceEnabled) {
            void Voice.speakReply(replyText);
          }
          sending = false;
          State.notify();
          onHeightChange();
          input.focus();
          return;
        }
      }

      let groundingContext = "";

      if (State.settings.webAccessEnabled) {
        const urlMatch = query.match(/https?:\/\/[^\s]+/);
        if (urlMatch) {
          const targetUrl = urlMatch[0];
          input.placeholder = "Reading web page…";
          try {
            const pageContent = await Bridge.webFetch(targetUrl);
            groundingContext = `Web page content from ${targetUrl}:\n${pageContent}`;
          } catch (err) {
            console.warn("[web-access] fetch failed:", err);
          }
        } else {
          State.isWebSearching = true;
          State.notify();
          input.placeholder = "Searching the web…";
          try {
            const results = await Bridge.webSearch(query);
            if (results && results.length > 0) {
              const dateStr = new Date().toISOString().slice(0, 10);
              const formatted = results
                .map((r, i) => `[${i + 1}] "${r.title}" (${r.url})\n${r.snippet}`)
                .join("\n\n");
              groundingContext = `[Current Date: ${dateStr}]\n[Web Search Results for "${query}"]:\n${formatted}`;
            }
          } catch (err) {
            console.warn("[web-access] search failed:", err);
          } finally {
            State.isWebSearching = false;
            State.notify();
          }
        }
      }

      let reply: { text: string };
      if (State.settings.chatProvider === "local") {
        const messages: { role: string; content: string }[] = [];
        if (groundingContext) {
          messages.push({ role: "system", content: groundingContext });
        }
        for (const m of State.chatHistory) {
          messages.push({ role: m.role, content: m.content });
        }
        reply = await Bridge.localChatSend(
          State.settings.localServerUrl,
          State.settings.localModel,
          messages,
        );
      } else {
        const promptQuery = groundingContext
          ? `${groundingContext}\n\nUser Question: ${query}`
          : query;
        reply = await Bridge.chatSend(promptQuery, context);
      }
      State.chatHistory.push({ id: nextId++, role: "assistant", content: reply.text });
      State.stateOverride = null;
      Sound.play("finish");
      if (State.settings.voiceEnabled) {
        void Voice.speakReply(reply.text);
      }
    } catch (err) {
      State.stateOverride = null;
      State.noteMessage = String(err).replace(/^Error:\s*/, "");
      State.view = "note";
      Sound.play("error");
    } finally {
      sending = false;
      State.notify();
      onHeightChange();
      input.focus();
    }
  }

  send.addEventListener("click", () => void submit());
  input.addEventListener("input", () => {
    Voice.stopSpeaking();
    Voice.cancelAutoSend();
  });
  input.addEventListener("keydown", (e) => {
    Voice.stopSpeaking();
    const key = (e as KeyboardEvent).key;
    if (key === "Escape") {
      Voice.cancelAutoSend();
    }
    if (key === "Enter") {
      Voice.cancelAutoSend();
      e.preventDefault();
      void submit();
    }
    e.stopPropagation(); // Escape closes the island, not the chat
  });

  return {
    el,
    sync() {
      const file = State.droppedFile;
      const wantChip = file?.name ?? "";
      if (chipRow.dataset.label !== wantChip) {
        chipRow.dataset.label = wantChip;
        clear(chipRow);
        if (wantChip) chipRow.append(contextChip(wantChip));
      }

      const thinking = State.stateOverride === "thinking";
      const count = State.chatHistory.length + (thinking ? 0.5 : 0);
      if (count !== renderedCount) {
        renderedCount = count;
        clear(log);
        for (const m of State.chatHistory) log.append(bubble(m));
        if (thinking) log.append(typingDots());
        log.scrollTop = log.scrollHeight;
      }

      webBtn.classList.toggle("active", State.settings.webAccessEnabled);
      input.placeholder = State.isWebSearching
        ? "Searching the web…"
        : State.isVoiceListening
          ? (State.voiceListeningPrompt || "Listening…")
          : (State.isVoiceTranscribing || (State.stateOverride === "thinking" && !sending))
            ? "Transcribing voice…"
            : State.chatHistory.length === 0
              ? "Ask me anything…"
              : "Continue…";
      input.disabled = sending;
      mic.classList.toggle("listening", State.isVoiceListening);
    },
    focus() {
      input.focus();
      input.select();
    },
  };
}
