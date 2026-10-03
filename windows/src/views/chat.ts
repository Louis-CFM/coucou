// Chat view — DOM port of PromptView / ChatBubble / TypingDotsView from
// IslandViewContent.swift.

import { h, svg, clear } from "./dom";
import { ICONS } from "./icons";
import { Bridge, type ChatContext } from "../core/bridge";
import { Sound } from "../core/sound";
import { codeBlock, renderMarkdown } from "./markdown";
import { generatingCard, mediaCard, releaseMedia, resetProgress } from "./media";
import { State, type ChatMessage, type ModelEntry, type ModelOutput } from "../core/state";
import type { ViewHost } from "./views";

let nextId = 1;

function bubble(message: ChatMessage): HTMLElement {
  if (message.role === "user") {
    const a = message.attachment;
    return h(
      "div",
      { class: "chat-row user" },
      h("div", { class: "user-turn" },
        // The dropped code file, as the model got it: Markdown code.
        a ? codeBlock(a.text, a.lang, `${a.name} · ${a.text.split("\n").length} lines`) : null,
        h("div", { class: "bubble", text: message.content }),
      ),
    );
  }
  const reply = h("div", { class: "reply md" });
  reply.append(renderMarkdown(message.content));
  return h(
    "div",
    { class: "chat-row" },
    h("div", {},
      message.notice ? h("div", { class: "reply-note", text: message.notice }) : null,
      // An image model may answer with pictures only.
      message.content ? reply : null,
      ...(message.media ?? []).map(mediaCard),
    ),
  );
}

function typingDots(): HTMLElement {
  return h(
    "div",
    { class: "chat-row" },
    h("div", { class: "typing" }, h("i"), h("i"), h("i")),
  );
}

/** The coloured chip showing what the question is about (a dropped file), with
 *  an x to drop it. */
function contextChip(label: string, onRemove: () => void): HTMLElement {
  const remove = h("button", { class: "chip-x", title: "Remove" }, svg(ICONS.xmark, 9));
  remove.addEventListener("click", (e) => {
    e.stopPropagation();
    onRemove();
  });
  const chip = h(
    "div",
    { class: "chip" },
    h("i", { class: "chip-dot" }),
    h("span", { text: label }),
    remove,
  );
  requestAnimationFrame(() => chip.classList.add("settled"));
  return chip;
}

const IMAGE_FILE = /\.(png|jpe?g|gif|webp)$/i;
/** The error chat_send reports when a text-only model refuses an image. */
const IMAGES_UNSUPPORTED = "IMAGES_UNSUPPORTED";

function activeModel() {
  const models = State.settings.models ?? [];
  return models.find((m) => m.id === State.settings.activeModel) ?? models[0] ?? null;
}

/** What a model makes; "text" for chat models, old entries included. */
function outputOf(m: ModelEntry | null): Exclude<ModelOutput, ""> {
  return m?.output || "text";
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
  const send = h("button", { class: "send-btn", title: "Send" }, svg(ICONS.arrowUp, 11));

  // Model picker, next to Send (like the Claude website).
  const modelBtn = h("button", { class: "model-btn", title: "Choose the model" });
  const modelMenu = h("div", { class: "model-menu" });
  const picker = h("div", { class: "model-picker" }, modelMenu, modelBtn);
  let menuOpen = false;
  const setMenu = (open: boolean) => {
    menuOpen = open;
    modelMenu.classList.toggle("open", open);
    if (open) drawMenu();
  };
  function drawMenu() {
    clear(modelMenu);
    // Speech-to-text models only serve the mic: they can't answer a chat.
    for (const m of (State.settings.models ?? []).filter((m) => m.output !== "stt")) {
      const item = h(
        "button",
        { class: m.id === activeModel()?.id ? "model-item on" : "model-item" },
        h("span", { class: "model-name", text: m.label || m.model }),
        m.vision === true ? h("span", { class: "model-tag eye", title: "Sees images" }, svg(ICONS.eye, 10)) : null,
        m.vision === false ? h("span", { class: "model-tag", text: "text" }) : null,
        outputOf(m) !== "text" ? h("span", { class: "model-tag", text: outputOf(m) }) : null,
      );
      item.addEventListener("click", (e) => {
        e.stopPropagation();
        State.settings.activeModel = m.id;
        void Bridge.saveSettings(State.settings);
        setMenu(false);
        askImage = askImage && !(m.vision === true || m.kind === "claude") ? askImage : false;
        State.notify();
        input.focus();
      });
      modelMenu.append(item);
    }
    const manage = h("button", { class: "model-item manage", text: "Manage models…" });
    manage.addEventListener("click", (e) => {
      e.stopPropagation();
      setMenu(false);
      void Bridge.openSettingsWindow();
    });
    modelMenu.append(manage);
  }
  modelBtn.addEventListener("click", (e) => {
    e.stopPropagation();
    setMenu(!menuOpen);
  });
  document.addEventListener("click", () => menuOpen && setMenu(false));

  // "This model can't see images": asked instead of wasting a request.
  let askImage = false;
  let pendingQuery = "";
  const askText = h("span", {});
  const sendTextOnly = h("button", { class: "btn primary small", text: "Send without image" });
  const switchModel = h("button", { class: "btn secondary small", text: "Switch model" });
  const cancelAsk = h("button", { class: "btn secondary small", text: "Cancel" });
  const ask = h("div", { class: "image-ask" }, askText, h("div", { class: "image-ask-btns" }, sendTextOnly, switchModel, cancelAsk));
  sendTextOnly.addEventListener("click", () => {
    askImage = false;
    input.value = pendingQuery;
    void submit(true);
  });
  switchModel.addEventListener("click", (e) => {
    e.stopPropagation();
    setMenu(true);
  });
  cancelAsk.addEventListener("click", () => {
    askImage = false;
    input.value = pendingQuery;
    State.notify();
    onHeightChange();
  });

  // Speak instead of typing: records, shows the words as they're heard, and
  // sends when the mic is clicked again (Enter too; Esc throws it away).
  const mic = h("button", { class: "mic-btn", title: "Speak instead of typing" }, svg(ICONS.mic, 13));
  let recorder: MediaRecorder | null = null;
  let micStream: MediaStream | null = null;
  let chunks: Blob[] = [];
  let micType = "audio/webm";
  let liveTimer = 0;
  let capTimer = 0;
  const sttModel = () => (State.settings.models ?? []).find((m) => m.output === "stt") ?? null;
  const heard = () => Bridge.transcribe(new Blob(chunks, { type: micType }));
  const micFailed = (message: string) => {
    State.noteMessage = message;
    State.view = "note";
    Sound.play("error");
    State.notify();
  };

  async function startMic() {
    try {
      micStream = await navigator.mediaDevices.getUserMedia({ audio: true });
    } catch {
      micFailed("Coucou can't use the microphone: it's blocked, or there isn't one.");
      return;
    }
    chunks = [];
    const opus = "audio/webm;codecs=opus";
    recorder = new MediaRecorder(micStream, MediaRecorder.isTypeSupported(opus) ? { mimeType: opus } : undefined);
    micType = recorder.mimeType || "audio/webm";
    recorder.ondataavailable = (e) => e.data.size && chunks.push(e.data);
    recorder.start(500);
    mic.classList.add("rec");
    mic.title = "Listening: click to send, Esc to cancel";
    input.value = "";
    input.placeholder = "Listening…";
    Sound.play("peek");
    // The words so far, re-read every few seconds (gently: free tiers allow
    // about 20 transcriptions a minute).
    let busy = false;
    liveTimer = window.setInterval(async () => {
      if (busy || !chunks.length) return;
      busy = true;
      try {
        const text = await heard();
        if (recorder && text) input.value = text;
      } catch {
        // The final read reports any real problem.
      } finally {
        busy = false;
      }
    }, 4000);
    capTimer = window.setTimeout(() => void stopMic(true), 120_000);
  }

  async function stopMic(sendIt: boolean) {
    const r = recorder;
    if (!r) return;
    recorder = null;
    window.clearInterval(liveTimer);
    window.clearTimeout(capTimer);
    await new Promise<void>((done) => {
      r.onstop = () => done();
      r.stop();
    });
    micStream?.getTracks().forEach((t) => t.stop());
    micStream = null;
    mic.classList.remove("rec");
    mic.title = "Speak instead of typing";
    if (!sendIt) {
      chunks = [];
      input.value = "";
      State.notify();
      return;
    }
    mic.classList.add("busy");
    try {
      const text = await heard();
      chunks = [];
      if (text) {
        input.value = text;
        void submit();
      } else {
        Sound.play("blip");
      }
    } catch (err) {
      micFailed(String(err).replace(/^Error:\s*/, ""));
    } finally {
      mic.classList.remove("busy");
      State.notify();
    }
  }

  mic.addEventListener("click", (e) => {
    e.stopPropagation();
    if (mic.classList.contains("busy")) return;
    if (recorder) void stopMic(true);
    else void startMic();
  });

  const bar = h("div", { class: "chat-bar" }, input, picker, send, mic);

  // Under Mochi: start the conversation over, dropped file included, so an
  // unrelated question doesn't carry (and pay for) it again.
  const clearChat = h("button", { class: "chat-clear", title: "Clear chat" }, svg(ICONS.trash, 11), h("span", { text: "Clear" }));
  clearChat.addEventListener("click", () => {
    if (sending) return;
    State.chatHistory = [];
    releaseMedia();
    State.dropAttachment();
    void Bridge.chatReset();
    renderedCount = -1;
    State.notify();
    onHeightChange();
    input.focus();
  });

  const el = h(
    "div",
    { class: "view" },
    h("div", { class: "card wash chat-card" }, clearChat, h("div", { class: "chat-body" }, chipRow, log, ask, bar)),
  );
  (el.querySelector(".card") as HTMLElement).style.setProperty("--wash", "rgba(99,102,241,0.5)");

  let sending = false;
  let renderedCount = -1;
  /** What the model in flight makes; anything but text shows the generating card. */
  let making: ModelOutput = "text";

  async function submit(textOnly = false) {
    // A picture-to-3D model needs no words: the picture is the prompt.
    const query = input.value.trim() || (outputOf(activeModel()) === "3d" ? "3D model" : "");
    if (!query || sending) return;
    const file = State.droppedFile;
    const firstTurn = State.chatHistory.length === 0;
    const withImage = firstTurn && !!file && IMAGE_FILE.test(file.path) && !textOnly;
    // Known text-only model: ask before sending the image, don't spend a request.
    const model = activeModel();
    if (withImage && model?.vision === false) {
      pendingQuery = query;
      askImage = true;
      State.notify();
      onHeightChange();
      return;
    }
    input.value = "";
    sending = true;
    askImage = false;
    making = outputOf(model);
    resetProgress();
    Sound.play("send");

    // A dropped text or code file goes along on the first turn: show it too.
    const attachment =
      firstTurn && file?.path && !IMAGE_FILE.test(file.path) ? await Bridge.readAttachment(file.path) : null;
    State.chatHistory.push({
      id: nextId++,
      role: "user",
      content: query,
      attachment: attachment ? { name: file!.name, ...attachment } : null,
    });
    State.stateOverride = "thinking";
    State.notify();
    onHeightChange();

    // A 3D model works from the dropped picture on every turn, not just the first.
    const pictureTo3d = making === "3d" && !!file && IMAGE_FILE.test(file.path);
    const context: ChatContext | null =
      (State.chatHistory.length === 1 || pictureTo3d) && file ? { kind: "file", name: file.name, path: file.path } : null;

    try {
      const reply = await Bridge.chatSend(query, context, textOnly);
      State.chatHistory.push({
        id: nextId++, role: "assistant", content: reply.text, notice: reply.notice, media: reply.media,
      });
      // The model ends with how it feels about its answer; the island acts it out.
      if (reply.mood) window.dispatchEvent(new CustomEvent("mochi-mood", { detail: reply.mood }));
      State.stateOverride = null;
      Sound.play("finish");
    } catch (err) {
      State.stateOverride = null;
      const message = String(err).replace(/^Error:\s*/, "");
      if (message === IMAGES_UNSUPPORTED) {
        // The model turned the image down: take the question back and ask.
        State.chatHistory.pop();
        pendingQuery = query;
        askImage = true;
        Sound.play("blip");
      } else {
        State.noteMessage = message;
        State.view = "note";
        Sound.play("error");
      }
    } finally {
      sending = false;
      State.notify();
      onHeightChange();
      input.focus();
    }
  }

  send.addEventListener("click", () => void submit());
  input.addEventListener("keydown", (e) => {
    const key = (e as KeyboardEvent).key;
    if (recorder && (key === "Enter" || key === "Escape")) {
      e.preventDefault();
      e.stopPropagation();
      void stopMic(key === "Enter");
      return;
    }
    if (key === "Enter") {
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
        if (wantChip) {
          chipRow.append(
            contextChip(wantChip, () => {
              State.dropAttachment();
              onHeightChange();
            }),
          );
        }
      }

      clearChat.style.display = State.chatHistory.length || State.droppedFile ? "" : "none";
      const thinking = State.stateOverride === "thinking";
      const count = State.chatHistory.length + (thinking ? 0.5 : 0);
      if (count !== renderedCount) {
        renderedCount = count;
        clear(log);
        for (const m of State.chatHistory) log.append(bubble(m));
        if (thinking) log.append(making === "text" ? typingDots() : generatingCard(making));
        log.scrollTop = log.scrollHeight;
      }

      const name = State.settings.mochiName?.trim() || "me";
      const hint = {
        image: "Describe an image…",
        video: "Describe a video…",
        audio: "Text to speak…",
        "3d": State.droppedFile ? "Press Enter to make it 3D…" : "Drop a picture to make it 3D…",
        stt: "Pick a chat model to talk to…",
      };
      const output = outputOf(activeModel());
      input.placeholder =
        output !== "text" ? hint[output] : State.chatHistory.length === 0 ? `Ask ${name} anything…` : "Continue…";
      input.disabled = sending;
      if (recorder) input.placeholder = "Listening…";
      const stt = sttModel();
      mic.style.display = stt ? "" : "none";
      if (stt && !recorder) mic.title = `Speak instead of typing (${stt.label || stt.model})`;

      const model = activeModel();
      modelBtn.textContent = `${model?.label || model?.model || "No model"} \u25BE`;
      ask.classList.toggle("open", askImage);
      askText.textContent = `${model?.label || model?.model || "This model"} can't see images.`;
      if (menuOpen) drawMenu();
    },
    focus() {
      input.focus();
      input.select();
    },
  };
}
