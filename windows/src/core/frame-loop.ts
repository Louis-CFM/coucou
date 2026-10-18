/** One pending frame at most. A failed frame can be woken by the next input,
 * and does not create a retry loop while the user is away. */
export class FrameLoop {
  private pending: number | null = null;
  private drawing = false;
  private requested = false;
  private last = 0;

  private draw: (dt: number, now: number) => boolean;
  private report: (error: unknown) => void;
  private request: (fn: FrameRequestCallback) => number;

  constructor(
    draw: (dt: number, now: number) => boolean,
    report: (error: unknown) => void = console.error,
    request: (fn: FrameRequestCallback) => number = fn => requestAnimationFrame(fn),
  ) {
    this.draw = draw;
    this.report = report;
    this.request = request;
  }

  wake() {
    if (this.drawing) { this.requested = true; return; }
    if (this.pending !== null) return;
    this.last = performance.now();
    this.pending = this.request(this.frame);
  }

  private frame = (now: number) => {
    this.pending = null;
    this.drawing = true;
    this.requested = false;
    let again = false;
    try {
      again = this.draw(Math.max(0, Math.min(0.05, (now - this.last) / 1000)), now);
    } catch (error) {
      this.requested = false;
      this.report(error);
    } finally {
      this.drawing = false;
    }
    this.last = now;
    if (again || this.requested) this.pending = this.request(this.frame);
  };
}
