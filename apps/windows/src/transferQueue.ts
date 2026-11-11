interface Pending {
  run: () => void;
  cancel: () => void;
}

export class TransferQueue {
  private limit = 1;
  private active = 0;
  private pending: Pending[] = [];

  setLimit(limit: number) {
    this.limit = Math.max(1, Math.floor(limit) || 1);
    this.drain();
  }

  acquire(signal: AbortSignal): Promise<(() => void) | undefined> {
    if (signal.aborted) return Promise.resolve(undefined);
    return new Promise(resolve => {
      const entry: Pending = {
        run: () => {
          signal.removeEventListener("abort", entry.cancel);
          this.active++;
          resolve(() => { this.active--; this.drain(); });
        },
        cancel: () => {
          this.pending = this.pending.filter(other => other !== entry);
          resolve(undefined);
        },
      };
      signal.addEventListener("abort", entry.cancel, {once: true});
      this.pending.push(entry);
      this.drain();
    });
  }

  private drain() {
    while (this.active < this.limit && this.pending.length) this.pending.shift()!.run();
  }
}
