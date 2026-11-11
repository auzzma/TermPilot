import { getCurrentWindow } from '@tauri-apps/api/window';

/** One close handler owns migration protection and durable pending writes. */
export function protectSyncMigrationClose(isBusy: () => boolean, showProgress: () => void,
  persistence?: { dirty: () => boolean; flush: () => Promise<void>; failed: (error: unknown) => void }) {
  let flushing = false;
  return getCurrentWindow().onCloseRequested(event => {
    if (isBusy()) { event.preventDefault(); showProgress(); return; }
    if (flushing || persistence?.dirty()) {
      event.preventDefault();
      if (flushing) return;
      flushing = true;
      void persistence!.flush().then(async () => {
        if (isBusy()) { showProgress(); return; }
        await getCurrentWindow().destroy();
      }).catch(error => persistence!.failed(error)).finally(() => { flushing = false; });
    }
  });
}
