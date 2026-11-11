/** At most one update per display frame; flush preserves the final pointer position. */
export function frameCoalescer<T>(apply: (value: T) => void) {
  let frame: number | undefined;
  let pending: { value: T } | undefined;
  const flush = () => {
    if (frame !== undefined) cancelAnimationFrame(frame);
    frame = undefined;
    const item = pending; pending = undefined;
    if (item) apply(item.value);
  };
  return {
    schedule(value: T) { pending = { value }; if (frame === undefined) frame = requestAnimationFrame(flush); },
    flush,
    cancel() { if (frame !== undefined) cancelAnimationFrame(frame); frame = undefined; pending = undefined; },
  };
}

export function refreshInterval(value: number, fallback = 5) {
  return (Number.isFinite(value) ? Math.min(10, Math.max(1, value)) : fallback) * 1000;
}

/** Slow native calls cannot accumulate a queue of obsolete terminal sizes. */
export function latestAsync<T>(apply: (value: T) => Promise<unknown>, failed: () => void) {
  let pending: { value: T } | undefined;
  let running = false;
  let disposed = false;
  const drain = async () => {
    if (running) return;
    running = true;
    try {
      while (pending && !disposed) {
        const item = pending; pending = undefined;
        try { await apply(item.value); } catch { if (!disposed) failed(); }
      }
    } finally { running = false; }
  };
  return {
    submit(value: T) { if (disposed) return; pending = { value }; void drain(); },
    dispose() { disposed = true; pending = undefined; },
  };
}
