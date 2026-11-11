use crate::connection::CoreError;
use serde_json::{json, Value};
use std::path::Path;

pub fn plan(request: &Value) -> Result<Value, CoreError> {
    let field = |name| {
        request[name]
            .as_str()
            .filter(|v| !v.is_empty() && !v.contains('\0'))
            .ok_or(CoreError::new(
                "invalidRuntime",
                "Missing engine runtime configuration.",
            ))
    };
    let runtime = field("runtime")?;
    // Callers supply app-owned paths, never shell commands or PATH lookups.
    if !Path::new(runtime).is_absolute() {
        return Err(CoreError::new(
            "invalidRuntime",
            "Engine paths must be absolute.",
        ));
    }
    let engine = field("engine")?;
    let args = match engine {
        "screenSharing" => vec!["screen-sharing"],
        "sshTerminal" | "sshForward" => vec!["ssh-terminal"],
        "sftp" => vec!["ssh-files"],
        "ssh" | "keygen" => vec![engine],
        _ => {
            return Err(CoreError::new(
                "unknownEngine",
                "Unknown connection engine.",
            ))
        }
    };
    Ok(json!({"executable":runtime,"arguments":args,"engine":engine}))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn no_shell_interpolation_or_credentials_in_launch_plan() {
        let base = std::env::temp_dir();
        let value = plan(&json!({"engine":"screenSharing","runtime":base.join("engine with spaces"),"password":"secret-marker"})).unwrap();
        assert_eq!(value["arguments"], json!(["screen-sharing"]));
        assert!(!value.to_string().contains("secret-marker"));
        assert!(plan(&json!({"engine":"ssh","runtime":"python","script":"script"})).is_err());
    }
}
