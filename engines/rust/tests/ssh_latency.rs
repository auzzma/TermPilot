//! A shell that refuses exec still supports transport RTT; probes must never run commands.
use russh::{server, Channel, ChannelId, Pty};
use serde_json::{json, Value};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

struct Shell(Arc<Mutex<Vec<Vec<u8>>>>);
struct TestDirectory(std::path::PathBuf);
impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
impl server::Handler for Shell {
    type Error = russh::Error;
    async fn auth_password(&mut self, _: &str, _: &str) -> Result<server::Auth, Self::Error> {
        Ok(server::Auth::Accept)
    }
    async fn channel_open_session(
        &mut self,
        _: Channel<server::Msg>,
        reply: server::ChannelOpenHandle,
        _: &mut server::Session,
    ) -> Result<(), Self::Error> {
        reply.accept().await;
        Ok(())
    }
    async fn pty_request(
        &mut self,
        id: ChannelId,
        _: &str,
        _: u32,
        _: u32,
        _: u32,
        _: u32,
        _: &[(Pty, u32)],
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(id)?;
        Ok(())
    }
    async fn shell_request(
        &mut self,
        id: ChannelId,
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(id)?;
        Ok(())
    }
    async fn exec_request(
        &mut self,
        id: ChannelId,
        command: &[u8],
        session: &mut server::Session,
    ) -> Result<(), Self::Error> {
        self.0.lock().unwrap().push(command.to_vec());
        session.channel_failure(id)?;
        session.close(id)?;
        Ok(())
    }
}

#[tokio::test]
async fn terminal_emits_repeated_integer_rtt_without_remote_exec() {
    let directory = TestDirectory(
        std::env::temp_dir().join(format!("termpilot-latency-{}", uuid::Uuid::new_v4())),
    );
    std::fs::create_dir(&directory.0).unwrap();
    let socket = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = socket.local_addr().unwrap().port();
    let commands = Arc::new(Mutex::new(Vec::new()));
    let fixture = Shell(commands.clone());
    let config = Arc::new(server::Config {
        keys: vec![russh::keys::PrivateKey::random(
            &mut rand10::rng(),
            russh::keys::Algorithm::Ed25519,
        )
        .unwrap()],
        auth_rejection_time: Duration::ZERO,
        ..Default::default()
    });
    let server = tokio::spawn(async move {
        let (socket, _) = socket.accept().await.unwrap();
        server::run_stream(config, socket, fixture)
            .await
            .unwrap()
            .await
    });
    let (client, engine) = tokio::io::duplex(65536);
    let (read, write) = tokio::io::split(engine);
    let worker = tokio::spawn(termpilot_engine::worker::serve(read, write, None, None));
    let (read, mut write) = tokio::io::split(client);
    let mut lines = BufReader::new(read).lines();
    let first = json!({"type":"connect","config":{"hostname":"127.0.0.1","port":port,"username":"fixture","password":"fixture","authentication":"password","autoAcceptHostKeys":true,"knownHostsFile":directory.0.join("known_hosts")}});
    write
        .write_all(format!("{first}\n").as_bytes())
        .await
        .unwrap();
    let mut registration_commands = None;
    let samples = tokio::time::timeout(Duration::from_secs(15), async {
        let mut samples = vec![];
        while samples.len() < 2 {
            let line = lines
                .next_line()
                .await
                .unwrap()
                .expect("worker ended before RTT");
            let event: Value = serde_json::from_str(&line).unwrap();
            assert_ne!(event["type"], "error", "{event}");
            assert_ne!(event["status"], "latency-unavailable", "{event}");
            if event["status"] == "connected" {
                registration_commands = Some(commands.lock().unwrap().clone());
            }
            if event["status"] == "latency" {
                assert_eq!(event["channel"], "terminal");
                samples.push(event["message"].as_str().unwrap().parse::<u64>().unwrap());
            }
        }
        samples
    })
    .await;
    write.write_all(b"{\"type\":\"close\"}\n").await.unwrap();
    tokio::time::timeout(Duration::from_secs(5), worker)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    server.abort();
    assert_eq!(
        samples
            .expect("RTT must refresh without shell exec permission")
            .len(),
        2
    );
    let registration_commands = registration_commands.expect("terminal connected event");
    assert!(!registration_commands.is_empty() && registration_commands.len() <= 4);
    assert!(registration_commands
        .iter()
        .all(|command| command.starts_with(b"# termpilot-terminal-processes\n")));
    assert_eq!(
        *commands.lock().unwrap(),
        registration_commands,
        "RTT probes must not execute any commands after initial terminal registration"
    );
}
