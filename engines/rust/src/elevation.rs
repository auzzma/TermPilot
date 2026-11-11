//! A bounded, serial root-shell session. Commands run in subshells so `exit`,
//! `cd`, and shell options cannot damage the next request. No command is retried.
use crate::{
    ipc::{shell_quote, text},
    ssh::{Handler, SessionChannel},
};
use anyhow::{bail, ensure, Context, Result};
use russh::{client, Channel, ChannelMsg, Pty};
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};
use tokio::sync::{mpsc, oneshot};
use tokio_util::sync::CancellationToken;
use zeroize::Zeroizing;

pub struct RootShell {
    pub identity: [u8; 32],
    commands: mpsc::Sender<Request>,
    cancel: CancellationToken,
}
struct Request {
    command: String,
    deadline: tokio::time::Instant,
    cancel: CancellationToken,
    reply: oneshot::Sender<Result<Value>>,
}
impl Drop for RootShell {
    fn drop(&mut self) {
        self.cancel.cancel();
    }
}
impl RootShell {
    pub fn identity(options: &Value) -> [u8; 32] {
        use sha2::{Digest, Sha256};
        Sha256::digest(format!(
            "{}\0{}",
            text(options, "elevationMethod"),
            text(options, "elevationPassword")
        ))
        .into()
    }
    pub fn new(
        handle: Arc<client::Handle<Handler>>,
        options: &Value,
        stop: &CancellationToken,
    ) -> Self {
        let identity = Self::identity(options);
        let password = Zeroizing::new(text(options, "elevationPassword").to_string());
        let su = text(options, "elevationMethod") == "su";
        let cancel = stop.child_token();
        let task_cancel = cancel.clone();
        let (commands, mut incoming) = mpsc::channel::<Request>(32);
        tokio::spawn(async move {
            let mut channel = None;
            loop {
                let request = tokio::select! {
                    _ = task_cancel.cancelled() => break,
                    item = tokio::time::timeout(Duration::from_secs(60), incoming.recv()) => match item {
                        Ok(Some(item)) => item,
                        Ok(None) => break,
                        Err(_) => { close(&mut channel).await; continue; }
                    }
                };
                if request.cancel.is_cancelled() || request.reply.is_closed() {
                    continue;
                }
                let work = async {
                    if channel.is_none() {
                        channel = Some(open(&handle, &password, su).await?);
                    }
                    execute(channel.as_mut().unwrap(), &request.command, su).await
                };
                let result = tokio::select! {
                    _ = task_cancel.cancelled() => Err(anyhow::anyhow!("Root session closed")),
                    _ = request.cancel.cancelled() => Err(anyhow::anyhow!("Command cancelled")),
                    value = tokio::time::timeout_at(request.deadline, work) => value.unwrap_or_else(|_| Err(anyhow::anyhow!("Remote command timed out"))),
                };
                if result.is_err() {
                    close(&mut channel).await;
                }
                let _ = request.reply.send(result);
            }
            close(&mut channel).await;
            // Dropping queued replies wakes every caller, including queued cancellations.
        });
        Self {
            identity,
            commands,
            cancel,
        }
    }
    pub fn submit(
        &self,
        command: &str,
        timeout: Duration,
        cancel: &CancellationToken,
    ) -> Result<oneshot::Receiver<Result<Value>>> {
        let (reply, receive) = oneshot::channel();
        self.commands
            .try_send(Request {
                command: command.into(),
                deadline: tokio::time::Instant::now() + timeout,
                cancel: cancel.clone(),
                reply,
            })
            .map_err(|_| anyhow::anyhow!("Root command queue is full or closed"))?;
        Ok(receive)
    }
}
async fn close(channel: &mut Option<SessionChannel>) {
    if let Some(mut channel) = channel.take() {
        let _ = tokio::time::timeout(Duration::from_secs(2), channel.close()).await;
    }
}
pub fn password_prompt(bytes: &[u8]) -> bool {
    let lower = String::from_utf8_lossy(bytes).to_lowercase();
    [
        "__termpilot_password__",
        "password",
        "passwort",
        "mot de passe",
        "contraseña",
        "senha",
        "密码",
        "口令",
    ]
    .iter()
    .any(|p| lower.contains(p))
}
async fn open(
    handle: &Arc<client::Handle<Handler>>,
    password: &str,
    su: bool,
) -> Result<SessionChannel> {
    let mut channel = SessionChannel::open(handle.clone()).await?;
    let result = tokio::time::timeout(Duration::from_secs(25), async {
        if su {
            channel
                .request_pty(
                    true,
                    "dumb",
                    80,
                    24,
                    0,
                    0,
                    &[(Pty::ECHO, 0), (Pty::ECHONL, 0), (Pty::OPOST, 0)],
                )
                .await?;
        }
        let marker = format!("__TERMPILOT_READY_{}__", uuid::Uuid::new_v4().simple());
        let script = shell_quote(&format!(
            "export PS1= PS2= ENV=; printf '%s' {}; exec sh",
            shell_quote(&marker)
        ));
        let command = if su {
            format!("su - root -c {script}")
        } else {
            format!("sudo -H -S -p '__TERMPILOT_PASSWORD__' sh -c {script}")
        };
        channel.exec(true, command).await?;
        let mut output = Vec::new();
        let mut errors = Vec::new();
        let mut sent = false;
        loop {
            match channel
                .wait()
                .await
                .context("Root shell closed before authentication")?
            {
                ChannelMsg::Data { data } => output.extend(&data),
                ChannelMsg::ExtendedData { data, .. } => errors.extend(&data),
                ChannelMsg::Close | ChannelMsg::ExitStatus { .. } => {
                    bail!("Root authentication failed")
                }
                _ => {}
            }
            ensure!(
                output.len() + errors.len() <= 65536,
                "Root handshake output limit"
            );
            if output.windows(marker.len()).any(|s| s == marker.as_bytes()) {
                return Ok::<_, anyhow::Error>(());
            }
            if password_prompt(&output) || password_prompt(&errors) {
                ensure!(!sent, "Root credentials rejected");
                let input = Zeroizing::new(format!("{password}\n"));
                channel.data(input.as_bytes()).await?;
                sent = true;
                output.clear();
                errors.clear();
            }
        }
    })
    .await;
    match result {
        Ok(Ok(())) => Ok(channel),
        failed => {
            let _ = tokio::time::timeout(Duration::from_secs(2), channel.close()).await;
            failed.context("Root authentication timed out")??;
            unreachable!()
        }
    }
}
async fn execute(channel: &mut Channel<client::Msg>, command: &str, pty: bool) -> Result<Value> {
    let marker = format!("\x1eTP{}:", uuid::Uuid::new_v4().simple());
    let escaped = marker.replace('\x1e', "\\036");
    let wrapper=format!("( eval {} ) </dev/null; _tp_status=$?; printf '{}%s\\037' \"$_tp_status\"; printf '{}done\\037' >&2\n",shell_quote(command),escaped,escaped);
    channel.data(wrapper.as_bytes()).await?;
    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    loop {
        match channel.wait().await.context("Root shell disconnected")? {
            ChannelMsg::Data { data } => stdout.extend(&data),
            ChannelMsg::ExtendedData { data, .. } => stderr.extend(&data),
            ChannelMsg::Close | ChannelMsg::ExitStatus { .. } => bail!("Root shell terminated"),
            _ => {}
        }
        ensure!(
            stdout.len() + stderr.len() <= 16 * 1024 * 1024,
            "Command output exceeds limit"
        );
        if let Some((position, code)) = status(&stdout, marker.as_bytes()) {
            let err = if pty {
                &stdout[position..]
            } else {
                &stderr[..]
            };
            let tail = format!("{marker}done\x1f");
            if let Some(end) = err.windows(tail.len()).position(|s| s == tail.as_bytes()) {
                let errors = if pty {
                    "".into()
                } else {
                    String::from_utf8_lossy(&err[..end]).into_owned()
                };
                return Ok(
                    json!({"stdout":String::from_utf8_lossy(&stdout[..position]),"stderr":errors,"code":code,"exitCode":code,"signal":null}),
                );
            }
        }
    }
}
fn status(bytes: &[u8], marker: &[u8]) -> Option<(usize, u32)> {
    let offset = bytes.windows(marker.len()).position(|s| s == marker)?;
    let tail = &bytes[offset + marker.len()..];
    let end = tail.iter().position(|b| *b == 0x1f)?;
    Some((
        offset,
        std::str::from_utf8(&tail[..end]).ok()?.parse().ok()?,
    ))
}
