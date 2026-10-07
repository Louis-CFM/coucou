export class SettingsSaveQueue<T extends { revision?: number }> {
  private running = false;
  private pending: T | null = null;
  private waiters: { resolve: () => void; reject: (error: unknown) => void }[] = [];
  private current: T | null = null;
  private cycleError: unknown = null;
  private concurrent = 0;
  lastError: unknown = null;
  maxConcurrent = 0;

  constructor(private readonly persist: (value: T) => Promise<void>) {}
  get revision(): number { return this.current?.revision ?? 0; }
  replaceCurrent(value: T) { this.current = value; }
  schedule(value: T) { this.current = value; this.pending = value; void this.drain(); }
  idle(): Promise<void> {
    if (!this.running && !this.pending) return this.lastError ? Promise.reject(this.lastError) : Promise.resolve();
    return new Promise((resolve, reject) => this.waiters.push({ resolve, reject }));
  }
  private async drain() {
    if (this.running) return;
    this.running = true;
    this.cycleError = null;
    while (this.pending) {
      const value = this.pending;
      this.pending = null;
      this.concurrent += 1;
      this.maxConcurrent = Math.max(this.maxConcurrent, this.concurrent);
      try { await this.persist(value); this.lastError = null; }
      catch (error) { this.lastError = error; this.cycleError ??= error; }
      finally { this.concurrent -= 1; }
    }
    this.running = false;
    const waiters = this.waiters.splice(0);
    if (this.cycleError) waiters.forEach(({ reject }) => reject(this.cycleError));
    else waiters.forEach(({ resolve }) => resolve());
    if (this.pending) void this.drain();
  }
}
