use anyhow::{ensure, Context, Result};
use serde_json::{json, Value};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;

// An 8 MiB editable text file can expand sixfold when JSON-escaped.
pub const MAX_COMMAND: usize = 64 * 1024 * 1024;
pub type Events = mpsc::Sender<Value>;

/// Own the partial line when read is used inside select!/timeout. Cancelling a
/// read never discards already consumed bytes from the next IPC message.
pub struct JsonReader<R> {
    reader: R,
    pending: Vec<u8>,
}
impl<R: AsyncBufRead + Unpin> JsonReader<R> {
    pub fn new(reader: R) -> Self {
        Self {
            reader,
            pending: Vec::new(),
        }
    }
    pub async fn read(&mut self) -> Result<Option<Value>> {
        loop {
            let bytes = self.reader.fill_buf().await?;
            if bytes.is_empty() {
                ensure!(self.pending.is_empty(), "Incomplete command");
                return Ok(None);
            }
            let length = bytes
                .iter()
                .position(|b| *b == b'\n')
                .map(|n| n + 1)
                .unwrap_or(bytes.len());
            ensure!(
                self.pending.len() + length <= MAX_COMMAND,
                "Command too large"
            );
            self.pending.extend_from_slice(&bytes[..length]);
            self.reader.consume(length);
            if self.pending.last() == Some(&b'\n') {
                let result = serde_json::from_slice(&self.pending).context("Invalid command");
                use zeroize::Zeroize;
                self.pending.zeroize();
                return result.map(Some);
            }
        }
    }
}
impl<R> Drop for JsonReader<R> {
    fn drop(&mut self) {
        use zeroize::Zeroize;
        self.pending.zeroize();
    }
}

pub async fn read_json<R: AsyncBufRead + Unpin>(reader: &mut R) -> Result<Option<Value>> {
    read_json_limit(reader, MAX_COMMAND).await
}
pub async fn read_json_limit<R: AsyncBufRead + Unpin>(
    reader: &mut R,
    maximum: usize,
) -> Result<Option<Value>> {
    let mut data = Vec::new();
    loop {
        let bytes = reader.fill_buf().await?;
        if bytes.is_empty() {
            ensure!(data.is_empty(), "Incomplete command");
            return Ok(None);
        }
        let length = bytes
            .iter()
            .position(|x| *x == b'\n')
            .map(|n| n + 1)
            .unwrap_or(bytes.len());
        ensure!(data.len() + length <= maximum, "Command too large");
        data.extend_from_slice(&bytes[..length]);
        reader.consume(length);
        if data.last() == Some(&b'\n') {
            return Ok(Some(
                serde_json::from_slice(&data).context("Invalid command")?,
            ));
        }
    }
}
pub async fn write_json<W: AsyncWrite + Unpin>(writer: &mut W, value: &Value) -> Result<()> {
    let mut bytes = serde_json::to_vec(value)?;
    ensure!(bytes.len() <= MAX_COMMAND, "Response too large");
    bytes.push(b'\n');
    writer.write_all(&bytes).await?;
    writer.flush().await?;
    Ok(())
}
pub async fn event(events: &Events, value: Value) -> Result<()> {
    events.send(value).await.context("Client disconnected")
}
pub async fn response(
    events: &Events,
    channel: &str,
    id: Value,
    result: Result<Value>,
) -> Result<()> {
    let message = match result {
        Ok(result) => json!({"id":id,"ok":true,"result":result}),
        Err(e) => json!({"id":id,"ok":false,"error":e.to_string()}),
    };
    event(
        events,
        json!({"type":"sftpResponse","channel":channel,"message":message}),
    )
    .await
}
pub fn text<'a>(v: &'a Value, key: &str) -> &'a str {
    v[key].as_str().unwrap_or("")
}
pub fn number(v: &Value, key: &str, default: u64) -> u64 {
    v[key].as_u64().unwrap_or(default)
}
pub fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn partial_ipc_survives_cancelled_read() {
        let (mut tx, rx) = tokio::io::duplex(128);
        let mut reader = JsonReader::new(tokio::io::BufReader::new(rx));
        tx.write_all(b"{\"kind\":\"par").await.unwrap();
        assert!(
            tokio::time::timeout(std::time::Duration::from_millis(5), reader.read())
                .await
                .is_err()
        );
        tx.write_all(b"tial\"}\n{\"next\":true}\n").await.unwrap();
        assert_eq!(reader.read().await.unwrap().unwrap()["kind"], "partial");
        assert_eq!(reader.read().await.unwrap().unwrap()["next"], true);
    }
}
