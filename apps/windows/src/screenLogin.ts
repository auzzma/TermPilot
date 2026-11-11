import { invoke } from "@tauri-apps/api/core";

type Operation = { sessionId: string; attemptId: string; requestId: string; cancelled: boolean; started: boolean };
export type ScreenLoginState = { busy: boolean; message: string };
// Only session/request identifiers cross IPC. Native code resolves the password.
export class ScreenLoginAction {
  available = () => false;
  prepare = async () => {};
  changed = (_state: ScreenLoginState) => {};
  private operation?: Operation;
  get busy() { return !!this.operation; }
  async start(sessionId: string, attemptId: string) {
    if (this.operation || !this.available()) return;
    const operation = { sessionId, attemptId, requestId: crypto.randomUUID(), cancelled: false, started: false };
    this.operation = operation;
    this.changed({busy:true,message:"正在输入密码…"});
    let message = "";
    try {
      await this.prepare();
      if (this.operation !== operation || operation.cancelled || !this.available()) throw Error("已取消密码输入。");
      operation.started = true;
      message = await invoke<string>("screen_enter_login_password", {sessionId,attemptId,requestId:operation.requestId});
    } catch (error) { message = error instanceof Error ? error.message : String(error); }
    finally {
      if (this.operation === operation) {
        this.operation = undefined;
        this.changed({busy:false,message:operation.cancelled ? "已取消密码输入。" : message});
      }
    }
  }
  cancel() {
    const operation = this.operation;
    if (!operation || operation.cancelled) return;
    operation.cancelled = true;
    this.changed({busy:true,message:"正在取消密码输入…"});
    if (operation.started) {
      const {sessionId,attemptId,requestId} = operation;
      void invoke("screen_cancel_login_password", {sessionId,attemptId,requestId}).catch(() => {});
    }
  }
  reset() { this.cancel(); this.operation = undefined; this.changed({busy:false,message:""}); }
}
