//! A limited SSH server exposes leaked channels and temporary MaxSessions failures.
use russh::{server, Channel, ChannelId, ChannelOpenFailure};
use serde_json::{json, Value};
use std::{collections::HashSet, sync::{Arc, Mutex}, time::Duration};
use termpilot_engine::ssh::{Prompts, Session};
use tokio_util::sync::CancellationToken;

#[derive(Default)]
struct Observed {
    active: HashSet<ChannelId>,
    opens: usize,
    commands: Vec<String>,
}
struct LimitedServer {
    observed: Arc<Mutex<Observed>>,
    delay: Duration,
    refusal: Option<ChannelOpenFailure>,
}
impl server::Handler for LimitedServer {
    type Error = russh::Error;
    async fn auth_password(&mut self, _: &str, _: &str) -> Result<server::Auth, Self::Error> {
        Ok(server::Auth::Accept)
    }
    async fn channel_open_session(
        &mut self, channel: Channel<server::Msg>, reply: server::ChannelOpenHandle,
        _: &mut server::Session,
    ) -> Result<(), Self::Error> {
        let refusal = {
            let mut observed = self.observed.lock().unwrap();
            observed.opens += 1;
            self.refusal.clone().or_else(|| (!observed.active.is_empty()).then_some(ChannelOpenFailure::ConnectFailed))
        };
        if let Some(reason) = refusal {
            reply.reject(reason).await;
        } else {
            self.observed.lock().unwrap().active.insert(channel.id());
            // Delayed confirmation reproduces cancellation while channel_open_session awaits.
            tokio::time::sleep(self.delay).await;
            reply.accept().await;
        }
        Ok(())
    }
    async fn channel_close(&mut self, id: ChannelId, _: &mut server::Session) -> Result<(), Self::Error> {
        self.observed.lock().unwrap().active.remove(&id);
        Ok(())
    }
    async fn exec_request(&mut self, id: ChannelId, command: &[u8], session: &mut server::Session) -> Result<(), Self::Error> {
        let command = String::from_utf8_lossy(command).into_owned();
        self.observed.lock().unwrap().commands.push(command.clone());
        session.channel_success(id)?;
        if command != "hold" && !command.starts_with("sudo ") {
            let output = if command.contains("__TERMPILOT_OS__") {
                "__TERMPILOT_OS__Linux\n__TERMPILOT_USER__root\n"
            } else { "ok\n" };
            session.data(id, output.as_bytes())?;
            session.exit_status_request(id, if command == "fails" { 7 } else { 0 })?;
            session.eof(id)?;
            session.close(id)?;
            self.observed.lock().unwrap().active.remove(&id);
        }
        Ok(())
    }
}
struct Fixture {
    session: Arc<Session>,
    observed: Arc<Mutex<Observed>>,
    server: tokio::task::JoinHandle<()>,
    directory: std::path::PathBuf,
}
impl Fixture {
    async fn new(delay: Duration, refusal: Option<ChannelOpenFailure>) -> Self {
        let directory = std::env::temp_dir().join(format!("termpilot-channels-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let observed = Arc::new(Mutex::new(Observed::default()));
        let handler = LimitedServer { observed: observed.clone(), delay, refusal };
        let config = Arc::new(server::Config {
            keys: vec![russh::keys::PrivateKey::random(&mut rand10::rng(), russh::keys::Algorithm::Ed25519).unwrap()],
            auth_rejection_time: Duration::ZERO, ..Default::default()
        });
        let server = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let _ = server::run_stream(config, socket, handler).await.unwrap().await;
        });
        let (events, mut outbound) = tokio::sync::mpsc::channel(32);
        tokio::spawn(async move { while outbound.recv().await.is_some() {} });
        let session = Session::connect(json!({
            "hostname":"127.0.0.1", "port":port, "username":"cimp", "authentication":"password",
            "password":"fixture", "knownHostsFile":directory.join("known_hosts"), "autoAcceptHostKeys":true
        }), events, Prompts::default()).await.unwrap();
        Self { session, observed, server, directory }
    }
    async fn wait_for(&self, predicate: impl Fn(&Observed) -> bool) {
        tokio::time::timeout(Duration::from_secs(2), async {
            while !predicate(&self.observed.lock().unwrap()) {
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        }).await.expect("server did not observe expected channel cleanup");
    }
    fn hold(&self) -> tokio::task::JoinHandle<anyhow::Result<Value>> {
        let session = self.session.clone();
        tokio::spawn(async move { session.exec("hold", Duration::from_secs(10), &Value::Null).await })
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        self.session.cancel.cancel();
        self.server.abort();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}

#[tokio::test]
async fn aborting_directory_probe_releases_channel_for_system_overview() {
    let fix = Fixture::new(Duration::ZERO, None).await;
    for _ in 0..12 {
        let hold = fix.hold();
        fix.wait_for(|s| !s.commands.is_empty()).await;
        hold.abort();
        let _ = hold.await;
        fix.wait_for(|s| s.active.is_empty()).await;
        fix.observed.lock().unwrap().commands.clear();
    }
    let info = fix.session.monitor.info(&fix.session, &CancellationToken::new()).await.unwrap();
    assert_eq!(info["platform"], "linux");
    assert_eq!(info["username"], "root");
}

#[tokio::test]
async fn cancelled_channel_open_closes_late_confirmation() {
    let fix = Fixture::new(Duration::from_millis(150), None).await;
    let hold = fix.hold();
    fix.wait_for(|s| s.opens == 1).await;
    hold.abort();
    let _ = hold.await;
    fix.wait_for(|s| s.active.is_empty()).await;
    assert!(fix.observed.lock().unwrap().commands.is_empty());
}

#[tokio::test]
async fn temporary_channel_limit_recovers_without_replaying_command() {
    let fix = Fixture::new(Duration::ZERO, None).await;
    let held = fix.session.handle.channel_open_session().await.unwrap();
    let session = fix.session.clone();
    let command = tokio::spawn(async move { session.exec("once", Duration::from_secs(3), &Value::Null).await });
    fix.wait_for(|s| s.opens >= 2).await;
    held.close().await.unwrap();
    assert_eq!(command.await.unwrap().unwrap()["stdout"], "ok\n");
    assert_eq!(fix.observed.lock().unwrap().commands, ["once"]);
}

#[tokio::test]
async fn administrative_refusal_is_not_retried() {
    let fix = Fixture::new(Duration::ZERO, Some(ChannelOpenFailure::AdministrativelyProhibited)).await;
    let error = fix.session.exec("never", Duration::from_secs(3), &Value::Null).await.unwrap_err();
    assert!(error.to_string().contains("AdministrativelyProhibited"));
    let observed = fix.observed.lock().unwrap();
    assert_eq!(observed.opens, 1);
    assert!(observed.commands.is_empty());
}

#[tokio::test]
async fn persistent_channel_limit_has_actionable_error_and_bounded_retries() {
    let fix = Fixture::new(Duration::ZERO, Some(ChannelOpenFailure::ConnectFailed)).await;
    let error = fix.session.exec("never", Duration::from_secs(3), &Value::Null).await.unwrap_err();
    assert!(error.to_string().contains("MaxSessions"), "{error}");
    let observed = fix.observed.lock().unwrap();
    assert_eq!(observed.opens, 4);
    assert!(observed.commands.is_empty());
}

#[tokio::test]
async fn command_timeout_releases_channel() {
    let fix = Fixture::new(Duration::ZERO, None).await;
    let error = fix.session.exec("hold", Duration::from_millis(100), &Value::Null).await.unwrap_err();
    assert!(error.to_string().contains("timed out"));
    fix.wait_for(|s| s.active.is_empty()).await;
    assert_eq!(fix.session.exec("once", Duration::from_secs(2), &Value::Null).await.unwrap()["code"], 0);
}

#[tokio::test]
async fn remote_command_failure_is_never_replayed() {
    let fix = Fixture::new(Duration::ZERO, None).await;
    assert_eq!(fix.session.exec("fails", Duration::from_secs(2), &Value::Null).await.unwrap()["code"], 7);
    let observed = fix.observed.lock().unwrap();
    assert_eq!(observed.opens, 1);
    assert_eq!(observed.commands, ["fails"]);
}

#[tokio::test]
async fn cancelled_elevation_handshake_releases_channel() {
    let fix = Fixture::new(Duration::ZERO, None).await;
    let files = termpilot_engine::files::Files::open(fix.session.clone(), json!({"execOnly":true,"persistentElevation":true})).await.unwrap();
    let (events, mut outbound) = tokio::sync::mpsc::channel(32);
    tokio::spawn(async move { while outbound.recv().await.is_some() {} });
    let client = files.clone();
    let request = tokio::spawn(async move {
        client.request(json!({"id":1,"action":"exec","command":"once","elevated":true}), events, "exec".into()).await
    });
    fix.wait_for(|s| s.commands.iter().any(|c| c.starts_with("sudo "))).await;
    files.shutdown().await;
    assert!(request.await.unwrap().is_err());
    fix.wait_for(|s| s.active.is_empty()).await;
}

#[tokio::test]
async fn failed_elevated_sftp_setup_releases_reserved_channel() {
    let fix = Fixture::new(Duration::ZERO, None).await;
    let result = termpilot_engine::files::Files::open(fix.session.clone(), json!({"usesSudo":true})).await;
    assert!(result.is_err());
    fix.wait_for(|s| s.active.is_empty()).await;
}
