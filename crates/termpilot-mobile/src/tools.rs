//! Mobile management commands use one shared quoting and validation policy.
use anyhow::{bail, ensure, Context, Result};
use base64::Engine;
use serde_json::{json, Value};
fn q(s: &str) -> Result<String> {
    ensure!(
        !s.contains('\0') && s.len() <= 65536,
        "Invalid command argument"
    );
    Ok(format!("'{}'", s.replace('\'', "'\\''")))
}
pub fn plan(v: &Value) -> Result<Value> {
    let op = v["operation"].as_str().unwrap_or("");
    let value = v["value"].as_str().unwrap_or("");
    let windows = v["platform"] == "windows";
    ensure!(
        !(windows && op.starts_with("tmux")),
        "Windows 原生环境没有 tmux；请连接已安装 tmux 的 Linux/WSL SSH 服务"
    );
    let arg = if windows {
        format!("'{}'", value.replace('\'', "''"))
    } else {
        q(value)?
    };
    if op.starts_with("docker") && !["dockerList", "dockerImages", "dockerPrune"].contains(&op) {
        container(value)?;
        if ["dockerTag", "dockerRename"].contains(&op) {
            container(v["name"].as_str().unwrap_or(""))?;
        }
    }
    let command = match op {
        "commandHistory" if windows => "$base=[Environment]::GetFolderPath('ApplicationData'); foreach($relative in @('Microsoft/PowerShell/PSReadLine/ConsoleHost_history.txt','Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt')) { $path=Join-Path $base $relative; if(Test-Path -LiteralPath $path -PathType Leaf) { Get-Content -LiteralPath $path -Tail 2000; break } }".into(),
        "commandHistory" => "for path in \"$HOME/.zsh_history\" \"$HOME/.bash_history\" \"$HOME/.local/share/fish/fish_history\"; do if [ -f \"$path\" ]; then tail -n 2000 -- \"$path\"; break; fi; done".into(),
        "tmuxList" => {
            "tmux list-sessions -F '#{session_name}\t#{session_windows}\t#{session_attached}'"
                .into()
        }
        "tmuxCreate" => {
            ensure!(
                !value.is_empty() && !value.starts_with('-') && !value.contains([':', '.']),
                "Invalid tmux session name"
            );
            format!("tmux new-session -d -s {arg}")
        }
        "tmuxRename" => format!(
            "tmux rename-session -t {} {}",
            q(&format!("={value}"))?,
            q(v["name"].as_str().unwrap_or(""))?
        ),
        "tmuxKill" => format!("tmux kill-session -t {}", q(&format!("={value}"))?),
        "tmuxWindowAttach" => {
            let index = v["window"].as_u64().context("Invalid window index")?;
            format!(
                "tmux select-window -t {} && tmux attach-session -t {}",
                q(&format!("={value}:{index}"))?,
                q(&format!("={value}"))?
            )
        }
        "tmuxAttach" => format!("tmux attach-session -t {}", q(&format!("={value}"))?),
        "tmuxWindows" => format!(
            "tmux list-windows -t {} -F '#{{window_index}}\t#{{window_name}}\t#{{window_panes}}'",
            q(&format!("={value}"))?
        ),
        "tmuxPreview" => format!("tmux capture-pane -p -S -200 -t {arg}"),
        "tmuxSend" => format!(
            "tmux send-keys -t {arg} -l -- {} && tmux send-keys -t {arg} Enter",
            q(v["text"].as_str().unwrap_or(""))?
        ),
        "processStop" if windows => {
            let pid = value.parse::<u32>()?;
            ensure!(pid > 4, "Invalid protected process ID");
            format!("Stop-Process -Id {pid} -ErrorAction Stop")
        }
        "script" if windows => {
            let shell = v["shell"].as_str().unwrap_or("powershell");
            ensure!(
                ["powershell", "powershell.exe", "pwsh", "pwsh.exe"].contains(&shell),
                "Windows 脚本请选择 powershell 或 pwsh 解释器"
            );
            return Ok(
                json!({"command":format!("{shell} -NoLogo -NoProfile -NonInteractive -EncodedCommand {}",encoded(value)),"interactive":true}),
            );
        }
        "dockerList" => "docker ps -a --no-trunc --format '{{json .}}'".into(),
        "dockerImages" => "docker images --no-trunc --format '{{json .}}'".into(),
        "dockerPrune" => "docker image prune -f".into(),
        "dockerRename" => format!(
            "docker rename {arg} {}",
            q(v["name"].as_str().unwrap_or(""))?
        ),
        "dockerTag" => format!("docker tag {arg} {}", q(v["name"].as_str().unwrap_or(""))?),
        op if op.starts_with("docker") => {
            ensure!(
                !value.is_empty()
                    && !value.starts_with('-')
                    && value
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || "_.:/-".contains(c)),
                "Invalid container or image name"
            );
            let verb = match op {
                "dockerStart" => "start",
                "dockerStop" => "stop",
                "dockerRestart" => "restart",
                "dockerPause" => "pause",
                "dockerResume" => "unpause",
                "dockerKill" => "kill",
                "dockerRemove" => "rm",
                "dockerImageRemove" => "rmi",
                "dockerLogs" => "logs --tail 300",
                "dockerLogsFollow" => "logs --follow --tail 300",
                "dockerInspect" => "inspect",
                "dockerShell" => "exec -it",
                _ => bail!("Unknown Docker operation"),
            };
            format!(
                "docker {verb} -- {arg}{}",
                if op == "dockerShell" { " /bin/sh" } else { "" }
            )
        }
        _ => return termpilot_core::server_tools::plan(v).map_err(|e| anyhow::anyhow!(e.message)),
    };
    let command = if windows {
        format!(
            "powershell.exe -NoLogo -NoProfile -NonInteractive -EncodedCommand {}",
            encoded(&command)
        )
    } else {
        command
    };
    Ok(
        json!({"command":command,"interactive":matches!(op,"tmuxAttach"|"tmuxWindowAttach"|"dockerShell"|"dockerLogsFollow")}),
    )
}
fn encoded(s: &str) -> String {
    base64::engine::general_purpose::STANDARD.encode(
        s.encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect::<Vec<_>>(),
    )
}
fn container(name: &str) -> Result<()> {
    ensure!(
        !name.is_empty()
            && !name.starts_with('-')
            && name
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "_.:/-".contains(c)),
        "Invalid container or image name"
    );
    Ok(())
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shell_arguments_never_become_operators() {
        let p = plan(&json!({"operation":"tmuxRename","value":"x;touch /tmp/no","name":"a'b"}))
            .unwrap();
        assert_eq!(
            p["command"],
            "tmux rename-session -t '=x;touch /tmp/no' 'a'\\''b'"
        );
        assert!(plan(&json!({"operation":"dockerRemove","value":"--all"})).is_err());
    }
}
