// One budget per tab; automatic attempts preserve it, explicit user retries reset it.
export class ScreenRecovery {
  private firstFrameRetries = 0;
  private brokerFailures: number[] = [];
  reset() { this.firstFrameRetries = 0; this.brokerFailures = []; }

  attempt(enabled: boolean, retry: (reason: "broker" | "firstFrame") => void, timeout: () => void) {
    let timer: ReturnType<typeof setTimeout> | undefined;
    let disposed = false, pending = false, framed = false, connected = false;
    const clear = () => { if (timer !== undefined) clearTimeout(timer); timer = undefined; };
    const recover = (reason: "broker" | "firstFrame") => {
      clear(); pending = true;
      timer = setTimeout(() => { if (!disposed) retry(reason); }, 300);
    };
    return {
      get pending() { return pending; },
      connected: () => {
        if (!enabled || disposed || pending || framed || connected) return;
        connected = true;
        timer = setTimeout(() => {
          if (disposed || framed) return;
          if (this.firstFrameRetries++ === 0) recover("firstFrame");
          else { pending = true; timeout(); }
        }, 15_000);
      },
      frame: () => {
        if (disposed || pending) return;
        framed = true; clear(); this.firstFrameRetries = 0;
      },
      failed: (code?: string) => {
        if (disposed) return false;
        if (pending) return true;
        clear();
        if (!enabled || code !== "mediaBrokerDisconnected") return false;
        const now = Date.now();
        this.brokerFailures = this.brokerFailures.filter(t => now - t < 60_000);
        if (this.brokerFailures.length >= 2) return false;
        this.brokerFailures.push(now); recover("broker"); return true;
      },
      dispose: () => { disposed = true; clear(); },
    };
  }
}
