//! Read the foreground process of the actual SSH PTY, never a new login shell's pwd.
use crate::{ipc::text, ssh::Session};
use anyhow::{bail, ensure, Context, Result};
use serde_json::Value;
use std::{
    collections::{HashMap, HashSet},
    time::Duration,
};

// /proc works with BusyBox as well as procps. macOS uses BSD ps and lsof.
// No command is written to the interactive terminal (which may be in a password
// prompt, editor, or a shell belonging to another user).
const SNAPSHOT: &str = r#"# termpilot-terminal-processes
printf '__TP_PARENT__%s\n' "$PPID"
if [ -r /proc/$$/stat ]; then
  for tp_proc in /proc/[0-9]*/stat; do
    IFS= read -r tp_stat < "$tp_proc" 2>/dev/null || continue
    tp_pid=${tp_stat%% *}; tp_fields=${tp_stat##*) }
    tp_name=${tp_stat#*(}; tp_name=${tp_name%)*}
    set -f; set -- $tp_fields; set +f
    [ "$#" -ge 20 ] || continue
    tp_ppid=$2; tp_pgid=$3; tp_tty=$5; tp_fg=$6
    shift 19
    printf '%s %s %s %s %s %s %s\n' "$tp_pid" "$tp_ppid" "$tp_pgid" "$tp_fg" "$tp_tty" "$1" "$tp_name"
  done
else
  LC_ALL=C ps -axo pid=,ppid=,pgid=,tpgid=,tty=,comm=
fi"#;

#[derive(Clone, Debug)]
pub(crate) struct TerminalProcess {
    pid: u32,
    parent: u32,
    group: i64,
    foreground: i64,
    tty: String,
    birth: Option<String>,
    command: String,
}
impl TerminalProcess {
    fn has_tty(&self) -> bool {
        !matches!(self.tty.as_str(), "0" | "?" | "??" | "-" | "")
    }
    fn same_process(&self, other: &Self) -> bool {
        self.pid == other.pid
            && self.parent == other.parent
            && self.tty == other.tty
            && self.birth == other.birth
    }
}
struct Snapshot {
    parent: u32,
    processes: HashMap<u32, TerminalProcess>,
}
impl Snapshot {
    fn parse(output: &str) -> Result<Self> {
        let mut lines = output.lines();
        let parent = lines
            .find_map(|line| line.split_once("__TP_PARENT__").map(|(_, value)| value))
            .and_then(|s| s.trim().parse().ok())
            .context("Terminal process inspection is unavailable on this server")?;
        let mut processes = HashMap::new();
        for line in lines {
            let fields: Vec<_> = line.split_whitespace().collect();
            if fields.len() < 5 {
                continue;
            }
            let (Ok(pid), Ok(parent), Ok(group), Ok(foreground)) = (
                fields[0].parse::<u32>(),
                fields[1].parse::<u32>(),
                fields[2].parse::<i64>(),
                fields[3].parse::<i64>(),
            ) else {
                continue;
            };
            if pid == 0 {
                continue;
            }
            processes.insert(
                pid,
                TerminalProcess {
                    pid,
                    parent,
                    group,
                    foreground,
                    tty: fields[4].into(),
                    birth: fields
                        .get(5)
                        .filter(|s| s.bytes().all(|b| b.is_ascii_digit()))
                        .map(|s| s.to_string()),
                    command: fields
                        .get(
                            if fields
                                .get(5)
                                .is_some_and(|s| s.bytes().all(|b| b.is_ascii_digit()))
                            {
                                6
                            } else {
                                5
                            },
                        )
                        .unwrap_or(&"")
                        .to_string(),
                },
            );
        }
        ensure!(
            !processes.is_empty(),
            "Terminal process inspection is unavailable on this server"
        );
        Ok(Self { parent, processes })
    }
    fn shell(&self, root: &TerminalProcess) -> Result<TerminalProcess> {
        let mut active = self.foreground(root)?;
        // Keep the interactive account while sudo asks for authentication or a
        // foreground program runs; follow a newly started shell after su/sudo.
        for _ in 0..64 {
            let name = active
                .command
                .rsplit('/')
                .next()
                .unwrap_or("")
                .trim_start_matches('-');
            if active.pid == root.pid
                || active.command.is_empty()
                || matches!(
                    name,
                    "sh" | "bash" | "zsh" | "dash" | "ash" | "ksh" | "fish" | "csh" | "tcsh"
                )
            {
                return Ok(active);
            }
            active = self
                .processes
                .get(&active.parent)
                .context("Terminal shell is no longer active")?
                .clone();
        }
        bail!("Terminal process nesting limit")
    }
    fn new_terminal(&self, claimed: &HashSet<u32>) -> Result<TerminalProcess> {
        let candidates: Vec<_> = self
            .processes
            .values()
            .filter(|p| p.parent == self.parent && p.has_tty() && !claimed.contains(&p.pid))
            .collect();
        ensure!(
            candidates.len() == 1,
            "Could not identify this terminal's process"
        );
        Ok(candidates[0].clone())
    }
    fn foreground(&self, root: &TerminalProcess) -> Result<TerminalProcess> {
        let current = self
            .processes
            .get(&root.pid)
            .filter(|p| root.same_process(p))
            .context("Source terminal is no longer active")?;
        let mut terminal = current;
        let mut visited = HashSet::new();
        for _ in 0..64 {
            ensure!(
                visited.insert(terminal.pid),
                "Invalid terminal process tree"
            );
            // A foreground shell may be below several waiting parents (sudo,
            // login shell, su). All processes on that PTY report the innermost
            // foreground group, so traverse the ancestry before choosing it.
            let mut descendants = vec![(terminal, 0usize)];
            let mut index = 0;
            while index < descendants.len() {
                let (parent, depth) = descendants[index];
                ensure!(
                    depth < 64 && descendants.len() <= self.processes.len(),
                    "Invalid terminal process tree"
                );
                descendants.extend(
                    self.processes
                        .values()
                        .filter(|p| p.parent == parent.pid)
                        .map(|p| (p, depth + 1)),
                );
                index += 1;
            }
            let foreground: Vec<_> = descendants
                .into_iter()
                .filter(|(p, _)| {
                    p.tty == terminal.tty && p.group == terminal.foreground && p.group > 0
                })
                .collect();
            let depth = foreground.iter().map(|(_, d)| *d).max().context(
                "Could not inspect the foreground job; check file-tool elevation and permissions",
            )?;
            let candidates: Vec<_> = foreground
                .into_iter()
                .filter(|(_, d)| *d == depth)
                .map(|(p, _)| p)
                .collect();
            ensure!(
                candidates.len() == 1,
                "Terminal foreground job is ambiguous; wait until it finishes"
            );
            let active = candidates[0];
            // sudo's monitor owns another PTY. Only follow a new PTY below the
            // selected foreground process, never a background job or other tab.
            let next: Vec<_> = self
                .processes
                .values()
                .filter(|p| p.parent == active.pid && p.has_tty() && p.tty != active.tty)
                .collect();
            if next.is_empty() {
                return Ok(active.clone());
            }
            ensure!(
                next.len() == 1,
                "Terminal foreground job is ambiguous; wait until it finishes"
            );
            terminal = next[0];
        }
        bail!("Terminal process nesting limit")
    }
}
#[derive(Debug, Default, PartialEq, Eq)]
pub(crate) struct TerminalContext {
    pub username: Option<String>,
    pub directory: Option<String>,
}
fn context_command(process: &TerminalProcess) -> String {
    let pid = process.pid;
    let birth = crate::ipc::shell_quote(process.birth.as_deref().unwrap_or(""));
    format!(
        r#"# termpilot-terminal-context {pid}
if [ -d /proc/{pid} ]; then
  IFS= read -r tp_stat < /proc/{pid}/stat || exit 1
  tp_fields=${{tp_stat##*) }}; set -f; set -- $tp_fields; set +f; shift 19
  [ "$1" = {birth} ] || exit 1
  tp_uid=
  while IFS= read -r tp_line; do
    case "$tp_line" in Uid:*) set -- $tp_line; tp_uid=$3; break;; esac
  done < /proc/{pid}/status
  tp_cwd=$(readlink /proc/{pid}/cwd 2>/dev/null) || tp_cwd=
else
  tp_uid=$(ps -p {pid} -o uid= | tr -d ' ')
  tp_cwd=$(lsof -a -p {pid} -d cwd -Fn 2>/dev/null | sed -n 's/^n\(\/.*\)$/\1/p')
fi
tp_user=$(id -nu "$tp_uid" 2>/dev/null) || tp_user=
printf '\036TP_USER:%s\037\036TP_CWD:%s\037' "$tp_user" "$tp_cwd"
"#
    )
}
fn context(output: &str) -> TerminalContext {
    let value = |tag: &str| {
        output
            .split_once(tag)
            .and_then(|(_, tail)| tail.split_once('\u{1f}'))
            .map(|(value, _)| value)
    };
    TerminalContext {
        username: value("\u{1e}TP_USER:")
            .filter(|s| {
                !s.is_empty() && s.len() <= 256 && !s.contains(['\0', '\r', '\n', '\u{1e}'])
            })
            .map(str::to_string),
        directory: value("\u{1e}TP_CWD:").and_then(|s| directory(s).ok()),
    }
}

fn directory(output: &str) -> Result<String> {
    let path = output.trim_end_matches(['\r', '\n']);
    ensure!(
        path.starts_with('/') && !path.contains(['\0', '\r', '\n']),
        "Could not read the active terminal directory; check file-tool elevation and permissions"
    );
    Ok(path.into())
}
impl Session {
    async fn terminal_snapshot(&self, options: &Value) -> Result<Snapshot> {
        let result = self.exec(SNAPSHOT, Duration::from_secs(5), options).await?;
        ensure!(
            result["exitCode"] == 0,
            "Could not inspect the active terminal processes"
        );
        Snapshot::parse(text(&result, "stdout"))
    }
    pub(crate) async fn register_terminal(&self, id: &str) -> Result<()> {
        let snapshot = self.terminal_snapshot(&Value::Null).await?;
        let mut roots = self.terminal_roots.write().await;
        let claimed = roots.values().map(|p| p.pid).collect();
        let root = snapshot.new_terminal(&claimed)?;
        roots.insert(id.into(), root);
        Ok(())
    }
    pub(crate) async fn terminal_context(
        &self,
        id: &str,
        options: &Value,
    ) -> Result<TerminalContext> {
        let root = self
            .terminal_roots
            .read()
            .await
            .get(id)
            .cloned()
            .context("Could not identify this terminal's process")?;
        for _ in 0..2 {
            let snapshot = self.terminal_snapshot(options).await?;
            let process = snapshot.shell(&root)?;
            let result = self
                .exec(&context_command(&process), Duration::from_secs(5), options)
                .await?;
            if result["exitCode"] == 0 {
                let context = context(text(&result, "stdout"));
                if let Some(path) = &context.directory {
                    self.cwd.write().await.insert(id.into(), path.clone());
                }
                if context.username.is_some() || context.directory.is_some() {
                    return Ok(context);
                }
            }
        }
        bail!(
            "Could not read the active terminal context; check file-tool elevation and permissions"
        )
    }
    pub(crate) async fn terminal_directory(&self, id: &str, options: &Value) -> Result<String> {
        self.terminal_context(id, options).await?.directory
            .context("Could not read the active terminal directory; check file-tool elevation and permissions")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    fn snapshot(rows: &str) -> Snapshot {
        Snapshot::parse(&format!("__TP_PARENT__10\n{rows}")).unwrap()
    }
    #[test]
    fn follows_sudo_nested_pty_su_and_returns_to_login_shell() {
        let base = "100 10 100 100 1 123\n900 10 900 900 9 900\n";
        let root = snapshot(base).new_terminal(&HashSet::from([900])).unwrap();
        let switched = snapshot("100 10 100 200 1 123\n200 100 200 200 1 200\n201 200 201 204 2 201\n203 201 203 204 2 203\n204 203 204 204 2 204\n205 204 204 204 2 205\n300 100 300 200 1 300\n900 10 900 900 9 900\n");
        assert_eq!(switched.foreground(&root).unwrap().pid, 205);
        assert_eq!(snapshot(base).foreground(&root).unwrap().pid, 100);
    }
    #[test]
    fn keeps_login_account_at_sudo_prompt_and_tracks_nested_shell_during_jobs() {
        let root = snapshot("100 10 100 100 1 123 bash\n")
            .new_terminal(&HashSet::new())
            .unwrap();
        let prompt = snapshot("100 10 100 200 1 123 bash\n200 100 200 200 1 200 sudo\n");
        assert_eq!(prompt.shell(&root).unwrap().pid, 100);
        let job = snapshot("100 10 100 200 1 123 bash\n200 100 200 200 1 200 sudo\n201 200 201 400 2 201 sudo\n203 201 203 400 2 203 bash\n400 203 400 400 2 400 sleep\n");
        assert_eq!(job.shell(&root).unwrap().pid, 203);
        let nested = snapshot("100 10 100 300 1 123 bash\n200 100 200 300 1 200 su\n203 200 203 300 1 203 -zsh\n300 203 300 300 1 300 vim\n");
        assert_eq!(nested.shell(&root).unwrap().pid, 203);
    }
    #[test]
    fn parses_framed_context_without_prompts_and_allows_user_without_cwd_permission() {
        assert_eq!(
            context("# \u{1e}TP_USER:root\u{1f}\u{1e}TP_CWD:/root/中文 logs \u{1f}# "),
            TerminalContext {
                username: Some("root".into()),
                directory: Some("/root/中文 logs ".into())
            }
        );
        assert_eq!(
            context("\u{1e}TP_USER:root\u{1f}\u{1e}TP_CWD:\u{1f}"),
            TerminalContext {
                username: Some("root".into()),
                directory: None
            }
        );
        assert_eq!(context("unframed root /root"), TerminalContext::default());
    }
    #[test]
    fn rejects_ambiguous_terminals_reused_pids_and_background_jobs() {
        let s = snapshot("100 10 100 100 1 123\n900 10 900 900 9 900\n");
        assert!(s.new_terminal(&HashSet::new()).is_err());
        let root = s.new_terminal(&HashSet::from([900])).unwrap();
        assert!(snapshot("100 10 100 100 1 999\n")
            .foreground(&root)
            .is_err());
        assert_eq!(
            snapshot("100 10 100 100 1 123\n200 100 200 100 1 200\n")
                .foreground(&root)
                .unwrap()
                .pid,
            100
        );
    }
    #[test]
    fn supports_bsd_ps_and_paths_with_spaces_and_unicode() {
        let s = snapshot("100 10 100 100 ttys001\n");
        assert_eq!(s.new_terminal(&HashSet::new()).unwrap().tty, "ttys001");
        assert_eq!(
            directory("/root/中文 logs \r\n").unwrap(),
            "/root/中文 logs "
        );
        assert!(directory("").is_err());
        assert!(directory("/a\n/b\n").is_err());
    }
}
