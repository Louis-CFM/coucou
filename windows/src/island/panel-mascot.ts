// The panel displays the original engine, including its current emote, outfit
// transition and dance. Uncompressed pixels avoid PNG encoder stalls; GNOME
// presents the latest frame on its monitor clock, without queuing stale frames.
import { Bridge, IS_TAURI } from "../core/bridge";
import { State } from "../core/state";
import { BotEngine } from "../mochi/engine";

export class PanelMascot {
  private canvas = document.createElement("canvas");
  private deadline = performance.now();
  private sequence = 0;
  private drawing = document.createElement("canvas");
  private measuring = new BotEngine();
  private fitOutfit = "";
  private fit = {x: 36, y: 40, width: 56, height: 64};
  private fitTarget = {...this.fit};
  private lastFrame = performance.now();

  private pointer = {x: 0, y: 0, hover: false, visible: true, transport: ""};
  private hoveredAt = 0;
  private lovedAt = -6000;

  constructor(private engine: BotEngine, private prepare: (x: number, y: number) => void) {
    this.canvas.width = 80;
    this.canvas.height = 64;
    this.drawing.width = this.drawing.height = 128;
    if (IS_TAURI) void this.tick();
  }

  private async tick() {
    try { await this.frame(); } catch { /* Recover after a bridge restart. */ }
    const period = (!State.panelIntegration || (!this.pointer.visible && State.mode !== "expanded")) ? 1000 : this.pointer.transport === "rgba120" ? 1000 / 120 : 1000 / 30;
    this.deadline += period;
    const now = performance.now();
    // Skip missed deadlines instead of piling up work or speeding up the dance.
    if (this.deadline < now) this.deadline += Math.ceil((now - this.deadline) / period) * period;
    window.setTimeout(() => void this.tick(), Math.max(0, this.deadline - now));
  }

  private async frame() {
    const now = performance.now();
    if (!State.panelIntegration) return;
    const dt = Math.min(.05, (now - this.lastFrame) / 1000);
    this.lastFrame = now;
    const compact = State.mode !== "expanded";
    if (compact) {
      this.prepare(this.pointer.x, this.pointer.y);
      // The full window's frame loop sleeps while GNOME shows the capsule.

      if (this.pointer.hover && !this.hoveredAt) {
        this.hoveredAt = now;
        this.engine.blink();
        this.engine.tgEs = 1.08;
      } else if (!this.pointer.hover && this.hoveredAt) {
        this.hoveredAt = 0;
        this.engine.tgEs = 1;
      }
      if (this.hoveredAt && now - this.hoveredAt >= 1900 && now - this.lovedAt >= 6000) {
        this.engine.triggerEmote("love");
        this.lovedAt = now;
      }
    } else if (this.hoveredAt) {
      this.hoveredAt = 0;
      this.engine.tgEs = 1;
    }
    this.engine.update(dt);
    const draw = this.drawing.getContext("2d", {willReadFrequently: true});
    if (!draw) return;
    if (this.fitOutfit !== this.engine.outfit) {
      this.fitOutfit = this.engine.outfit;
      // Measure the original accessory in a neutral pose, once per change.
      // Stable framing preserves the dance instead of chasing each frame's bounds.
      this.measuring.setOutfit(this.engine.outfit, false);
      draw.setTransform(2, 0, 0, 2, 36, 40);
      draw.clearRect(-18, -20, 64, 64);
      this.measuring.draw(draw, 28, 28);
      const rgba = draw.getImageData(0, 0, 128, 128).data;
      let left = 128, right = 0, top = 128, bottom = 0;
      for (let y = 0; y < 128; y++) for (let x = 0; x < 128; x++) {
        if (rgba[(y * 128 + x) * 4 + 3] > 16) {
          left = Math.min(left, x); right = Math.max(right, x + 1);
          top = Math.min(top, y); bottom = Math.max(bottom, y + 1);
        }
      }
      this.fitTarget = {x: left - 8, y: top - 8, width: right - left + 16, height: bottom - top + 16};
    }
    const blend = 1 - Math.exp(-dt / .12);
    for (const key of ["x", "y", "width", "height"] as const)
      this.fit[key] += (this.fitTarget[key] - this.fit[key]) * blend;
    draw.setTransform(1, 0, 0, 1, 0, 0);
    draw.clearRect(0, 0, 128, 128);
    draw.setTransform(2, 0, 0, 2, 36, 40);
    const ctx = this.canvas.getContext("2d", {willReadFrequently: true});
    if (!ctx) return;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, 80, 64);

    const overhang = this.engine.particleOverhang;
    this.engine.particleOverhang = 0;
    draw.save();
    this.engine.applyDance(draw, 28, 28);
    this.engine.draw(draw, 28, 28);
    draw.restore();
    this.engine.particleOverhang = overhang;
    const scale = Math.min(76 / this.fit.width, 60 / this.fit.height);
    ctx.setTransform(scale, 0, 0, scale,
      (80 - this.fit.width * scale) / 2 - this.fit.x * scale,
      (64 - this.fit.height * scale) / 2 - this.fit.y * scale);
    ctx.drawImage(this.drawing, 0, 0);
    let packet: Uint8Array;
    if (this.pointer.transport === "rgba120") {
      // CCF1: fixed 80×64 RGBA pixels, sequence, capture time. At most one IPC
      // request is in flight; the shell reads only the newest complete packet.
      packet = new Uint8Array(16 + 80 * 64 * 4);
      packet.set([67, 67, 70, 49]);
      const header = new DataView(packet.buffer);
      header.setUint32(4, ++this.sequence, true);
      header.setFloat64(8, Date.now(), true);
      packet.set(ctx.getImageData(0, 0, 80, 64).data, 16);
    } else {
      // Compatibility while the previous extension is still loaded by GNOME.
      const blob = await new Promise<Blob | null>(resolve => this.canvas.toBlob(resolve, "image/png"));
      if (!blob) return;
      packet = new Uint8Array(await blob.arrayBuffer());
    }
    const pointer = await Bridge.publishPanelFrame(packet);
    if (pointer) this.pointer = {...pointer, transport: pointer.transport ?? ""};
  }
}
