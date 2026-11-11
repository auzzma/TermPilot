use crate::connection::CoreError;
use chrono::{DateTime, NaiveDateTime, Utc};
use serde_json::{json, Value};

pub const SWIFT_EPOCH: f64 = 978307200.0;
pub fn now() -> Value {
    json!(Utc::now().timestamp_millis() as f64 / 1000.0 - SWIFT_EPOCH)
}
pub fn sql_date(value: &Value) -> Value {
    if let Some(n) = value.as_f64() {
        if let Some(dt) = DateTime::from_timestamp_millis(((n + SWIFT_EPOCH) * 1000.0) as i64) {
            return json!(dt.format("%Y-%m-%d %H:%M:%S%.3f").to_string());
        }
    }
    value.clone()
}
pub fn swift_date(value: &Value) -> Value {
    if let Some(s) = value.as_str() {
        let parsed = DateTime::parse_from_rfc3339(s)
            .map(|d| d.with_timezone(&Utc))
            .ok()
            .or_else(|| {
                NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S%.f")
                    .ok()
                    .map(|d| d.and_utc())
            });
        if let Some(dt) = parsed {
            return json!(dt.timestamp_millis() as f64 / 1000.0 - SWIFT_EPOCH);
        }
    }
    value.clone()
}
pub fn backup_dates(value: &mut Value, to_iso: bool) {
    if let Some(object) = value.as_object_mut() {
        for (key, item) in object.iter_mut() {
            if matches!(
                key.as_str(),
                "createdAt" | "updatedAt" | "exportedAt" | "startedAt" | "endedAt" | "lastUsedAt"
            ) {
                if to_iso {
                    if let Some(n) = item.as_f64() {
                        if let Some(dt) =
                            DateTime::from_timestamp_millis(((n + SWIFT_EPOCH) * 1000.0) as i64)
                        {
                            *item = json!(dt.to_rfc3339_opts(chrono::SecondsFormat::Secs, true));
                        }
                    }
                } else {
                    *item = swift_date(item);
                }
            } else {
                backup_dates(item, to_iso);
            }
        }
    } else if let Some(items) = value.as_array_mut() {
        for item in items {
            backup_dates(item, to_iso);
        }
    }
}
pub fn key(column: &str) -> String {
    match column {
        "credential_reference" => "credentialID".into(),
        "proxy_profile_reference" => "proxyProfileID".into(),
        "parent_group_id" => "parentGroupID".into(),
        "host_id" => "hostID".into(),
        "group_id" => "groupID".into(),
        "icon_id" => "iconID".into(),
        "sftp_follows_terminal_cwd" => "sftpFollowsTerminalCWD".into(),
        other => {
            let mut parts = other.split('_');
            let mut s = parts.next().unwrap_or("").to_string();
            for part in parts {
                let mut c = part.chars();
                if let Some(f) = c.next() {
                    s.extend(f.to_uppercase());
                    s.push_str(c.as_str());
                }
            }
            s
        }
    }
}
pub fn is_secret(column: &str) -> bool {
    matches!(
        column,
        "password" | "private_key" | "passphrase" | "elevation_password" | "proxy_password"
    )
}
pub fn is_bool(column: &str) -> bool {
    matches!(
        column,
        "audio"
            | "saves_passphrase"
            | "sftp_uses_sudo"
            | "sftp_follows_terminal_cwd"
            | "server_tools_use_root"
            | "succeeded"
    )
}
pub fn validate(collection: &str, value: &mut Value) -> Result<(), CoreError> {
    if !value.is_object() {
        return Err(CoreError::new("invalidRecord", "Record must be an object."));
    }
    let required = match collection {
        "hosts" => Some("label"),
        "groups" => Some("name"),
        "credentials" | "proxies" => Some("label"),
        "scripts" | "notes" => Some("title"),
        "forwards" => Some("name"),
        _ => None,
    };
    if let Some(key) = required {
        let trimmed = value[key].as_str().unwrap_or("").trim().to_owned();
        if trimmed.is_empty() {
            return Err(CoreError::new("missingName", "A name is required."));
        }
        value[key] = json!(trimmed);
    }
    match collection {
        "hosts" => {
            let host = value["hostname"].as_str().unwrap_or("").trim().to_owned();
            let ssh = value["connectionKind"].as_str().unwrap_or("ssh") == "ssh";
            crate::connection::validate_endpoint(
                &host,
                if ssh {
                    value["port"].as_u64().unwrap_or(22)
                } else {
                    22
                },
            )?;
            value["hostname"] = json!(host);
            if value["username"].is_null() {
                value["username"] = json!("");
            }
            for (key, allowed) in [
                ("connectionKind", &["ssh", "screenSharing", "rdp"][..]),
                ("authentication", &["password", "identityFile", "agent"][..]),
            ] {
                if !value[key].is_null() && !allowed.contains(&value[key].as_str().unwrap_or("")) {
                    return Err(CoreError::new(
                        "invalidConnection",
                        "Invalid connection type.",
                    ));
                }
            }
            if ssh && value["username"].as_str().unwrap_or("").trim().is_empty() {
                return Err(CoreError::new("missingUsername", "Username is required."));
            }
        }
        "credentials" => {
            if !value["elevationMethod"].is_null()
                && !["sudo", "su"].contains(&value["elevationMethod"].as_str().unwrap_or(""))
            {
                return Err(CoreError::new("invalidCredential", "Invalid credential elevation method."));
            }
            if value["username"].as_str().unwrap_or("").trim().is_empty() {
                return Err(CoreError::new("missingUsername", "Username is required."));
            }
            if value["kind"] != "password" && value["kind"] != "identityKey" {
                return Err(CoreError::new(
                    "invalidCredential",
                    "Invalid credential kind.",
                ));
            }
            let field = if value["kind"] == "identityKey" {
                "privateKey"
            } else {
                "password"
            };
            if value[field].as_str().unwrap_or("").is_empty() {
                return Err(CoreError::new(
                    "missingCredential",
                    "Credential content is required.",
                ));
            }
            if field == "privateKey" {
                value["password"] = Value::Null;
                if value["savesPassphrase"] != true {
                    value["passphrase"] = Value::Null;
                }
            } else {
                for key in ["privateKey", "publicKey", "certificate", "passphrase"] {
                    value[key] = Value::Null;
                }
                value["savesPassphrase"] = json!(false);
            }
        }
        "proxies" => {
            let config = &mut value["configuration"];
            if !["socks5", "http", "command"].contains(&config["type"].as_str().unwrap_or("")) {
                return Err(CoreError::new("invalidProxy", "Invalid proxy type."));
            }
            if config["type"] == "command" {
                let command = config["command"].as_str().unwrap_or("").trim().to_string();
                if command.is_empty() {
                    return Err(CoreError::new(
                        "missingProxyCommand",
                        "Proxy command is required.",
                    ));
                }
                config["command"] = json!(command);
                config["host"] = json!("");
                config["port"] = json!(0);
                for key in ["credentialID", "username", "password"] {
                    config[key] = Value::Null;
                }
            } else {
                let host = config["host"].as_str().unwrap_or("").trim().to_string();
                crate::connection::validate_endpoint(&host, config["port"].as_u64().unwrap_or(0))?;
                config["host"] = json!(host);
                config["command"] = Value::Null;
                if !config["credentialID"].is_null() {
                    config["username"] = Value::Null;
                    config["password"] = Value::Null;
                } else {
                    let username = config["username"].as_str().unwrap_or("").trim().to_string();
                    config["username"] = if username.is_empty() {
                        Value::Null
                    } else {
                        json!(username)
                    };
                    if config["password"].as_str() == Some("") {
                        config["password"] = Value::Null;
                    }
                }
            }
        }
        "screenSharing" => {
            if value["username"].is_null() {
                value["username"] = json!("");
            }
            let mode = value["mode"].as_str().unwrap_or("highPerformance");
            if !["standardVNC", "highPerformance", "rdp"].contains(&mode)
                || (mode != "standardVNC"
                    && value["username"].as_str().unwrap_or("").trim().is_empty())
            {
                return Err(CoreError::new(
                    "invalidProfile",
                    "Invalid screen sharing profile.",
                ));
            }
            if !(1..=65535).contains(&value["port"].as_u64().unwrap_or(5900)) {
                return Err(CoreError::new(
                    "invalidPort",
                    "Invalid screen-sharing port.",
                ));
            }
        }
        "scripts" => {
            if value["shell"].as_str().unwrap_or("").trim().is_empty() {
                return Err(CoreError::new("missingShell", "Script shell is required."));
            }
        }
        "forwards" => {
            if !["local", "remote", "dynamic"].contains(&value["kind"].as_str().unwrap_or("")) {
                return Err(CoreError::new("invalidForward", "Invalid forwarding type."));
            }
            if !(1..=65535).contains(&value["localPort"].as_u64().unwrap_or(0)) {
                return Err(CoreError::new("invalidPort", "Invalid local port."));
            }
            if value["kind"] != "dynamic" {
                crate::connection::validate_endpoint(
                    value["remoteHost"].as_str().unwrap_or(""),
                    value["remotePort"].as_u64().unwrap_or(0),
                )?;
            }
        }
        _ => {}
    }
    Ok(())
}
