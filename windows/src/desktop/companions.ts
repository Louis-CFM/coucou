import { NoticeQueue, type PetNotice } from "../mochi/notices";
import { Bridge, emitToWindow, onEvent } from "../core/bridge";
import { FlowBridge, type PillState } from "../core/flow";
import { Sound } from "../core/sound";
import { SPOTIFY_ID } from "../core/spotify";
import { BotEngine, hexToRGB } from "../mochi/engine";
import { CompanionWorld, PET_EVENTS, PET_SIZE, type CompanionsSnapshot, type PetLife } from "../mochi/companions";
import { resolveLanguage, setLanguage, systemLanguages, t } from "../i18n/i18n";
import { registerVoiceSpeech } from "../pill/voice-speech";

interface PetView { button: HTMLButtonElement; canvas: HTMLCanvasElement; label: HTMLSpanElement; engine: BotEngine; sleepKey?: string }
const world = new CompanionWorld();
const views = new Map<string, PetView>();
const root = document.getElementById("pets")!;
const menu = document.getElementById("menu")!;
const voice = document.getElementById("voice")!;
const notice = document.createElement("aside");
notice.className = "pet-notice"; notice.hidden = true;
notice.setAttribute("role","status"); notice.setAttribute("aria-live","polite");
document.body.append(notice);
const noticeQueue = new NoticeQueue();
let shownNotice: PetNotice | null = null;
let noticeTimer: number | null = null;
function dismissNotice() {
  if(noticeTimer!=null) window.clearTimeout(noticeTimer);
  noticeTimer=null; shownNotice=null; notice.hidden=true;
  world.presented=voicePet??snapshot.presented??null;
  input(performance.now()/1000,true); showNextNotice(); wake();
}
function showNextNotice() {
  if(shownNotice || !snapshot.enabled || snapshot.paused || !nativeVisible || voicePet || snapshot.presented) return;
  const next=noticeQueue.take(); if(!next)return;
  const p=world.pets.get(next.pet);
  if(!p?.shown){showNextNotice();return;}
  shownNotice=next; world.presented=next.pet; world.touch(next.pet,performance.now()/1000);
  const name=document.createElement("strong");name.textContent=p.identity.name;
  const text=document.createElement("p");text.textContent=t(next.text);
  const review=document.createElement("button");review.textContent=t("Review");
  review.onclick=()=>{ const view=next.view; dismissNotice(); open(p,view); };
  const close=document.createElement("button");close.textContent=t("Dismiss");close.onclick=dismissNotice;
  notice.replaceChildren(name,text,review,close);
  positionNotice();notice.hidden=false;
  noticeTimer=window.setTimeout(dismissNotice,next.urgent?12000:7000);
  input(performance.now()/1000,true);wake();
}
function positionNotice() {
  const p=shownNotice && world.pets.get(shownNotice.pet);if(!p)return;
  const left=Math.max(8,Math.min(world.width-308,p.x-150));
  notice.style.left=`${left}px`;notice.style.top=`${(world.band?.height??p.y+30)+8}px`;
  notice.style.setProperty("--tip",`${Math.max(12,Math.min(280,p.x-left-6))}px`);
}
let voicePet: string | null = null;
let voiceActive = false;
interface VoiceView { phase: string; heard: string; answer: string; pet?: string; announcementId?: number; note?: boolean }
let bubble: {view: VoiceView; dictation: boolean} | null = null;
function voiceBubble(view: VoiceView | null, dictation = false) {
  bubble = view ? {view,dictation} : null;
  voice.hidden = !view;
  voice.replaceChildren();
  if (!view) { voicePet = null; showNextNotice(); world.presented = snapshot.presented ?? null; input(performance.now()/1000, true); return; }
  const owner = dictation ? "ai_ollama" : view.pet;
  const p = owner ? world.pets.get(owner) : world.pets.get("agent_codex") ?? world.pets.get("ai_ollama");
  if (!p?.shown) { voice.hidden = true; return; }
  voicePet = p.identity.id;
  if(shownNotice) dismissNotice();
  world.presented = voicePet;
  world.touch(voicePet, performance.now()/1000);
  world.sync({...snapshot,presented:voicePet,motion:world.motion},window.innerWidth,performance.now()/1000);
  void emitToWindow("island", "companions-hide-popup");
  const title = document.createElement("strong");
  const phases: Record<string,string> = {listening:t("Listening"),thinking:t("Thinking…"),speaking:t("Answers"),copied:t("Dictation")};
  title.textContent = `${p.identity.name} · ${dictation ? t("Dictation") : phases[view.phase] ?? view.phase}`;
  const heard = document.createElement("p"); heard.className = "heard"; heard.textContent = view.heard;
  const answer = document.createElement("p"); answer.textContent = view.answer;
  voice.append(title, heard, answer);
  const actions = view.announcementId != null ? [[t("Close"),"dismiss"]] :
    view.note ? [[t("Finish"),"stopNote"]] :
    [[t("Cancel"), "cancel"], ...(["listening", "locked"].includes(view.phase) ? [[t("Finish"), "finish"]] : [])];
  for (const [text, action] of actions) {
    const button = document.createElement("button"); button.textContent = text;
    button.onclick = () => void FlowBridge.pillAction(action, view.announcementId);
    voice.append(button);
  }
  const left = Math.max(8, Math.min(world.width - 348, p.x - 170));
  voice.style.left = `${left}px`;
  voice.style.top = `${(world.band?.height ?? p.y + 30) + 10}px`;
  voice.style.setProperty("--tip", `${Math.max(12, Math.min(320,p.x-left-6))}px`);
  input(performance.now()/1000, true); wake();
}
const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
let snapshot: CompanionsSnapshot = { enabled: false, paused: false, motion: true, pets: [] };
let timer: number | null = null;
let last = 0;
let lastShape = "";
let shapeAt = -Infinity;
let dragging: { id: string; start: number; x: number; moved: boolean } | null = null;
let suppressClick = false;
let nativeVisible = true;
let menuTimer: number | null = null;
let menuPet: string | null = null;
// Ambient behaviour stays silent. The island already owns notification sounds;
// several pets must not create several audio contexts or repeat an alert.
Sound.setEnabled(false);

// Events can precede the snapshot that introduces their owner. Keep that
// exact identity briefly; never substitute a different integration's pet.
let pendingPresentation: { id: string; view: string; until: number } | null = null;
function presentPending() {
  const e = pendingPresentation;
  if (!e) return;
  if (performance.now() > e.until) { pendingPresentation = null; return; }
  const p = world.pets.get(e.id);
  if (p?.shown && nativeVisible) open(p, e.view);
}

function open(p: PetLife, view?: string) {
  pendingPresentation = null;
  if(shownNotice) { if(noticeTimer!=null)window.clearTimeout(noticeTimer);noticeTimer=null;shownNotice=null;notice.hidden=true; }
  closeMenu();
  world.touch(p.identity.id, performance.now() / 1000);
  world.sync({...snapshot,presented:p.identity.id,motion:world.motion},window.innerWidth,performance.now()/1000);
  void Bridge.companionsOpen(p.identity.id, p.x, p.y, view ?? (p.identity.id === "ai_ollama" ? "prompt" : undefined));
}

function closeMenu() {
  const wasOpen = !menu.hidden;
  menuPet = null;
  if (menuTimer != null) window.clearTimeout(menuTimer);
  menuTimer = null;
  menu.hidden = true;
  if (wasOpen) world.hovered = null;
}
function showMenu(p: PetLife) {
  closeMenu();
  menu.replaceChildren();
  const add = (label: string, action: () => void) => {
    const b = document.createElement("button");
    b.textContent = label;
    b.addEventListener("click", () => { closeMenu(); action(); wake(); });
    menu.append(b);
  };
  add(t("Open"), () => open(p));
  if (p.identity.id === "ai_ollama") {
    add(t("Chat"), () => open(p, "prompt"));
    add(t("Talk to Mochi"), () => void FlowBridge.pillAction("voice"));
    add(t("Dictation"), () => void FlowBridge.pillAction("dictate"));
  }
  if (p.identity.id === SPOTIFY_ID) add(t("Play / pause"), () => void Bridge.spotifyControl("playPause"));
  add(t("Pet"), () => world.touch(p.identity.id, performance.now() / 1000));
  add(snapshot.paused ? t("Resume companions") : t("Pause companions"), () => {
    void emitToWindow("island", PET_EVENTS.action, { action: "pause" });
  });
  add(t("Settings"), () => void Bridge.openSettingsWindow());
  menu.style.left = `${Math.max(0, Math.min(world.width - 170, p.x - 76))}px`;
  menu.style.top = `${p.y + 40}px`;
  menu.hidden = false;
  menuPet = p.identity.id;
  menuTimer = window.setTimeout(closeMenu, 8000);
  world.hovered = p.identity.id;
  wake();
}

function create(p: PetLife): PetView {
  const button = document.createElement("button");
  button.className = "pet";
  const canvas = document.createElement("canvas");
  const label = document.createElement("span");
  button.append(canvas, label);
  root.append(button);
  const engine = new BotEngine();
  engine.particleOverhang = 0;
  button.addEventListener("click", () => {
    if (suppressClick) { suppressClick = false; return; }
    if (snapshot.presented === p.identity.id) {
      pendingPresentation = null;
      void emitToWindow("island", "companions-hide-popup");
    } else open(p);
  });
  button.addEventListener("pointerenter", () => { world.hovered = p.identity.id; wake(); });
  button.addEventListener("pointerleave", () => { if (menu.hidden && !dragging) { world.hovered = null; wake(); } });
  button.addEventListener("contextmenu", e => { e.preventDefault(); showMenu(p); });
  button.addEventListener("pointerdown", e => {
    if (e.button !== 0) return;
    dragging = { id: p.identity.id, start: e.clientX, x: p.x, moved: false };
    button.setPointerCapture(e.pointerId);
  });
  button.addEventListener("pointermove", e => {
    if (!dragging || dragging.id !== p.identity.id) return;
    const delta = e.clientX - dragging.start;
    if (Math.abs(delta) > 4) dragging.moved = true;
    if (!dragging.moved) return;
    let [left, right] = world.bounds(p);
    // Keep both bodies clickable when a user drags one into another.
    for (const other of world.pets.values()) {
      if (other === p || !other.shown || other.y !== p.y) continue;
      if (p.x < other.x) right = Math.min(right, other.x - world.spacing);
      else left = Math.max(left, other.x + world.spacing);
    }
    p.x = Math.max(left, Math.min(right, dragging.x + delta));
    wake();
  });
  const endDrag = () => {
    suppressClick = dragging?.moved ?? false;
    dragging = null;
    if (menu.hidden) world.hovered = null;
  };
  button.addEventListener("pointerup", endDrag);
  button.addEventListener("pointercancel", endDrag);
  return { button, canvas, label, engine };
}

function input(now: number, force = false) {
  if (!force && now - shapeAt < 0.1) return;
  const rects: [number, number, number, number][] = [];
  if (snapshot.enabled) for (const p of world.pets.values()) {
    if (!p.shown) continue;
    const scale = world.scale;
    // Disc rows around the body, plus its own label. Empty habitat never takes
    // input. A small margin accommodates the movement between region updates.
    for (let y = -22; y < 22; y += 4) {
      const dx = Math.sqrt(23 * 23 - y * y) + 3;
      rects.push([p.x - dx * scale, p.y + (y - 2) * scale, dx * 2 * scale, 8 * scale]);
    }
    if (!world.band) rects.push([p.x - 30, p.y + 19, 60, 23]);
  }
  if (!menu.hidden && snapshot.enabled) {
    const r = menu.getBoundingClientRect();
    rects.push([r.x, r.y, r.width, r.height]);
  }
  if (!notice.hidden && snapshot.enabled) { const r=notice.getBoundingClientRect();rects.push([r.x,r.y,r.width,r.height]); }
  if (!voice.hidden && snapshot.enabled) { const r = voice.getBoundingClientRect(); rects.push([r.x,r.y,r.width,r.height]); }
  const key = JSON.stringify(rects.map(r => r.map(Math.round)));
  shapeAt = now;
  if (key === lastShape) return;
  lastShape = key;
  void Bridge.companionsInput(JSON.parse(key));
}

function draw(p: PetLife, v: PetView, dt: number, now: number) {
  const { engine, canvas, button, label } = v;
  button.hidden = !p.shown;
  if (!p.shown) { v.sleepKey = undefined; return; }
  const sleeping = p.action === "sleep";
  const sleepKey = sleeping ? JSON.stringify([p.x,p.y,world.scale,p.identity.color,p.identity.outfit]) : undefined;
  if (sleeping && v.sleepKey === sleepKey) return;
  v.sleepKey = sleepKey;
  engine.setState(sleeping ? "sleeping" : p.identity.state, sleeping);
  engine.bodyColor = hexToRGB(p.identity.color);
  engine.setOutfit(p.identity.outfit, false);
  engine.setDancing(p.action === "dance" || (world.motion && p.identity.dancing && p.action === "walk"));
  engine.lookX = ["walk", "wave"].includes(p.action) ? p.direction * 0.65 : p.action === "look" ? Math.sin(now * 0.4 + p.seed) * 0.8 : 0;
  if (p.emote) {
    if (world.motion && !snapshot.paused) {
      if (p.action === "wave") engine.greet();
      engine.triggerEmote(p.emote, 1.5);
    }
    p.emote = null;
  }
  if (world.motion || sleeping) engine.update(dt);
  const dpr = Math.min(2, window.devicePixelRatio || 1);
  const size = Math.round(PET_SIZE * dpr);
  if (canvas.width !== size || canvas.height !== size) canvas.width = canvas.height = size;
  const ctx = canvas.getContext("2d");
  if (!ctx) return;
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.clearRect(0, 0, PET_SIZE, PET_SIZE);
  ctx.save();
  if (p.action === "walk") {
    const stride = Math.sin(now * 11) * 2;
    // Two little feet and a gait complement the engine's face and breathing.
    ctx.fillStyle = p.identity.color;
    for (const side of [-1, 1]) {
      ctx.beginPath();
      ctx.ellipse(32 + side * 10 + side * stride, 50, 5, 2.5, 0, 0, Math.PI * 2);
      ctx.fill();
    }
    ctx.translate(0, -Math.abs(Math.sin(now * 11)) * 2);
    ctx.translate(32, 32); ctx.rotate(stride * 0.012); ctx.translate(-32, -32);
  }
  if (p.action === "wave") {
    // Partners face each other, lift a hand and share a small synchronized hop.
    const phase = (1.8 - Math.max(0, p.until - now)) / 1.8;
    ctx.translate(0, -Math.sin(Math.PI * phase) * 2);
    ctx.strokeStyle = p.identity.color;
    ctx.lineWidth = 4; ctx.lineCap = "round";
    const side = p.direction;
    ctx.beginPath(); ctx.moveTo(32 + side * 19, 34);
    ctx.quadraticCurveTo(32 + side * 28, 26, 32 + side * (26 + Math.sin(now * 12) * 2), 19);
    ctx.stroke();
  }
  engine.applyDance(ctx, PET_SIZE, PET_SIZE);
  engine.draw(ctx, PET_SIZE, PET_SIZE);
  if (p.identity.attention) {
    ctx.fillStyle = "#fbbf24";
    ctx.beginPath(); ctx.arc(52, 11, 5, 0, Math.PI*2); ctx.fill();
  }
  ctx.restore();
  button.style.transform = `translate(${p.x - 32 * world.scale}px, ${p.y - 32 * world.scale}px) scale(${world.scale})`;
  button.style.transformOrigin = "top left";
  button.style.clipPath = world.band ? "circle(25px at 32px 32px)" : "none";
  label.hidden = !!world.band;
  button.dataset.attention = String(p.identity.attention);
  const description = `${p.identity.name} · ${t("Open")}`;
  if (button.title !== description) { button.title = description; button.setAttribute("aria-label", description); }
  if (label.textContent !== p.identity.name) label.textContent = p.identity.name;
}

function wake() {
  if (timer != null || ![...world.pets.values()].some(p => p.shown) || !snapshot.enabled || !nativeVisible || document.hidden || !world.pets.size) return;
  timer = window.setTimeout(frame, 0);
}
function frame() {
  timer = null;
  if (!snapshot.enabled || !nativeVisible || document.hidden) return;
  const now = performance.now() / 1000;
  const dt = Math.min(0.1, Math.max(0, now - last));
  last = now;
  try {
    world.tick(dt, now);
    for (const p of world.pets.values()) draw(p, views.get(p.identity.id)!, dt, now);
    input(now);
  } catch (error) {
    // A drawing failure must not leave invisible input regions over the apps.
    console.error("[coucou] companions frame", error);
    void Bridge.companionsInput([]);
    lastShape = "";
    return;
  }
  if (world.needsFrames) {
    const moving = [...world.pets.values()].some(p => p.shown && ["walk","wave","dance","celebrate"].includes(p.action));
    timer = window.setTimeout(frame, !world.motion ? 1000 : moving ? 1000 / 24 : 250);
  }
}

async function start() {
  await registerVoiceSpeech();
  await onEvent<PetNotice>("companions-notice", n=>{noticeQueue.push(n);showNextNotice();});
  await onEvent<VoiceView | null>("companions-voice", view => { voiceActive = !!view; voiceBubble(view); });
  await onEvent<PillState>("companions-flow", state => {
    if (voiceActive) return;
    const active = ["listening", "locked", "thinking", "copied", "failed", "pastedAgain"].includes(state.phase);
    const feedback = state.phase === "copied" ? t("Copied · press Ctrl+V to paste") :
      state.phase === "failed" ? t("Microphone unavailable") :
      state.phase === "pastedAgain" ? t("Last dictation pasted") : null;
    if (active || state.announcement || state.noteStartedAt) {
      voiceBubble({phase: state.phase, heard: "", announcementId: state.announcement?.id, note: !!state.noteStartedAt, answer: state.announcement?.text ?? feedback ??
        (state.phase === "thinking" ? t("Thinking…") : state.noteStartedAt ? t("Notetaker") : t("Listening"))}, true);
    } else voiceBubble(null, true);
  });
  await onEvent<{ id: string; view: string }>("companions-present", e => {
    if (!e.id) return;
    pendingPresentation = { ...e, until: performance.now() + 10000 };
    presentPending();
  });
  await onEvent<boolean>("companions-visible", visible => {
    nativeVisible = visible;
    if (!visible && timer != null) { window.clearTimeout(timer); timer = null; }
    if (visible) { presentPending(); showNextNotice(); wake(); }
  });
  await onEvent<CompanionsSnapshot>(PET_EVENTS.state, s => {
    snapshot = s;
    setLanguage(resolveLanguage(s.language ?? "", systemLanguages()));
    if (!s.enabled || (menuPet && !s.pets.some(p=>p.id===menuPet))) closeMenu();
    const oldPet = s.presented ? world.pets.get(s.presented) : null;
    const oldPosition = oldPet ? [oldPet.x, oldPet.y] : null;
    world.sync({ ...s, presented: voicePet ?? s.presented ?? shownNotice?.pet, motion: s.motion && !reducedMotion.matches }, window.innerWidth, performance.now() / 1000);
    for (const [id, v] of views) if (!world.pets.has(id)) { v.button.remove(); views.delete(id); }
    for (const p of world.pets.values()) if (!views.has(p.identity.id)) views.set(p.identity.id, create(p));
    if (shownNotice && (s.paused || !s.enabled || s.presented)) dismissNotice();
    presentPending();
    positionNotice();
    showNextNotice();
    if (bubble) voiceBubble(bubble.view,bubble.dictation);
    else if (oldPet?.shown && oldPosition && (oldPet.x !== oldPosition[0] || oldPet.y !== oldPosition[1])) {
      void Bridge.companionsAnchor(oldPet.x,oldPet.y);
    }
    if (timer != null) window.clearTimeout(timer);
    timer = null;
    if (!s.enabled) { root.hidden = true; input(performance.now() / 1000, true); }
    else { root.hidden = false; last = performance.now() / 1000; wake(); }
  });
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) {
      if (timer != null) window.clearTimeout(timer);
      timer = null;
    } else wake();
  });
  document.addEventListener("pointerdown", e => { if (e.target === document.body) { closeMenu(); wake(); } });
  reducedMotion.addEventListener("change", () => { world.motion = snapshot.motion && !reducedMotion.matches; wake(); });
  window.addEventListener("resize", () => {
    world.sync({ ...snapshot, motion: snapshot.motion && !reducedMotion.matches }, window.innerWidth, performance.now() / 1000);
    wake();
  });
  await emitToWindow("island", PET_EVENTS.ready);
}
void start();
