//! Remote Windows monitoring over the existing SSH exec channel. No remote agent.
use crate::{ipc::text, ssh::Session};
use anyhow::{bail, ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use serde_json::{json, Value};
use std::{collections::HashMap, time::Duration};
use tokio::sync::{Mutex, OnceCell};
use tokio_util::sync::CancellationToken;

const MARKER: &str = "__TERMPILOT_SYSTEM_JSON__";
const PROBE: &str = r#"$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false); if([Environment]::OSVersion.Platform -ne 'Win32NT'){throw 'Not Windows'}; Write-Output '__TERMPILOT_SYSTEM_JSON__'; @{schema=1;platform='windows';username=[Environment]::UserName} | ConvertTo-Json -Compress"#;

#[derive(Default)]
pub struct Monitor {
    info: OnceCell<Value>,
    network: Mutex<Option<NetworkSample>>,
}
#[derive(Clone)]
struct NetworkSample {
    timestamp_ms: f64,
    counters: HashMap<String, (u64, u64)>,
}
pub fn powershell_command(script: &str) -> String {
    let bytes: Vec<u8> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
    format!(
        "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand {}",
        STANDARD.encode(bytes)
    )
}
fn parse_payload(output: &str) -> Result<Value> {
    let (_, payload) = output
        .split_once(MARKER)
        .context("Windows monitor returned no data")?;
    let value: Value =
        serde_json::from_str(payload.trim()).context("Invalid Windows monitor response")?;
    ensure!(value["schema"] == 1, "Unsupported Windows monitor response");
    Ok(value)
}
async fn windows_exec(
    session: &Session,
    script: &str,
    cancel: &CancellationToken,
) -> Result<Value> {
    let result = session
        .exec_cancellable(
            &powershell_command(script),
            Duration::from_secs(30),
            &Value::Null,
            cancel,
        )
        .await?;
    ensure!(
        result["code"] == 0,
        "Windows monitoring failed: {}",
        text(&result, "stderr").trim()
    );
    parse_payload(text(&result, "stdout"))
}
impl Monitor {
    pub async fn info(&self, session: &Session, cancel: &CancellationToken) -> Result<Value> {
        self.info
            .get_or_try_init(|| async {
                let result = session
                    .exec_cancellable(
                        "printf '__TERMPILOT_OS__'; uname -s; printf '__TERMPILOT_USER__'; id -un",
                        Duration::from_secs(8),
                        &Value::Null,
                        cancel,
                    )
                    .await?;
                if let Some(info) = unix_info(text(&result, "stdout")) {
                    return Ok(info);
                }
                windows_exec(session, PROBE, cancel).await
            })
            .await
            .cloned()
    }
    pub async fn request(
        &self,
        session: &Session,
        request: &Value,
        cancel: &CancellationToken,
    ) -> Result<Value> {
        let info = self.info(session, cancel).await?;
        ensure!(
            info["platform"] == "windows",
            "Windows monitoring requires a Windows host"
        );
        match text(request, "operation") {
            "overview" => {
                // Keep concurrent refreshes ordered, and reset counters with the SSH session.
                let mut previous = self.network.lock().await;
                let raw = windows_exec(session, include_str!("overview.ps1"), cancel).await?;
                let (result, sample) = normalize_overview(raw, previous.as_ref())?;
                *previous = Some(sample);
                Ok(result)
            }
            "processes" => windows_exec(session, include_str!("processes.ps1"), cancel).await,
            "exec" => {
                session
                    .exec_cancellable(
                        &powershell_command(text(request, "command")),
                        Duration::from_secs(30),
                        &Value::Null,
                        cancel,
                    )
                    .await
            }
            "terminate" => {
                let pid = request["pid"]
                    .as_u64()
                    .filter(|pid| *pid > 4 && *pid <= u32::MAX as u64)
                    .context("Invalid process ID")?;
                let script = format!("$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; Stop-Process -Id {pid} -Force; Write-Output '{MARKER}'; Write-Output '{{\"schema\":1}}'");
                windows_exec(session, &script, cancel).await
            }
            _ => bail!("Unknown Windows monitoring operation"),
        }
    }
}
fn unix_info(output: &str) -> Option<Value> {
    let (_, tail) = output.split_once("__TERMPILOT_OS__")?;
    let (os, user) = tail.split_once("__TERMPILOT_USER__")?;
    let os = os.trim();
    let platform = match os {
        "Linux" => "linux",
        "Darwin" => "macos",
        "FreeBSD" | "OpenBSD" | "NetBSD" | "SunOS" => "unix",
        _ => return None,
    };
    let username = user.lines().next()?.trim();
    if username.is_empty() {
        return None;
    }
    Some(json!({"platform":platform,"username":username}))
}
fn normalize_overview(
    mut raw: Value,
    previous: Option<&NetworkSample>,
) -> Result<(Value, NetworkSample)> {
    ensure!(
        raw["memoryTotal"]
            .as_f64()
            .is_some_and(|n| n.is_finite() && n > 0.0),
        "Windows memory information unavailable"
    );
    let timestamp_ms = raw["timestampMs"]
        .as_f64()
        .filter(|n| n.is_finite())
        .context("Missing sample timestamp")?;
    let mut sample = NetworkSample {
        timestamp_ms,
        counters: HashMap::new(),
    };
    let elapsed = previous
        .map(|p| (timestamp_ms - p.timestamp_ms) / 1000.0)
        .filter(|n| *n > 0.0 && *n < 3600.0);
    let mut interfaces = Vec::new();
    let (mut rx_total, mut tx_total) = (0.0, 0.0);
    for item in raw["interfaces"].as_array().into_iter().flatten() {
        let id = text(item, "id");
        let (Some(rx), Some(tx)) = (item["rx"].as_u64(), item["tx"].as_u64()) else {
            continue;
        };
        if id.is_empty() {
            continue;
        }
        let (rx_rate, tx_rate) = match (elapsed, previous.and_then(|p| p.counters.get(id))) {
            (Some(seconds), Some((old_rx, old_tx))) => (
                rx.checked_sub(*old_rx).unwrap_or(0) as f64 / seconds,
                tx.checked_sub(*old_tx).unwrap_or(0) as f64 / seconds,
            ),
            _ => (0.0, 0.0),
        };
        sample.counters.insert(id.into(), (rx, tx));
        rx_total += rx_rate;
        tx_total += tx_rate;
        interfaces
            .push(json!({"name":text(item,"name"),"rxPerSecond":rx_rate,"txPerSecond":tx_rate}));
    }
    let object = raw.as_object_mut().context("Invalid Windows overview")?;
    object.remove("interfaces");
    object.remove("timestampMs");
    raw["networkRxPerSecond"] = json!(rx_total);
    raw["networkTxPerSecond"] = json!(tx_total);
    raw["networkInterfaces"] = json!(interfaces);
    raw["loadAverage"] = json!("N/A");
    raw["swap"] = json!(format!(
        "{:.0} MB / {:.0} MB",
        raw["pageFileUsedMB"].as_f64().unwrap_or(0.0),
        raw["pageFileTotalMB"].as_f64().unwrap_or(0.0)
    ));
    let uptime = raw["uptimeSeconds"].as_f64().unwrap_or(0.0).max(0.0) as u64;
    raw["uptime"] = json!(format!(
        "up {} days {} hours",
        uptime / 86400,
        (uptime / 3600) % 24
    ));
    Ok((raw, sample))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn sample(time: f64, rx: u64, tx: u64) -> Value {
        json!({"schema":1,"timestampMs":time,"memoryTotal":1024,"interfaces":[{"id":"adapter-1","name":"以太网","rx":rx,"tx":tx}],"uptimeSeconds":90000})
    }
    #[test]
    fn rates_use_adapter_identity_and_remote_sample_time() {
        let (first, previous) = normalize_overview(sample(1000.0, 100, 200), None).unwrap();
        assert_eq!(first["networkRxPerSecond"], 0.0);
        let (next, _) = normalize_overview(sample(3000.0, 1100, 4200), Some(&previous)).unwrap();
        assert_eq!(next["networkRxPerSecond"], 500.0);
        assert_eq!(next["networkTxPerSecond"], 2000.0);
        assert_eq!(next["networkInterfaces"][0]["name"], "以太网");
        assert_eq!(next["uptime"], "up 1 days 1 hours");
    }
    #[test]
    fn counter_reset_and_clock_reset_do_not_spike() {
        let (_, previous) = normalize_overview(sample(1000.0, 9000, 9000), None).unwrap();
        for time in [500.0, 2000.0] {
            let (next, _) = normalize_overview(sample(time, 10, 20), Some(&previous)).unwrap();
            assert_eq!(next["networkRxPerSecond"], 0.0);
        }
    }
    #[test]
    fn rejects_invalid_output_and_missing_metrics() {
        assert!(parse_payload("garbage").is_err());
        assert!(parse_payload("__TERMPILOT_SYSTEM_JSON__{\"schema\":2}").is_err());
        assert!(normalize_overview(json!({"memoryTotal":0}), None).is_err());
        assert_eq!(parse_payload("Login banner\r\n__TERMPILOT_SYSTEM_JSON__\r\n{\"schema\":1,\"username\":\"管理员\"}\r\n").unwrap()["username"],"管理员");
    }
    #[test]
    fn platform_probe_requires_markers_and_supported_uname() {
        assert_eq!(
            unix_info("__TERMPILOT_OS__Darwin\n__TERMPILOT_USER__alice\n").unwrap()["platform"],
            "macos"
        );
        assert_eq!(
            unix_info("__TERMPILOT_OS__Linux\n__TERMPILOT_USER__root\n").unwrap()["username"],
            "root"
        );
        assert!(unix_info("Windows command not found").is_none());
        assert!(unix_info("__TERMPILOT_OS__MINGW64\n__TERMPILOT_USER__admin\n").is_none());
    }
    #[test]
    fn encoding_is_utf16_and_does_not_expose_shell_metacharacters() {
        let script = "Write-Output '中文 & $(test)'";
        let cmd = powershell_command(script);
        let bytes = STANDARD
            .decode(cmd.split_whitespace().last().unwrap())
            .unwrap();
        assert_eq!(
            String::from_utf16(
                &bytes
                    .chunks_exact(2)
                    .map(|n| u16::from_le_bytes([n[0], n[1]]))
                    .collect::<Vec<_>>()
            )
            .unwrap(),
            script
        );
    }
}
