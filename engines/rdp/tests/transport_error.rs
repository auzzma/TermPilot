use serde_json::{Value, json};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
};

#[tokio::test]
async fn failed_direct_and_proxy_connections_keep_endpoint_and_os_cause() {
    for proxied in [false, true] {
        let closed = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = closed.local_addr().unwrap().port();
        drop(closed);
        let (native, engine) = tokio::io::duplex(65536);
        let (read, write) = tokio::io::split(engine);
        let task = tokio::spawn(termpilot_rdp::serve(read, write));
        let (mut output, mut input) = tokio::io::split(native);
        let config = if proxied {
            json!({"kind":"connect","host":"rdp.fixture.invalid","port":3389,"username":"fixture",
                "proxy":{"type":"socks5","host":"127.0.0.1","port":port,"username":"secret-user","password":"secret-password"}})
        } else {
            json!({"kind":"connect","host":"127.0.0.1","port":port,"username":"fixture"})
        };
        input
            .write_all(format!("{config}\n").as_bytes())
            .await
            .unwrap();
        let message = tokio::time::timeout(std::time::Duration::from_secs(10), async {
            loop {
                let length = output.read_u32().await.unwrap() as usize;
                let mut bytes = vec![0; length];
                output.read_exact(&mut bytes).await.unwrap();
                let header: Value = serde_json::from_slice(&bytes).unwrap();
                let mut payload = vec![0; header["payloadLength"].as_u64().unwrap() as usize];
                output.read_exact(&mut payload).await.unwrap();
                if header["kind"] == "error" {
                    break header["message"].as_str().unwrap().to_owned();
                }
            }
        })
        .await
        .unwrap();
        assert!(message.contains(&format!("127.0.0.1:{port}")), "{message}");
        assert!(message.contains("os error"), "{message}");
        assert!(
            message.contains(if proxied {
                "Cannot connect to proxy"
            } else {
                "Cannot connect to server"
            }),
            "{message}"
        );
        assert!(!message.contains("secret-"));
        drop(input);
        tokio::time::timeout(std::time::Duration::from_secs(5), task)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
    }
}
