import { invoke } from "@tauri-apps/api/core";

// Serialize teardown/start per tab, including React effect remounts. Closing an
// attempt cannot close its successor; native close waits for helper exit.
const operations = new Map<string, Promise<unknown>>();
export function queueScreenOperation<T>(sessionId: string, operation: () => Promise<T>): Promise<T> {
  const result = (operations.get(sessionId) ?? Promise.resolve()).catch(() => {}).then(operation);
  operations.set(sessionId, result);
  void result.finally(() => { if (operations.get(sessionId) === result) operations.delete(sessionId); }).catch(() => {});
  return result;
}
export function screenAttempt(sessionId: string) {
  const attemptId = crypto.randomUUID();
  let cancelled = false;
  return {
    attemptId,
    get cancelled() { return cancelled; },
    start: (args: Record<string, unknown>) => queueScreenOperation(sessionId, async () => {
      if (cancelled) return;
      await invoke("screen_start", { ...args, sessionId, attemptId });
    }),
    close: () => {
      cancelled = true;
      return queueScreenOperation(sessionId, () => invoke<void>("screen_close", {sessionId, attemptId}));
    },
  };
}
export function screenConnectionError(event: { code?: string; message?: string }): string {
  return ({
    authenticationRejected: "认证失败，请检查已保存的账号、密码和屏幕共享权限。",
    serverProof: "服务器认证校验失败，请检查账号、密码和目标主机。",
    addressNotAvailable: "本机网络地址不可用，请检查网络或 VPN 后重试。",
    udpPortsInUse: "UDP 媒体端口（默认 5900/5901）已被其他程序占用，请关闭占用程序后重试。",
    busy: "旧版高性能连接仍占用媒体端口，请断开旧版连接后重试。",
    legacyScreenSessionActive: "旧版高性能连接仍占用媒体端口，请断开旧版连接后重试。",
    screenSessionAlreadyActive: "此远端 Mac 已有高性能连接，请使用已打开的会话。",
    mediaBrokerUnavailable: "无法启动共享媒体服务，请重新连接。",
    mediaBrokerDisconnected: "共享媒体服务已中断，请重新连接。",
    mediaBrokerVersion: "共享媒体服务版本不匹配，请退出旧版 TermPilot 后重试。",
    firstFrameTimeout: "未能收到远程画面，请检查远端屏幕共享与 UDP 网络后重新连接。",
    displayMode: "远端 Mac 未接受所选分辨率，请选择其他分辨率后重新连接。",
    vncProxyUnsupported: "高性能模式需要直连，暂不支持代理",
    highPerformanceProxyUnsupported: "高性能模式需要直连，暂不支持代理",
  } as Record<string, string>)[event.code ?? ""] ?? event.message ?? event.code ?? "连接失败";
}
