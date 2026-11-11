//! Shell job framing shared by native terminals on both platforms.
use crate::{model::text, Runtime};
use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};
use std::{collections::HashMap, sync::Arc, time::Duration};
use tokio::sync::{Mutex, Notify};
use tokio_util::sync::CancellationToken;

pub struct Job {
    pub conversation: String,
    pub session: String,
    marker: String,
    bytes: Vec<u8>,
    pending: Vec<u8>,
    truncated: bool,
    started: bool,
    pub status: String,
    code: Option<i32>,
}
#[derive(Default)]
pub struct Hub {
    jobs: Mutex<HashMap<String, Job>>,
    changed: Notify,
}
impl Hub {
    pub async fn reserve_script(&self, conversation: &str, session: &str) -> Result<String> {
        let mut jobs = self.jobs.lock().await;
        ensure!(
            !jobs.values().any(|j| j.session == session && active(j)),
            "This terminal already has an active AI command or script"
        );
        if jobs.len() >= 128 {
            jobs.retain(|_, j| active(j));
        }
        ensure!(jobs.len() < 128, "Too many terminal jobs");
        let id = uuid::Uuid::new_v4().to_string();
        jobs.insert(
            id.clone(),
            Job {
                conversation: conversation.into(),
                session: session.into(),
                marker: String::new(),
                bytes: vec![],
                pending: vec![],
                truncated: false,
                started: false,
                status: "script".into(),
                code: None,
            },
        );
        Ok(id)
    }
    pub async fn release_script(&self, id: &str) {
        if let Some(job) = self.jobs.lock().await.get_mut(id) {
            job.status = "completed".into();
        }
        self.changed.notify_waiters();
    }
    pub async fn reconcile(&self, context: &Value) {
        let sessions = context["sessions"].as_array().cloned().unwrap_or_default();
        for job in self.jobs.lock().await.values_mut() {
            if active(job) && !sessions.iter().any(|s| s["sessionId"] == job.session) {
                job.status = "disconnected".into();
            }
        }
        self.changed.notify_waiters();
    }
    pub async fn cancel_conversation(&self, rt: &Arc<Runtime>, conversation: &str) {
        let ids: Vec<String> = self
            .jobs
            .lock()
            .await
            .iter()
            .filter(|(_, j)| j.conversation == conversation && j.status == "running")
            .map(|(id, _)| id.clone())
            .collect();
        for id in ids {
            let _ = self.interrupt(rt, conversation, &id, &rt.lifetime).await;
        }
    }
    async fn interrupt(
        &self,
        rt: &Arc<Runtime>,
        conversation: &str,
        id: &str,
        cancel: &CancellationToken,
    ) -> Result<Value> {
        let session = {
            let mut jobs = self.jobs.lock().await;
            let j = jobs
                .get_mut(id)
                .filter(|j| j.conversation == conversation)
                .context("Job is not owned by this conversation")?;
            ensure!(j.status == "running", "Job is not running");
            j.status = "interruptRequested".into();
            j.session.clone()
        };
        let value = rt
            .ask(
                conversation,
                "toolRequest",
                json!({"name":"terminal_write","arguments":{"sessionId":session,"text":"\u{3}"}}),
                cancel,
            )
            .await;
        // Sending Ctrl-C is not proof of process exit. Retain the active slot until
        // the completion marker arrives or this connection instance disappears.
        ensure!(
            value.as_ref().is_ok_and(|v| v["ok"] == true),
            "Unable to confirm terminal interrupt delivery; check terminal state"
        );
        self.changed.notify_waiters();
        self.snapshot(conversation, id, 0).await
    }
    pub async fn feed(&self, session: &str, bytes: &[u8]) {
        for job in self
            .jobs
            .lock()
            .await
            .values_mut()
            .filter(|j| j.session == session && active(j) && j.status != "script")
        {
            job.pending.extend(bytes);
            let begin = format!("\x1e{}:BEGIN\x1f", job.marker);
            if !job.started {
                if let Some(n) = find(&job.pending, begin.as_bytes()) {
                    job.pending.drain(..n + begin.len());
                    job.started = true;
                } else {
                    let n = job.pending.len().saturating_sub(begin.len());
                    job.pending.drain(..n);
                    continue;
                }
            }
            let end = format!("\x1e{}:END:", job.marker);
            if let Some(n) = find(&job.pending, end.as_bytes()) {
                if let Some(k) = job.pending[n + end.len()..].iter().position(|b| *b == 31) {
                    let tail = &job.pending[n + end.len()..n + end.len() + k];
                    job.code = std::str::from_utf8(tail).ok().and_then(|s| s.parse().ok());
                    append_output(job, n);
                    job.pending.clear();
                    job.status = if job.status == "interruptRequested" {
                        "interrupted"
                    } else {
                        "completed"
                    }
                    .into();
                }
            }
            if active(job) {
                // Keep only enough look-behind to recognize a split exit marker.
                let n = job.pending.len().saturating_sub(end.len() + 16);
                append_output(job, n);
            }
        }
        self.changed.notify_waiters();
    }
    pub async fn snapshot(&self, conversation: &str, id: &str, offset: usize) -> Result<Value> {
        let jobs = self.jobs.lock().await;
        let j = jobs
            .get(id)
            .filter(|j| j.conversation == conversation)
            .context("Job is not owned by this conversation")?;
        let mut bytes = j.bytes.as_slice();
        if let Err(e) = std::str::from_utf8(bytes) {
            if e.error_len().is_none() {
                bytes = &bytes[..e.valid_up_to()];
            }
        }
        let chars: Vec<char> = String::from_utf8_lossy(bytes).chars().collect();
        ensure!(offset <= chars.len(), "Job output offset is out of range");
        let end = (offset + 24000).min(chars.len());
        Ok(
            json!({"jobId":id,"sessionId":j.session,"status":j.status,"exitCode":j.code,"output":chars[offset..end].iter().collect::<String>(),"nextOffset":end,"totalChars":chars.len(),"truncated":j.truncated}),
        )
    }
    pub async fn operate(
        &self,
        rt: &Arc<Runtime>,
        conversation: &str,
        name: &str,
        args: &Value,
        cancel: &CancellationToken,
    ) -> Result<Value> {
        if name == "terminal_poll" {
            return self
                .snapshot(
                    conversation,
                    text(args, "jobId"),
                    args["offset"].as_u64().unwrap_or(0) as usize,
                )
                .await;
        }
        if name == "terminal_stop" {
            return self
                .interrupt(rt, conversation, text(args, "jobId"), cancel)
                .await;
        }
        let session = text(args, "sessionId");
        let id = uuid::Uuid::new_v4().to_string();
        let marker = uuid::Uuid::new_v4().simple().to_string();
        {
            let mut jobs = self.jobs.lock().await;
            ensure!(
                !jobs.values().any(|j| j.session == session && active(j)),
                "This terminal already has an active AI command"
            );
            if jobs.len() >= 128 {
                jobs.retain(|_, j| active(j));
            }
            ensure!(jobs.len() < 128, "Too many active terminal jobs");
            jobs.insert(
                id.clone(),
                Job {
                    conversation: conversation.into(),
                    session: session.into(),
                    marker: marker.clone(),
                    bytes: vec![],
                    pending: vec![],
                    truncated: false,
                    started: false,
                    status: "running".into(),
                    code: None,
                },
            );
        }
        // Control characters appear only in shell output, never in the echoed command.
        let command=format!("( printf '\\036{marker}:BEGIN\\037'; (\n{}\n); __termpilot_ai_status=$?; printf '\\036{marker}:END:%s\\037' \"$__termpilot_ai_status\" )\r",text(args,"command"));
        let sent = rt
            .ask(
                conversation,
                "toolRequest",
                json!({"name":"terminal_write","arguments":{"sessionId":session,"text":command}}),
                cancel,
            )
            .await;
        if !sent.as_ref().is_ok_and(|v| v["ok"] == true) {
            // Delivery can have happened before its acknowledgment was lost.
            // Keep the terminal reserved until interruption or disconnection.
            return Err(anyhow::anyhow!(
                "Terminal command delivery failed; check terminal state"
            ));
        }
        // Both foreground and background commands obey the same configured
        // deadline. An interrupt request is never reported as proof of exit.
        let timeout = rt.settings.lock().await.command_timeout;
        let runtime = rt.clone();
        let job_id = id.clone();
        let owner = conversation.to_owned();
        tokio::spawn(async move {
            tokio::select! {
                _ = runtime.lifetime.cancelled() => {},
                _ = tokio::time::sleep(Duration::from_secs(timeout)) => {
                    if runtime.terminal.snapshot(&owner, &job_id, 0).await.is_ok_and(|s| s["status"] == "running") {
                        let _ = runtime.terminal.interrupt(&runtime, &owner, &job_id, &runtime.lifetime).await;
                        let _ = runtime.emit(json!({"type":"commandTimeout","jobId":job_id,"message":"命令超过配置时限，已请求中断；请核实远端退出状态。"}), &owner).await;
                    }
                }
            }
        });
        if name == "terminal_start" {
            return self.snapshot(conversation, &id, 0).await;
        }
        let wait = async {
            loop {
                let notified = self.changed.notified();
                tokio::pin!(notified);
                notified.as_mut().enable();
                let s = self.snapshot(conversation, &id, 0).await?;
                if s["status"] != "running" {
                    return Ok(s);
                }
                tokio::select! {_=cancel.cancelled()=>return Err(anyhow::anyhow!("Cancelled; terminal job may still be running")),_=notified=>{}}
            }
        };
        match tokio::time::timeout(Duration::from_secs(60), wait).await {
            Ok(r) => r,
            Err(_) => Ok(
                json!({"jobId":id,"status":"running","message":"Command exceeded the synchronous wait; use terminal_poll or terminal_stop."}),
            ),
        }
    }
}
fn active(job: &Job) -> bool {
    matches!(
        job.status.as_str(),
        "running" | "interruptRequested" | "script"
    )
}
fn append_output(job: &mut Job, n: usize) {
    let take = n.min((1024 * 1024usize).saturating_sub(job.bytes.len()));
    job.bytes.extend_from_slice(&job.pending[..take]);
    job.truncated |= take < n;
    job.pending.drain(..n);
}
fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|x| x == needle)
}

#[cfg(test)]
mod tests {
    use super::*;
    async fn fixture() -> Hub {
        let hub = Hub::default();
        hub.jobs.lock().await.insert(
            "job".into(),
            Job {
                conversation: "chat".into(),
                session: "terminal".into(),
                marker: "marker".into(),
                bytes: vec![],
                pending: vec![],
                truncated: false,
                started: false,
                status: "running".into(),
                code: None,
            },
        );
        hub
    }
    #[tokio::test]
    async fn split_markers_and_unicode_preserve_output_and_exit_status() {
        let h = fixture().await;
        let output =
            "echoed command\r\n\x1emarker:BEGIN\x1f中文✅\x1emarker:END:7\x1fignored prompt";
        for b in output.as_bytes() {
            h.feed("terminal", &[*b]).await;
        }
        let s = h.snapshot("chat", "job", 0).await.unwrap();
        assert_eq!(s["output"], "中文✅");
        assert_eq!(s["exitCode"], 7);
        assert_eq!(s["status"], "completed");
        assert!(h.snapshot("other", "job", 0).await.is_err());
    }
    #[tokio::test]
    async fn huge_output_keeps_job_active_and_recognizes_later_completion() {
        let h = fixture().await;
        h.feed("terminal", b"\x1emarker:BEGIN\x1f").await;
        for _ in 0..1100 {
            h.feed("terminal", &[b'x'; 1024]).await;
        }
        let s = h.snapshot("chat", "job", 0).await.unwrap();
        assert_eq!(s["status"], "running");
        assert_eq!(s["truncated"], true);
        h.feed("terminal", b"\x1emarker:END:0\x1f").await;
        let s = h.snapshot("chat", "job", 0).await.unwrap();
        assert_eq!(s["status"], "completed");
        assert_eq!(s["totalChars"], 1024 * 1024);
    }
    #[tokio::test]
    async fn reconnection_does_not_move_a_job_to_the_new_terminal() {
        let h = fixture().await;
        h.reconcile(&json!({"sessions":[{"sessionId":"new-terminal"}]}))
            .await;
        assert_eq!(
            h.snapshot("chat", "job", 0).await.unwrap()["status"],
            "disconnected"
        );
    }
}
