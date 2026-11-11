//! Native-only credential input. Passwords never cross back into the WebView.
use parking_lot::{Condvar, Mutex};
use serde_json::{json, Value};
use std::time::{Duration, Instant};

pub const CANCELLED: &str = "已取消密码输入。";
pub const SENT: &str = "已输入密码并回车，请查看远端登录结果。";
const UNAVAILABLE: &str = "连接不可用，已停止输入密码。";
const TIMEOUT: &str = "密码输入超时，请检查远端输入框后再重试。";
struct Operation {
    id: String,
    cancelled: bool,
    pending: Option<String>,
}
#[derive(Default)]
pub struct LoginInput {
    operation: Mutex<Option<Operation>>,
    wake: Condvar,
}
impl LoginInput {
    pub fn begin(&self, id: &str) -> Result<(), String> {
        uuid::Uuid::parse_str(id).map_err(|_| "Invalid input request")?;
        let mut operation = self.operation.lock();
        if operation.is_some() { return Err("正在输入密码，请稍候。".into()); }
        *operation = Some(Operation { id: id.into(), cancelled: false, pending: None });
        Ok(())
    }
    pub fn busy(&self) -> bool { self.operation.lock().is_some() }
    pub fn cancel(&self, id: Option<&str>) {
        let mut operation = self.operation.lock();
        if let Some(op) = operation.as_mut().filter(|op| id.is_none_or(|id| id == op.id)) {
            op.cancelled = true;
            self.wake.notify_all();
        }
    }
    pub fn acknowledge(&self, request: &str) {
        if let Some(op) = self.operation.lock().as_mut().filter(|op| !op.cancelled && op.pending.as_deref() == Some(request)) {
            op.pending = None;
            self.wake.notify_all();
        }
    }
    pub fn run(&self, id: &str, password: Result<String, String>, available: impl Fn() -> bool,
               send: impl Fn(&Value) -> Result<(), String>, timeout: Duration) -> Result<String, String> {
        let result = (|| {
            let password = password?;
            if password.is_empty() { return Err("没有可用的远程桌面凭证，请修改主机或重新打开快速连接。".into()); }
            if password.chars().count() > 1024 || password.chars().any(|c| c.is_control() || matches!(c, '\u{2028}' | '\u{2029}')) {
                return Err("此密码无法自动输入，请在远端 Mac 手动输入。".into());
            }
            self.check(id, &available)?;
            send(&json!({"kind":"release"}))?;
            for key in password.chars().map(|c| if c as u32 <= 255 { c as u32 } else { c as u32 | 0x01000000 }).chain([0xff0d]) {
                self.check(id, &available)?;
                let request = uuid::Uuid::new_v4().to_string();
                {
                    let mut operation = self.operation.lock();
                    let op = operation.as_mut().filter(|op| op.id == id && !op.cancelled).ok_or(CANCELLED)?;
                    op.pending = Some(request.clone());
                }
                // Exactly one key pair in flight, including the final Return.
                send(&json!({"kind":"credentialKey","key":key,"requestID":request}))?;
                let deadline = Instant::now() + timeout;
                let mut operation = self.operation.lock();
                loop {
                    let op = operation.as_ref().filter(|op| op.id == id && !op.cancelled).ok_or(CANCELLED)?;
                    if !available() { return Err(UNAVAILABLE.into()); }
                    if op.pending.is_none() { break; }
                    if Instant::now() >= deadline { return Err(TIMEOUT.into()); }
                    self.wake.wait_for(&mut operation, deadline.saturating_duration_since(Instant::now()));
                }
            }
            Ok(SENT.into())
        })();
        let _ = send(&json!({"kind":"release"}));
        let mut operation = self.operation.lock();
        if operation.as_ref().is_some_and(|op| op.id == id) { *operation = None; }
        result
    }
    fn check(&self, id: &str, available: &impl Fn() -> bool) -> Result<(), String> {
        if !self.operation.lock().as_ref().is_some_and(|op| op.id == id && !op.cancelled) { return Err(CANCELLED.into()); }
        if !available() { return Err(UNAVAILABLE.into()); }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn id() -> String { uuid::Uuid::new_v4().to_string() }
    #[test]
    fn unicode_symbols_and_one_return_are_acknowledged_without_clipboard() {
        let input = LoginInput::default(); let operation = id(); input.begin(&operation).unwrap();
        assert!(input.begin(&id()).is_err());
        let commands = Mutex::new(Vec::new());
        let result = input.run(&operation, Ok("A!\"\\ 空🔑é".into()), || true, |command| {
            commands.lock().push(command.clone());
            if let Some(request) = command["requestID"].as_str() { input.acknowledge(request); }
            Ok(())
        }, Duration::from_millis(100));
        assert_eq!(result.unwrap(), SENT); assert!(!input.busy());
        let expected = [65, 33, 34, 92, 32, 0x01007a7a, 0x0101f511, 233, 0xff0d];
        let commands = commands.lock();
        assert_eq!(commands.iter().filter_map(|v| v["key"].as_u64()).collect::<Vec<_>>(), expected);
        assert!(commands.iter().all(|v| v["kind"] == "credentialKey" || v["kind"] == "release"));
    }
    #[test]
    fn cancellation_and_stale_ack_do_not_send_remaining_password_or_return() {
        let input = LoginInput::default(); let operation = id(); input.begin(&operation).unwrap();
        let sent = Mutex::new(Vec::new());
        let result = input.run(&operation, Ok("secret".into()), || true, |command| {
            if command["kind"] == "credentialKey" {
                sent.lock().push(command.clone());
                input.cancel(Some("stale-operation")); assert!(input.busy());
                input.cancel(Some(&operation)); input.acknowledge(command["requestID"].as_str().unwrap());
            } Ok(())
        }, Duration::from_millis(50));
        assert_eq!(result.unwrap_err(), CANCELLED); assert_eq!(sent.lock().len(), 1);
        let next = id(); input.begin(&next).unwrap();
        assert_eq!(input.run(&next, Ok("ab".into()), || true, |command| {
            if command["kind"] == "credentialKey" { input.acknowledge(sent.lock()[0]["requestID"].as_str().unwrap()); }
            Ok(())
        }, Duration::from_millis(10)).unwrap_err(), TIMEOUT);
    }
    #[test]
    fn invalid_missing_and_disconnected_inputs_never_submit() {
        let input = LoginInput::default();
        for password in [Ok("".into()), Ok("a\nb".into()), Ok("a\u{2028}b".into()), Ok("a".repeat(1025)), Err("Credential deleted".into())] {
            let op = id(); input.begin(&op).unwrap();
            assert!(input.run(&op, password, || true, |c| { assert_eq!(c["kind"], "release"); Ok(()) }, Duration::from_millis(10)).is_err());
        }
        let op = id(); input.begin(&op).unwrap();
        assert_eq!(input.run(&op, Ok("ok".into()), || false, |c| { assert_eq!(c["kind"], "release"); Ok(()) }, Duration::from_millis(10)).unwrap_err(), UNAVAILABLE);
    }
}
