import { invoke } from "@tauri-apps/api/core";
import type { Host } from "./types";

export interface RemoteSystemInfo {
  platform: "windows" | "linux" | "macos" | "unix";
  username: string;
}

/** Scoped to the current SSH session; never infer the remote OS from the client OS. */
export function remoteSystemMonitor(host: Host, sourceSessionId: string) {
  let pendingInfo: Promise<RemoteSystemInfo> | undefined;
  function request<T>(request: Record<string, unknown>): Promise<T> {
    return invoke<T>("sftp_request", { host, sourceSessionId, request });
  }
  return {
    info(): Promise<RemoteSystemInfo> {
      pendingInfo ??= request<RemoteSystemInfo>({ action: "systemInfo" }).catch((error) => {
        pendingInfo = undefined;
        throw error;
      });
      return pendingInfo;
    },
    collect<T>(operation: "overview" | "processes" | "exec" | "terminate", parameters: Record<string, unknown> = {}) {
      return request<T>({ ...parameters, action: "systemMonitor", operation });
    },
  };
}
