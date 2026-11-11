import { useSyncExternalStore } from 'react';

const subscribe = (changed: () => void) => {
  document.addEventListener('visibilitychange', changed);
  return () => document.removeEventListener('visibilitychange', changed);
};
export function useWindowVisible() {
  return useSyncExternalStore(subscribe, () => document.visibilityState !== 'hidden', () => true);
}
