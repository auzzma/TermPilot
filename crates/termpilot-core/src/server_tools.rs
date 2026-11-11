use crate::connection::CoreError;
use serde_json::{json, Value};
fn quote(text: &str) -> Result<String, CoreError> {
    if text.contains('\0') || text.len() > 65536 {
        return Err(CoreError::new(
            "invalidArgument",
            "Invalid command argument.",
        ));
    }
    Ok(format!("'{}'", text.replace('\'', "'\"'\"'")))
}
pub fn plan(request: &Value) -> Result<Value, CoreError> {
    let value = request["value"].as_str().unwrap_or("");
    let command=match request["operation"].as_str().unwrap_or(""){
        "overview"=>"uname -a; printf '\\n--- Uptime ---\\n'; uptime; printf '\\n--- Memory ---\\n'; if command -v free >/dev/null 2>&1; then free -h; else vm_stat; fi; printf '\\n--- Filesystems ---\\n'; df -h".to_string(),
        "processes"=>"ps -eo pid,ppid,user,%cpu,%mem,etime,args | head -n 150".to_string(),
        "processStop"=>{let pid=value.parse::<u32>().ok().filter(|n|*n>1).ok_or(CoreError::new("invalidPID","Enter a process ID greater than 1."))?;format!("kill -TERM {pid}")},
        "dockerList"=>"docker ps -a --no-trunc --format '{{.ID}}\\t{{.Names}}\\t{{.Image}}\\t{{.Status}}'".to_string(),
        "dockerStart"|"dockerStop"|"dockerRestart"|"dockerLogs"=>{if value.is_empty()||!value.chars().all(|c|c.is_ascii_alphanumeric()||"_.-".contains(c))||value.starts_with('-'){return Err(CoreError::new("invalidContainer","Enter a container name or ID."));}let verb=match request["operation"].as_str().unwrap(){"dockerStart"=>"start","dockerStop"=>"stop","dockerRestart"=>"restart",_=>"logs --tail 300"};format!("docker {verb} -- {}",quote(value)?)},
        "tmuxList"=>"tmux list-sessions".to_string(),
        "tmuxAttach"=>format!("tmux new-session -A -s {}",quote(value)?),
        "tmuxKill"=>format!("tmux kill-session -t {}",quote(value)?),
        "script"=>format!("{} -c {}",quote(request["shell"].as_str().unwrap_or("/bin/sh"))?,quote(value)?),
        _=>return Err(CoreError::new("unknownTool","Unknown server tool."))};
    Ok(json!({"command":command}))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn arguments_do_not_escape_shell() {
        let p = plan(&json!({"operation":"tmuxAttach","value":"a'; touch /tmp/no; '"})).unwrap();
        assert_eq!(
            p["command"],
            "tmux new-session -A -s 'a'\"'\"'; touch /tmp/no; '\"'\"''"
        );
        assert!(plan(&json!({"operation":"processStop","value":"1;uname"})).is_err());
        assert!(plan(&json!({"operation":"dockerStop","value":"--all"})).is_err());
    }
}
