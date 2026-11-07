// The Kit's Prayer page: the next prayer and the time left on the left, the
// day's prayers on the sun's arc on the right, the sun where it stands now.
// A gear swaps in the settings: the city, the calculation method, Asr, the
// reminder before each prayer and pausing the music at prayer time.
// The times are worked out on this PC (core/prayer.ts).

import { h, clear, svg } from "./dom";
import { ICONS } from "./icons";
import { language, t } from "../i18n/i18n";
import {
  arcPosition, findCities, METHOD_NAMES, METHODS, nextPrayer, prayerTimes, untilParts,
  type MethodId, type PrayerName,
} from "../core/prayer";
import { Kit } from "../core/kitstore";
import type { ViewActions } from "./views";

const SVGNS = "http://www.w3.org/2000/svg";
const el = <K extends keyof SVGElementTagNameMap>(tag: K, attrs: Record<string, string | number> = {}) => {
  const n = document.createElementNS(SVGNS, tag);
  for (const [k, v] of Object.entries(attrs)) n.setAttribute(k, String(v));
  return n;
};

export function prayerLabel(p: PrayerName): string {
  switch (p) {
    case "fajr": return t("Fajr");
    case "sunrise": return t("Sunrise");
    case "dhuhr": return t("Dhuhr");
    case "asr": return t("Asr");
    case "maghrib": return t("Maghrib");
    case "isha": return t("Isha");
  }
}

/** 12-hour times ("5:00 AM"), whatever the PC's clock setting. */
const hm = (ms: number) => new Date(ms).toLocaleTimeString([], { hour: "numeric", minute: "2-digit", hour12: true });

/** "in 1 h 8 min", "in 25 min", "now". */
export function inWords(ms: number): string {
  const [hh, mm] = untilParts(ms);
  if (hh === 0 && mm === 0) return t("right now");
  if (hh === 0) return t("in {min} min", { min: mm });
  return mm === 0 ? t("in {h} h", { h: hh }) : t("in {h} h {min} min", { h: hh, min: mm });
}

/** Today in the Islamic calendar (Umm al-Qura), in the interface's language when the webview knows it. */
function hijri(now: number): string {
  try {
    return new Intl.DateTimeFormat(`${language()}-u-ca-islamic-umalqura`, { day: "numeric", month: "long", year: "numeric" }).format(now);
  } catch {
    return "";
  }
}

export function buildPrayerPage(actions: ViewActions): { el: HTMLElement; sync(now: number): void } {
  // ── The day ──
  const place = h("span", { class: "pr-place" });
  const hijriEl = h("span", { class: "pr-hijri" });
  const gear = h("button", { class: "kit-mini pr-gear", title: t("Prayer settings"), onclick: () => { settingsOpen = !settingsOpen; paint(); } }, svg(ICONS.gearLine, 13, { stroke: 1.8 }));
  const nextLbl = h("div", { class: "pr-next-lbl", text: t("Next") });
  const nextName = h("div", { class: "pr-next" });
  const nextTime = h("span", { class: "pr-time" });
  const nextIn = h("span", { class: "pr-in" });
  const barFill = h("i", { class: "pr-bar-fill" });
  const left = h("div", { class: "pr-left" },
    nextLbl, nextName, h("div", { class: "pr-when" }, nextTime, nextIn), h("div", { class: "pr-bar" }, barFill));

  // The arc: 0..1 across from sunrise to sunset, a little below the line at night.
  const W = 300;
  const H = 96;
  const base = 70;
  const lift = 58;
  const xOf = (f: number) => 14 + Math.min(1.08, Math.max(-0.08, f)) * (W - 28);
  const yOf = (f: number) => base - Math.sin(Math.PI * Math.min(1, Math.max(0, f))) * lift + (f < 0 || f > 1 ? Math.min(10, Math.abs(f < 0 ? f : f - 1) * 60) : 0);
  const arcSvg = el("svg", { viewBox: `0 0 ${W} ${H + 26}`, class: "pr-arc" });
  const defs = el("defs");
  const grad = el("linearGradient", { id: "pr-grad", x1: 0, x2: 1, y1: 0, y2: 0 });
  grad.append(el("stop", { offset: "0%", "stop-color": "#38bdf8" }), el("stop", { offset: "100%", "stop-color": "#818cf8" }));
  const glow = el("radialGradient", { id: "pr-sun" });
  glow.append(el("stop", { offset: "0%", "stop-color": "#fff7d6" }), el("stop", { offset: "45%", "stop-color": "#fcd34d", "stop-opacity": 0.9 }),
    el("stop", { offset: "100%", "stop-color": "#f59e0b", "stop-opacity": 0 }));
  defs.append(grad, glow);
  const horizon = el("line", { x1: 6, x2: W - 6, y1: base + 1, y2: base + 1, class: "pr-horizon" });
  const pathAll = el("path", { class: "pr-path" });
  const pathDone = el("path", { class: "pr-path-done" });
  const dotsG = el("g");
  const sun = el("circle", { r: 13, fill: "url(#pr-sun)" });
  const sunCore = el("circle", { r: 4.2, fill: "#fffbeb" });
  arcSvg.append(defs, horizon, pathAll, pathDone, dotsG, sun, sunCore);
  const right = h("div", { class: "pr-right" }, arcSvg);

  const dayEl = h("div", { class: "pr-day" }, left, h("i", { class: "pr-sep" }), right);

  // ── Settings ──
  const search = h("input", { class: "kit-input pr-search", type: "text", placeholder: t("Search a city…") }) as HTMLInputElement;
  const results = h("div", { class: "pr-results" });
  const method = h("select", { class: "kit-input pr-select", title: t("Calculation method") }) as HTMLSelectElement;
  for (const id of Object.keys(METHODS) as MethodId[]) method.append(h("option", { value: id, text: METHOD_NAMES[id] }));
  method.addEventListener("change", () => Kit.setPrayer({ method: method.value as MethodId }));
  const asr = h("select", { class: "kit-input pr-select", title: t("Asr") }) as HTMLSelectElement;
  asr.append(h("option", { value: "standard", text: t("Asr: Shafi'i, Maliki, Hanbali") }), h("option", { value: "hanafi", text: t("Asr: Hanafi") }));
  asr.addEventListener("change", () => Kit.setPrayer({ asr: asr.value === "hanafi" ? "hanafi" : "standard" }));
  const remind = h("select", { class: "kit-input pr-select", title: t("Reminder before each prayer") }) as HTMLSelectElement;
  for (const m of [0, 5, 10, 15, 20, 30]) remind.append(h("option", { value: String(m), text: m === 0 ? t("No reminder before") : t("{min} min before", { min: m }) }));
  remind.addEventListener("change", () => Kit.setPrayer({ remindMin: Number(remind.value) }));
  const pause = h("input", { type: "checkbox", class: "kit-check" }) as HTMLInputElement;
  pause.addEventListener("change", () => Kit.setPrayer({ pauseMusic: pause.checked }));
  for (const input of [search]) {
    input.addEventListener("mousedown", () => actions.keyboard(true));
    input.addEventListener("blur", () => actions.keyboard(false));
    input.addEventListener("keydown", (e) => e.stopPropagation());
  }
  search.addEventListener("input", () => listCities());
  const settingsEl = h("div", { class: "pr-settings" },
    h("div", { class: "pr-col" }, search, results),
    h("div", { class: "pr-col" },
      method, asr, remind,
      h("label", { class: "kit-lbl kit-remind" }, pause, h("span", { text: t("Pause music at prayer time") })),
      h("div", { class: "kit-row" }, h("div", { class: "grow" }), h("button", { class: "kit-btn primary", onclick: () => { settingsOpen = false; paint(); } }, h("span", { text: t("Done") })))));

  function listCities() {
    clear(results);
    const cur = Kit.data.prayer.city;
    for (const c of findCities(search.value, 6)) {
      const on = cur != null && cur.lat === c.lat && cur.lng === c.lng;
      results.append(h("button", {
        class: `pr-city${on ? " on" : ""}`,
        onclick: () => {
          Kit.setPrayer({ city: { name: c.name, country: c.country, lat: c.lat, lng: c.lng }, method: c.method, asr: c.hanafi ? "hanafi" : "standard" });
          search.value = "";
          listCities();
        },
      }, h("span", { class: "pr-city-n", text: c.name }), h("span", { class: "pr-city-c", text: c.country })));
    }
  }

  const root = h("div", { class: "pr-root" },
    h("div", { class: "pr-head" }, place, hijriEl, h("div", { class: "grow" }), gear),
    dayEl, settingsEl);

  let settingsOpen = false;
  let arcKey = "";
  let shownSettings: boolean | null = null;

  function paint() {
    const now = Date.now();
    sync(now);
  }

  function sync(now: number) {
    const p = Kit.data.prayer;
    const open = settingsOpen || p.city == null;
    if (shownSettings !== open) {
      shownSettings = open;
      settingsEl.classList.toggle("on", open);
      dayEl.classList.toggle("on", !open);
      gear.classList.toggle("on", open);
      if (open) {
        method.value = p.method;
        asr.value = p.asr;
        remind.value = String(p.remindMin);
        pause.checked = p.pauseMusic;
        listCities();
      }
    }
    const placeText = p.city ? `${t("Prayer")} · ${p.city.name}` : t("Choose your city");
    if (place.textContent !== placeText) place.textContent = placeText;
    const hj = hijri(now);
    if (hijriEl.textContent !== hj) hijriEl.textContent = hj;
    if (open || !p.city) return;

    const { lat, lng } = p.city;
    const next = nextPrayer(now, lat, lng, p.method, p.asr);
    const name = prayerLabel(next.name);
    if (nextName.textContent !== name) nextName.textContent = name;
    const time = hm(next.at);
    if (nextTime.textContent !== time) nextTime.textContent = time;
    const inText = inWords(next.at - now);
    if (nextIn.textContent !== inText) nextIn.textContent = inText;
    const span = Math.max(1, next.at - next.prev.at);
    barFill.style.width = `${Math.min(100, Math.max(0, ((now - next.prev.at) / span) * 100))}%`;

    const times = prayerTimes(now, lat, lng, p.method, p.asr);
    const minute = Math.floor(now / 60_000);
    const key = `${minute}|${lat}|${lng}|${p.method}|${p.asr}|${language()}`;
    if (key !== arcKey) {
      arcKey = key;
      // The curve, and the part of it the sun has already crossed.
      const pts = (to: number) => {
        const out: string[] = [];
        for (let i = 0; i <= 60; i++) {
          const f = -0.08 + (Math.min(to, 1.08) + 0.08) * (i / 60);
          out.push(`${i ? "L" : "M"}${xOf(f).toFixed(1)},${yOf(f).toFixed(1)}`);
        }
        return out.join(" ");
      };
      const nowF = arcPosition(now, times);
      pathAll.setAttribute("d", pts(1.08));
      pathDone.setAttribute("d", pts(nowF));
      while (dotsG.firstChild) dotsG.firstChild.remove();
      for (const pr of ["fajr", "dhuhr", "asr", "maghrib", "isha"] as PrayerName[]) {
        const f = arcPosition(times[pr], times);
        const x = xOf(f);
        const y = yOf(f);
        const isNext = pr === next.name && new Date(next.at).toDateString() === new Date(now).toDateString();
        const passed = times[pr] <= now;
        dotsG.append(el("circle", { cx: x, cy: y, r: isNext ? 3.6 : 2.6, class: `pr-pt${passed ? " passed" : ""}${isNext ? " next" : ""}` }));
        const label = el("text", { x, y: H + 8, class: `pr-lbl${isNext ? " next" : ""}`, "text-anchor": "middle" });
        label.textContent = prayerLabel(pr);
        const tm = el("text", { x, y: H + 20, class: `pr-tm${isNext ? " next" : ""}`, "text-anchor": "middle" });
        tm.textContent = hm(times[pr]);
        dotsG.append(label, tm);
      }
      const sx = xOf(nowF);
      const sy = yOf(nowF);
      for (const c of [sun, sunCore]) {
        c.setAttribute("cx", sx.toFixed(1));
        c.setAttribute("cy", sy.toFixed(1));
      }
      // At night the sun sits low and dim at the arc's end.
      const night = nowF < 0 || nowF > 1;
      sun.setAttribute("opacity", night ? "0.35" : "1");
      sunCore.setAttribute("opacity", night ? "0.5" : "1");
    }
  }

  return { el: root, sync };
}

