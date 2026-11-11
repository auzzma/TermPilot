//! Exercise the shipped process, whose TLS provider cannot be primed by another test.
use serde_json::json;
use std::{process::Stdio, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    process::Command,
};

#[tokio::test]
async fn socks5_tunnel_reaches_tls_handshake_in_standalone_engine() {
    let proxy = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = proxy.local_addr().unwrap().port();
    let mut child = Command::new(env!("CARGO_BIN_EXE_termpilot-rdp"))
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    input
        .write_all(
            format!(
                "{}\n",
                json!({
                    "kind":"connect", "host":"rdp.fixture.invalid", "port":3389,
                    "username":"fixture", "password":"fixture-password", "audio":false,
                    "proxy":{"type":"socks5", "host":"127.0.0.1", "port":port}
                })
            )
            .as_bytes(),
        )
        .await
        .unwrap();
    let handshake = tokio::time::timeout(Duration::from_secs(15), async {
        let (mut socket, _) = proxy.accept().await?;
        let mut greeting = [0; 3];
        socket.read_exact(&mut greeting).await?;
        assert_eq!(greeting, [5, 1, 0]);
        socket.write_all(&[5, 0]).await?;
        let mut connect = [0; 5];
        socket.read_exact(&mut connect).await?;
        assert_eq!(&connect[..4], &[5, 1, 0, 3]);
        let mut host = vec![0; connect[4] as usize];
        socket.read_exact(&mut host).await?;
        assert_eq!(host, b"rdp.fixture.invalid");
        assert_eq!(socket.read_u16().await?, 3389);
        socket.write_all(&[5, 0, 0, 1, 127, 0, 0, 1, 0, 0]).await?;
        // RDP X.224 negotiate response selects HYBRID (CredSSP over TLS).
        assert_eq!(socket.read_u16().await?, 0x0300);
        let size = socket.read_u16().await?;
        let mut request = vec![0; size as usize - 4];
        socket.read_exact(&mut request).await?;
        socket
            .write_all(&[
                3, 0, 0, 19, 14, 0xd0, 0, 0, 0x12, 0x34, 0, 2, 0x0f, 8, 0, 2, 0, 0, 0,
            ])
            .await?;
        let mut tls = [0; 5];
        socket.read_exact(&mut tls).await?;
        assert_eq!(tls[0], 22, "TLS handshake record");
        assert_eq!(tls[1], 3, "TLS version");
        assert!(u16::from_be_bytes([tls[3], tls[4]]) > 0);
        Ok::<_, std::io::Error>(())
    })
    .await;
    // Close stdin as well: Tokio's blocking stdin reader must be released at shutdown.
    drop(input);
    let _ = child.kill().await;
    let output = child.wait_with_output().await.unwrap();
    assert!(
        matches!(handshake, Ok(Ok(()))),
        "TLS handshake failed: {handshake:?}\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
}
