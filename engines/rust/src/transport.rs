//! Proxy policies are shared by SSH and RFB. Failures never fall back to direct TCP.
use crate::ipc::{shell_quote, text};
use anyhow::{bail, ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::Value;
use std::{
    pin::Pin,
    process::Stdio,
    task::{Context as TaskContext, Poll},
    time::Duration,
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf},
    net::TcpStream,
    process::{Child, ChildStdin, ChildStdout, Command},
};

pub trait Duplex: AsyncRead + AsyncWrite + Unpin + Send + Sync {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send + Sync> Duplex for T {}
pub type Stream = Box<dyn Duplex>;
struct CommandStream {
    input: ChildStdin,
    output: ChildStdout,
    child: Child,
}
impl AsyncRead for CommandStream {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.output).poll_read(cx, buf)
    }
}
impl AsyncWrite for CommandStream {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        data: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.input).poll_write(cx, data)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.input).poll_flush(cx)
    }
    fn poll_shutdown(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.input).poll_shutdown(cx)
    }
}
impl Drop for CommandStream {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}
pub fn validate_target(host: &str, port: u16) -> Result<()> {
    ensure!(
        !host.is_empty()
            && host.len() <= 1024
            && !host.chars().any(|c| c.is_whitespace() || c.is_control())
            && port > 0,
        "Invalid endpoint"
    );
    Ok(())
}
pub async fn connect(host: &str, port: u16, proxy: &Value) -> Result<Stream> {
    validate_target(host, port)?;
    tokio::time::timeout(Duration::from_secs(20), connect_inner(host, port, proxy))
        .await
        .context("Connection timed out")?
}
async fn connect_inner(host: &str, port: u16, proxy: &Value) -> Result<Stream> {
    if proxy.is_null() {
        let s = TcpStream::connect((host, port))
            .await
            .map_err(|error| anyhow::anyhow!("Cannot connect to server {host}:{port}: {error}"))?;
        s.set_nodelay(true)?;
        return Ok(Box::new(s));
    }
    let kind = proxy["kind"]
        .as_str()
        .or(proxy["type"].as_str())
        .context("Proxy type required")?;
    if kind == "command" || kind == "proxyCommand" {
        let template = text(proxy, "command");
        ensure!(
            !template.is_empty() && !template.contains('\0'),
            "ProxyCommand required"
        );
        let mut command = String::new();
        let mut chars = template.chars();
        while let Some(c) = chars.next() {
            if c == '%' {
                match chars.next() {
                    Some('h') => command.push_str(&proxy_host_quote(host)?),
                    Some('p') => command.push_str(&port.to_string()),
                    Some('%') => command.push('%'),
                    Some(c) => {
                        command.push('%');
                        command.push(c)
                    }
                    None => command.push('%'),
                }
            } else {
                command.push(c);
            }
        }
        #[cfg(unix)]
        let mut process = {
            let mut p = Command::new("/bin/sh");
            p.args(["-c", &command]);
            p
        };
        #[cfg(windows)]
        let mut process = {
            let mut p = Command::new("cmd.exe");
            p.args(["/D", "/S", "/C", &command]);
            p
        };
        let mut child = process
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()?;
        return Ok(Box::new(CommandStream {
            input: child.stdin.take().context("Proxy input")?,
            output: child.stdout.take().context("Proxy output")?,
            child,
        }));
    }
    let proxy_host = text(proxy, "host");
    let proxy_port = proxy["port"]
        .as_u64()
        .filter(|p| (1..=65535).contains(p))
        .context("Proxy port")? as u16;
    validate_target(proxy_host, proxy_port)?;
    let mut stream = TcpStream::connect((proxy_host, proxy_port)).await.map_err(|error| {
        anyhow::anyhow!("Cannot connect to proxy {proxy_host}:{proxy_port} for server {host}:{port}: {error}")
    })?;
    stream.set_nodelay(true)?;
    let username = text(proxy, "username");
    let password = text(proxy, "password");
    match kind {
        "http" | "httpConnect" => {
            let address = if host.contains(':') {
                format!("[{host}]:{port}")
            } else {
                format!("{host}:{port}")
            };
            let auth = if !username.is_empty() || !password.is_empty() {
                format!(
                    "Proxy-Authorization: Basic {}\r\n",
                    STANDARD.encode(format!("{username}:{password}"))
                )
            } else {
                String::new()
            };
            stream
                .write_all(
                    format!("CONNECT {address} HTTP/1.1\r\nHost: {address}\r\n{auth}\r\n")
                        .as_bytes(),
                )
                .await?;
            let mut header = Vec::new();
            while !header.ends_with(b"\r\n\r\n") {
                ensure!(header.len() < 16384, "Proxy response too large");
                header.push(stream.read_u8().await?);
            }
            ensure!(
                std::str::from_utf8(&header)?
                    .lines()
                    .next()
                    .unwrap_or("")
                    .split_whitespace()
                    .nth(1)
                    == Some("200"),
                "HTTP proxy rejected connection"
            );
        }
        "socks5" => {
            let authenticated = !username.is_empty() || !password.is_empty();
            let method = if authenticated { 2 } else { 0 };
            stream.write_all(&[5, 1, method]).await?;
            let mut reply = [0; 2];
            stream.read_exact(&mut reply).await?;
            ensure!(reply == [5, method], "SOCKS5 authentication unsupported");
            if authenticated {
                ensure!(
                    username.len() <= 255 && password.len() <= 255,
                    "SOCKS5 credential limit"
                );
                let mut auth = vec![1, username.len() as u8];
                auth.extend(username.as_bytes());
                auth.push(password.len() as u8);
                auth.extend(password.as_bytes());
                stream.write_all(&auth).await?;
                stream.read_exact(&mut reply).await?;
                ensure!(reply == [1, 0], "SOCKS5 credentials rejected");
            }
            ensure!(host.len() <= 255, "SOCKS5 hostname limit");
            let mut request = vec![5, 1, 0, 3, host.len() as u8];
            request.extend(host.as_bytes());
            request.extend(port.to_be_bytes());
            stream.write_all(&request).await?;
            let mut head = [0; 4];
            stream.read_exact(&mut head).await?;
            ensure!(head[..3] == [5, 0, 0], "SOCKS5 connection rejected");
            let length = match head[3] {
                1 => 4,
                4 => 16,
                3 => stream.read_u8().await? as usize,
                _ => bail!("SOCKS5 invalid address"),
            };
            let mut tail = vec![0; length + 2];
            stream.read_exact(&mut tail).await?;
        }
        _ => bail!("Unsupported proxy type"),
    }
    Ok(Box::new(stream))
}

fn proxy_host_quote(host: &str) -> Result<String> {
    #[cfg(unix)]
    {
        Ok(shell_quote(host))
    }
    #[cfg(windows)]
    {
        // cmd.exe expands percent/exclamation even inside quotes. Hostnames and
        // IP literals need none of its metacharacters; reject those before substitution.
        ensure!(
            host.bytes()
                .all(|c| c.is_ascii_alphanumeric() || b".-_:[]".contains(&c)),
            "Invalid ProxyCommand hostname"
        );
        Ok(format!("\"{host}\""))
    }
}
