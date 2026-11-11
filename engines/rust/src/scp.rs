//! Legacy SCP data protocol and POSIX metadata operations. No remote Python,
//! Node, SFTP server, or platform-specific local executable is required.
use crate::{
    ipc::shell_quote,
    sftp::{Attributes, Status},
    ssh::Session,
};
use anyhow::{bail, ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::Value;
use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
pub struct Scp {
    pub session: Arc<Session>,
    gb: AtomicBool,
    auto: bool,
}
impl Scp {
    pub fn new(session: Arc<Session>, encoding: &str) -> Self {
        Self {
            session,
            gb: AtomicBool::new(encoding == "gb18030"),
            auto: encoding.is_empty() || encoding == "auto",
        }
    }
    pub fn path(&self, path: &str) -> Result<String> {
        ensure!(
            !path.is_empty() && !path.contains(['\0', '\r', '\n']) && path.len() <= 65536,
            "Invalid SCP path"
        );
        if self.gb.load(Ordering::Relaxed) {
            let (bytes, _, bad) = encoding_rs::GB18030.encode(path);
            ensure!(!bad, "Filename encoding error");
            let escapes = bytes
                .iter()
                .map(|b| format!("\\{:03o}", b))
                .collect::<String>();
            Ok(format!("\"$(printf '%b' {})\"", shell_quote(&escapes)))
        } else {
            Ok(shell_quote(path))
        }
    }
    pub fn decode(&self, bytes: &[u8]) -> Result<String> {
        if self.auto && std::str::from_utf8(bytes).is_err() {
            self.gb.store(true, Ordering::Relaxed);
        }
        if self.gb.load(Ordering::Relaxed) {
            let (text, _, bad) = encoding_rs::GB18030.decode(bytes);
            ensure!(!bad, "Invalid filename encoding");
            Ok(text.into_owned())
        } else {
            Ok(std::str::from_utf8(bytes)?.into())
        }
    }
    pub async fn command(&self, command: &str) -> Result<String> {
        let r = self
            .session
            .exec(
                &format!("sh -c {}", shell_quote(command)),
                Duration::from_secs(30),
                &Value::Null,
            )
            .await?;
        let code = r["exitCode"].as_u64().unwrap_or(1);
        if code == 2 {
            return Err(Status(2, "No such file".into()).into());
        }
        ensure!(
            code == 0,
            "Remote file operation failed: {}",
            r["stderr"].as_str().unwrap_or("")
        );
        Ok(r["stdout"].as_str().unwrap_or("").into())
    }
    pub async fn canonicalize(&self, path: &str) -> Result<String> {
        let p = self.path(path)?;
        let command=format!("realpath -- {p} 2>/dev/null || readlink -f -- {p} 2>/dev/null || (cd {p} && pwd -P) || (cd \"$(dirname -- {p})\" && printf '%s/%s\\n' \"$(pwd -P)\" \"$(basename -- {p})\")");
        Ok(self.command(&command).await?.trim_end().into())
    }
    pub async fn stat(&self, path: &str) -> Result<Attributes> {
        let p = self.path(path)?;
        let output = self
            .command(&format!(
                "p={p}; if [ ! -e \"$p\" ] && [ ! -L \"$p\" ]; then exit 2; fi; {}",
                metadata_script("$p")
            ))
            .await?;
        parse_record(output.trim_end())
    }
    pub async fn list(&self, path: &str) -> Result<Vec<(String, Attributes)>> {
        let p = self.path(path)?;
        let command=format!("cd {p} || exit 2\nfor f in * .[!.]* ..?*; do\n{{ [ -e \"$f\" ] || [ -L \"$f\" ]; }} || continue\n{}\nif command -v base64 >/dev/null 2>&1; then printf '%s' \"$f\" | base64 | tr -d '\\r\\n'; else printf '%s' \"$f\" | openssl base64 | tr -d '\\r\\n'; fi\nprintf '\\n'\ndone",metadata_script("$f").replace("\\n'", "|'"));
        let output = self.command(&command).await?;
        let mut entries = Vec::new();
        for line in output.lines() {
            let fields = line.split('|').collect::<Vec<_>>();
            ensure!(fields.len() == 5, "Invalid remote listing");
            let name = self.decode(&STANDARD.decode(fields[4])?)?;
            validate_name(&name)?;
            entries.push((name, parse_record(line)?));
            ensure!(entries.len() <= 100000, "Directory item limit");
        }
        Ok(entries)
    }
    pub async fn mkdir(&self, path: &str) -> Result<()> {
        self.command(&format!("mkdir -- {}", self.path(path)?))
            .await?;
        Ok(())
    }
    pub async fn remove(&self, path: &str, directory: bool) -> Result<()> {
        ensure!(
            path != "/" && path != "." && path != "..",
            "Refusing root deletion"
        );
        self.command(&format!(
            "{} -- {}",
            if directory { "rmdir" } else { "rm -f" },
            self.path(path)?
        ))
        .await?;
        Ok(())
    }
    pub async fn rename(&self, old: &str, new: &str, replace: bool) -> Result<()> {
        let a = self.path(old)?;
        let b = self.path(new)?;
        let command = if replace {
            format!("mv -f -- {a} {b}")
        } else {
            format!("if [ -e {b} ] || [ -L {b} ]; then exit 1; fi; mv -n -- {a} {b}; [ ! -e {a} ]")
        };
        self.command(&command).await?;
        Ok(())
    }
    pub async fn chmod(&self, path: &str, mode: u32) -> Result<()> {
        ensure!(mode <= 0o7777, "Invalid permissions");
        self.command(&format!("chmod -- {:o} {}", mode, self.path(path)?))
            .await?;
        Ok(())
    }
    pub async fn download_stream(
        &self,
        path: &str,
    ) -> Result<(russh::ChannelStream<russh::client::Msg>, u64, u32)> {
        let channel = self.session.open_session_channel().await?;
        channel
            .exec(true, format!("scp -f -- {}", self.path(path)?))
            .await?;
        let mut stream = channel.into_stream();
        stream.write_all(&[0]).await?;
        for _ in 0..4 {
            let line = read_line(&mut stream).await?;
            match line.first() {
                Some(b'T') => stream.write_all(&[0]).await?,
                Some(b'C') => {
                    let mut fields = line[1..line.len() - 1].splitn(3, |b| *b == b' ');
                    let mode = u32::from_str_radix(
                        std::str::from_utf8(fields.next().context("SCP mode")?)?,
                        8,
                    )?;
                    let size =
                        std::str::from_utf8(fields.next().context("SCP size")?)?.parse::<u64>()?;
                    let name = self.decode(fields.next().context("SCP filename")?)?;
                    validate_name(&name)?;
                    ensure!(
                        name == path.rsplit('/').next().unwrap_or(path),
                        "SCP server sent an unexpected filename"
                    );
                    stream.write_all(&[0]).await?;
                    return Ok((stream, size, mode));
                }
                Some(1) | Some(2) => bail!("Remote SCP rejected download"),
                _ => bail!("Invalid SCP file record"),
            }
        }
        bail!("Too many SCP time records")
    }
    pub async fn upload_stream(
        &self,
        path: &str,
        size: u64,
        mode: u32,
    ) -> Result<russh::ChannelStream<russh::client::Msg>> {
        let name = path.rsplit('/').next().context("SCP filename")?;
        validate_name(name)?;
        let channel = self.session.open_session_channel().await?;
        channel
            .exec(true, format!("scp -t -- {}", self.path(path)?))
            .await?;
        let mut stream = channel.into_stream();
        ack(&mut stream).await?;
        let mut header = format!("C{:04o} {size} ", mode & 0o7777).into_bytes();
        if self.gb.load(Ordering::Relaxed) {
            let (bytes, _, bad) = encoding_rs::GB18030.encode(name);
            ensure!(!bad, "Filename encoding error");
            header.extend_from_slice(&bytes);
        } else {
            header.extend_from_slice(name.as_bytes());
        }
        header.push(b'\n');
        stream.write_all(&header).await?;
        ack(&mut stream).await?;
        Ok(stream)
    }
}
pub fn validate_name(name: &str) -> Result<()> {
    ensure!(
        !name.is_empty()
            && name != "."
            && name != ".."
            && !name.contains(['/', '\\', '\0', '\n', '\r']),
        "Unsafe remote filename"
    );
    Ok(())
}
pub async fn ack<R: AsyncRead + Unpin>(read: &mut R) -> Result<()> {
    let status = read.read_u8().await?;
    ensure!(status == 0, "SCP peer rejected transfer");
    Ok(())
}
pub async fn finish_upload<S: AsyncRead + AsyncWrite + Unpin>(stream: &mut S) -> Result<()> {
    stream.write_all(&[0]).await?;
    ack(stream).await?;
    stream.shutdown().await?;
    Ok(())
}
pub async fn finish_download<S: AsyncRead + AsyncWrite + Unpin>(stream: &mut S) -> Result<()> {
    ack(stream).await?;
    stream.write_all(&[0]).await?;
    stream.shutdown().await?;
    Ok(())
}
async fn read_line<R: AsyncRead + Unpin>(read: &mut R) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    while bytes.last() != Some(&b'\n') {
        ensure!(bytes.len() < 65536, "SCP header limit");
        bytes.push(read.read_u8().await?);
    }
    Ok(bytes)
}
fn metadata_script(path: &str) -> String {
    format!(
        r#"if [ -L "{path}" ]; then t=l; elif [ -d "{path}" ]; then t=d; elif [ -f "{path}" ]; then t=f; else t=o; fi
mode=$(LC_ALL=C ls -ld -- "{path}" 2>/dev/null | awk '{{print $1}}')
size=$(stat -c %s -- "{path}" 2>/dev/null || stat -f %z -- "{path}" 2>/dev/null || echo 0)
mtime=$(stat -c %Y -- "{path}" 2>/dev/null || stat -f %m -- "{path}" 2>/dev/null || echo 0)
printf '%s|%s|%s|%s\n' "$t" "$mode" "$size" "$mtime""#
    )
}
fn parse_record(record: &str) -> Result<Attributes> {
    let fields = record.split('|').collect::<Vec<_>>();
    ensure!(fields.len() >= 4, "Invalid remote metadata");
    let mut mode = match fields[0] {
        "f" => 0o100000,
        "d" => 0o040000,
        "l" => 0o120000,
        _ => 0,
    };
    let permissions = fields[1].as_bytes();
    ensure!(permissions.len() >= 10, "Remote permissions unavailable");
    for (i, c) in permissions[1..10].iter().enumerate() {
        if matches!(c, b'r' | b'w' | b'x' | b's' | b't') {
            mode |= 1 << (8 - i);
        }
    }
    if matches!(permissions[3], b's' | b'S') {
        mode |= 0o4000;
    }
    if matches!(permissions[6], b's' | b'S') {
        mode |= 0o2000;
    }
    if matches!(permissions[9], b't' | b'T') {
        mode |= 0o1000;
    }
    Ok(Attributes {
        size: Some(fields[2].parse()?),
        permissions: Some(mode),
        mtime: Some(fields[3].parse()?),
        ..Default::default()
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preserves_special_permissions() {
        let a = parse_record("f|-rwsr-Sr-t|17|123").unwrap();
        assert_eq!(a.permissions, Some(0o107745));
        assert_eq!(a.size, Some(17));
        assert!(validate_name("../secret").is_err());
    }
}
