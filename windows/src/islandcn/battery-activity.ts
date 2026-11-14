// ── islandcn Battery Activity Component ─────────────────────────────────────
// Pixel-perfect Apple Dynamic Island / iOS status bar battery indicator.
// Provides precision geometry, inset floating fill, charging bolt glyph, and tabular percentage readout.

export interface BatteryState {
  /** Battery charge level from 0.0 to 1.0 (e.g. 0.58 = 58%) */
  level: number;
  /** True when connected to AC power and charging */
  charging: boolean;
  /** True if the device has a physical battery (false on desktop PCs) */
  hasBattery: boolean;
  /** Estimated seconds until fully charged (optional) */
  chargingTime?: number;
  /** Estimated seconds of remaining battery life (optional) */
  dischargingTime?: number;
}

export type BatteryColorMode = "normal" | "charging" | "low" | "critical";

export function getBatteryColorMode(state: BatteryState): BatteryColorMode {
  if (state.charging) return "charging";
  if (state.level <= 0.10) return "critical";
  if (state.level <= 0.20) return "low";
  return "normal";
}

export function getBatteryFillColor(mode: BatteryColorMode): string {
  switch (mode) {
    case "charging":
      return "#34c759"; // Apple System Green
    case "critical":
      return "#ff453a"; // Apple System Red
    case "low":
      return "#ff9f0a"; // Apple System Amber
    case "normal":
    default:
      return "#ffffff"; // Crisp Apple White
  }
}

/**
 * Creates the battery DOM structure for the notch:
 * <div id="island-battery" class="island-battery">
 *   <div class="battery-capsule">
 *     <div class="battery-shell">
 *       <div class="battery-fill"></div>
 *     </div>
 *     <div class="battery-nub"></div>
 *   </div>
 *   <svg class="battery-bolt">⚡</svg>
 *   <span class="battery-pct">58%</span>
 * </div>
 */
export function createBatteryElement(state: BatteryState, showPct = true): HTMLElement {
  const container = document.createElement("div");
  container.id = "island-battery";
  container.className = "island-battery";

  const capsule = document.createElement("div");
  capsule.className = "battery-capsule";

  const shell = document.createElement("div");
  shell.className = "battery-shell";

  const fill = document.createElement("div");
  fill.className = "battery-fill";

  shell.append(fill);

  const nub = document.createElement("div");
  nub.className = "battery-nub";

  capsule.append(shell, nub);

  // Micro-crisp Apple-style lightning bolt vector
  const bolt = document.createElementNS("http://www.w3.org/2000/svg", "svg");
  bolt.setAttribute("viewBox", "0 0 10 14");
  bolt.setAttribute("class", "battery-bolt");
  bolt.setAttribute("aria-hidden", "true");
  bolt.innerHTML = '<path d="M5.8 1L1.2 7.6h3.4L3.8 13l5-6.6H5.4L5.8 1z" fill="currentColor"/>';

  const pct = document.createElement("span");
  pct.className = "battery-pct";

  container.append(capsule, bolt, pct);

  updateBatteryElement(container, state, showPct);
  return container;
}

/**
 * Dynamically updates the battery fill width, color, charging state, and percentage label.
 */
export function updateBatteryElement(
  container: HTMLElement,
  state: BatteryState,
  showPct = true
): void {
  const pctEl = container.querySelector(".battery-pct") as HTMLElement | null;
  const fillEl = container.querySelector(".battery-fill") as HTMLElement | null;
  const boltEl = container.querySelector(".battery-bolt") as HTMLElement | null;

  if (!fillEl || !pctEl) return;

  const mode = getBatteryColorMode(state);
  const color = getBatteryFillColor(mode);
  const pctValue = Math.max(0, Math.min(100, Math.round(state.level * 100)));

  // Update container state classes
  container.classList.toggle("charging", state.charging);
  container.classList.toggle("low", mode === "low");
  container.classList.toggle("critical", mode === "critical");
  container.classList.toggle("no-battery", !state.hasBattery);

  // Set proportional fill width and fill color
  fillEl.style.width = `${pctValue}%`;
  fillEl.style.backgroundColor = color;

  // Percentage text
  pctEl.textContent = `${pctValue}%`;
  pctEl.style.display = showPct ? "" : "none";

  // Charging bolt visibility
  if (boltEl) {
    boltEl.style.display = state.charging ? "inline-block" : "none";
  }

  // Native tooltip
  let title = `${pctValue}%`;
  if (state.charging) {
    title += " (Charging)";
  } else if (!state.hasBattery) {
    title = "AC Power";
  }
  container.title = title;
}
