/** Serial, coalesced persistence. Failed values stay pending until retry/flush. */
export class DeferredWrite<T> {
  private pending?: { value: T; revision: number };
  private revision = 0;
  private running?: Promise<void>;
  private timer?: ReturnType<typeof setTimeout>;
  private firstPendingAt = 0;

  constructor(private write: (value: T) => Promise<void>, private report: (error?: unknown) => void,
    private delay = 150, private maxWait = 1000) {}

  enqueue(value: T) {
    if (!this.pending) this.firstPendingAt = Date.now();
    this.pending = { value, revision: ++this.revision };
    clearTimeout(this.timer);
    this.timer = setTimeout(() => { void this.flush().catch(() => undefined); },
      Math.max(0, Math.min(this.delay, this.maxWait - (Date.now() - this.firstPendingAt))));
  }

  get dirty() { return Boolean(this.pending || this.running); }

  async flush(): Promise<void> {
    clearTimeout(this.timer);
    if (this.running) {
      await this.running;
      if (this.pending) return this.flush();
      return;
    }
    const drain = async () => {
      while (this.pending) {
        const item = this.pending;
        this.pending = undefined;
        try { await this.write(item.value); this.report(); }
        catch (error) {
          // Never replace a newer edit with an old failed write.
          if (!this.pending) this.pending = item;
          this.report(error);
          throw error;
        }
      }
    };
    this.running = drain();
    try { await this.running; } finally { this.running = undefined; }
  }
}
