import { afterEach, describe, expect, it, vi } from 'vitest';
import { readFileSync } from 'node:fs';
import { webcrypto } from 'node:crypto';
import { clearMocks, mockIPC, mockWindows } from '@tauri-apps/api/mocks';
import { emit, TauriEvent } from '@tauri-apps/api/event';
import { protectSyncMigrationClose } from './syncWindowClose';

afterEach(() => { clearMocks(); vi.unstubAllGlobals(); });

describe('native window close with the sync migration guard', () => {
  it.each(['main', 'terminal-fixture'])('allows normal close, blocks migration, and allows closing after completion (%s)', async label => {
    vi.stubGlobal('window', { crypto: webcrypto });
    const capability = JSON.parse(readFileSync(new URL('../src-tauri/capabilities/default.json', import.meta.url), 'utf8'));
    const destroy = vi.fn();
    mockIPC(command => {
      if (command === 'plugin:window|destroy') {
        // Exercise the real SDK onCloseRequested path against our packaged ACL.
        expect(capability.permissions).toContain('core:window:allow-destroy');
        destroy();
      }
    }, { shouldMockEvents: true });
    mockWindows(label);
    let busy = false;
    const showProgress = vi.fn();
    const unlisten = await protectSyncMigrationClose(() => busy, showProgress);
    await emit(TauriEvent.WINDOW_CLOSE_REQUESTED);
    await vi.waitFor(() => expect(destroy).toHaveBeenCalledTimes(1));
    busy = true;
    await emit(TauriEvent.WINDOW_CLOSE_REQUESTED);
    await Promise.resolve();
    expect(destroy).toHaveBeenCalledTimes(1);
    expect(showProgress).toHaveBeenCalledTimes(1);
    busy = false;
    await emit(TauriEvent.WINDOW_CLOSE_REQUESTED);
    await vi.waitFor(() => expect(destroy).toHaveBeenCalledTimes(2));
    unlisten();
  });
});

describe('pending writes on native close', () => {
  it('flushes before destruction and keeps the window open after a save failure', async () => {
    vi.stubGlobal('window', { crypto: webcrypto });
    const destroy = vi.fn();
    mockIPC(command => { if (command === 'plugin:window|destroy') destroy(); }, {shouldMockEvents:true});
    mockWindows('main');
    let finish!:()=>void;
    const flush=vi.fn().mockImplementationOnce(()=>new Promise<void>(r=>finish=r)).mockRejectedValueOnce(Error('disk full'));
    const failed=vi.fn();
    const off=await protectSyncMigrationClose(()=>false,vi.fn(),{dirty:()=>true,flush,failed});
    await emit(TauriEvent.WINDOW_CLOSE_REQUESTED);
    await vi.waitFor(()=>expect(flush).toHaveBeenCalledTimes(1));expect(destroy).not.toHaveBeenCalled();
    finish();await vi.waitFor(()=>expect(destroy).toHaveBeenCalledTimes(1));
    await emit(TauriEvent.WINDOW_CLOSE_REQUESTED);
    await vi.waitFor(()=>expect(failed).toHaveBeenCalledTimes(1));expect(destroy).toHaveBeenCalledTimes(1);off();
  });
});
