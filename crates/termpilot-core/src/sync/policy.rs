//! Field classification happens before operations, conflicts or snapshots leave this device.
use serde_json::{Map, Value};
use std::collections::BTreeMap;

pub const DEFAULT_SCOPES: &[&str] = &["configuration"];
pub const SCOPES: &[&str] = &[
    "configuration",
    "credentials",
    "aiSecrets",
    "preferences",
    "aiHistory",
];
pub const TABLES: &[(&str, &str)] = &[
    ("hosts", "id"),
    ("host_groups", "id"),
    ("ssh_credentials", "id"),
    ("ssh_proxy_profiles", "id"),
    ("screen_sharing_profiles", "host_id"),
    ("automation_scripts", "id"),
    ("host_notes", "id"),
    ("port_forward_rules", "id"),
];
fn normalized(field: &str) -> String {
    field.replace(['_', '-'], "").to_ascii_lowercase()
}
pub fn secret(field: &str) -> bool {
    let name = normalized(field);
    name.contains("password")
        || name.contains("passphrase")
        || name.contains("privatekey")
        || name.contains("apikey")
        || name.contains("token")
        || name.contains("authorization")
        || name == "headers"
        || name == "customheaders"
        || name == "httpheaders"
}
pub fn local(field: &str) -> bool {
    matches!(
        normalized(field).as_str(),
        "identityfile"
            | "privatekeypath"
            | "agentpath"
            | "executablepath"
            | "workingdirectory"
            | "windowlayout"
            | "autogrant"
            | "permissions"
            | "allowedtools"
            | "pendingapprovals"
            | "trustedhosts"
            | "knownhosts"
            | "lastconnectedat"
            | "toolaccess"
            | "agents"
            | "executable"
            | "cwd"
            | "configdirectory"
            | "settingsfile"
            | "attachments"
            | "externalid"
            | "autostart"
    )
}
// Objects are split recursively: a proxy password must not hide inside ordinary configuration.
fn filter(value: &Value, include_secret: bool) -> Option<Value> {
    match value {
        Value::Object(object) => {
            let fields: Map<String, Value> = object
                .iter()
                .filter_map(|(k, v)| {
                    if local(k) {
                        None
                    } else if secret(k) {
                        include_secret.then(|| (k.clone(), v.clone()))
                    } else if v.is_object() || v.is_array() {
                        filter(v, include_secret).map(|v| (k.clone(), v))
                    } else {
                        (!include_secret).then(|| (k.clone(), v.clone()))
                    }
                })
                .collect();
            (!fields.is_empty()).then_some(Value::Object(fields))
        }
        // Keep array shape, otherwise secret subfields could move to another model/provider.
        Value::Array(values) => {
            let result: Vec<Value> = values
                .iter()
                .map(|v| filter(v, include_secret).unwrap_or(Value::Null))
                .collect();
            result
                .iter()
                .any(|v| !v.is_null())
                .then_some(Value::Array(result))
        }
        _ => (!include_secret).then(|| value.clone()),
    }
}
pub fn fields(collection: &str, record: &Value, scope: &str) -> BTreeMap<String, Value> {
    let is_ai = collection.starts_with("ai:");
    let history = matches!(collection, "ai:conversations" | "ai:messages");
    if collection.starts_with("ai:")
        && !matches!(
            collection,
            "ai:providers"
                | "ai:settings"
                | "ai:models"
                | "ai:prompts"
                | "ai:conversations"
                | "ai:messages"
        )
    {
        return BTreeMap::new();
    }
    if history != (scope == "aiHistory")
        || (collection == "preferences") != (scope == "preferences")
    {
        return BTreeMap::new();
    }
    let secrets = scope == "credentials" || scope == "aiSecrets";
    if (scope == "credentials" && is_ai) || (scope == "aiSecrets" && !is_ai) {
        return BTreeMap::new();
    }
    let mut object = filter(record, secrets)
        .and_then(|v| v.as_object().cloned())
        .unwrap_or_default();
    if collection == "ai:conversations" {
        for field in ["draft", "status", "updated", "usage"] {
            object.remove(field);
        }
    }
    if collection == "ai:settings" {
        for field in ["mode", "toolAccess", "agents", "commandBlacklist"] {
            object.remove(field);
        }
    }
    for key in ["id", "created_at", "updated_at", "createdAt", "updatedAt"] {
        object.remove(key);
    }
    if collection == "screen_sharing_profiles" {
        object.remove("host_id");
    }
    if !secrets
        && matches!(
            collection,
            "hosts" | "ssh_credentials" | "ssh_proxy_profiles" | "screen_sharing_profiles"
        )
    {
        let mut authentication = Map::new();
        let keys: &[&str] = match collection {
            "ssh_credentials" => &["kind", "username"],
            "ssh_proxy_profiles" => &[
                "type",
                "host",
                "port",
                "command",
                "username",
                "credential_reference",
            ],
            "screen_sharing_profiles" => &["port", "username", "mode"],
            _ => &[
                "connection_kind",
                "authentication",
                "username",
                "credential_reference",
            ],
        };
        for &key in keys {
            if let Some(value) = object.remove(key) {
                authentication.insert(key.into(), value);
            }
        }
        if !authentication.is_empty() {
            object.insert("$authentication".into(), Value::Object(authentication));
        }
    }
    object.into_iter().collect()
}
pub fn expand(fields: Value) -> Value {
    let mut object = fields.as_object().cloned().unwrap_or_default();
    if let Some(Value::Object(auth)) = object.remove("$authentication") {
        object.extend(auth);
    }
    Value::Object(object)
}
/// Seed only secret material actually present on this device. Keep array slots
/// stable so nested provider secrets cannot be associated with another provider.
pub fn initial_secrets(fields: BTreeMap<String, Value>) -> BTreeMap<String, Value> {
    fn present(value: Value) -> Option<Value> {
        match value {
            Value::String(value) if !value.is_empty() => Some(Value::String(value)),
            Value::Object(fields) => {
                let fields: Map<String, Value> = fields
                    .into_iter()
                    .filter_map(|(key, value)| present(value).map(|value| (key, value)))
                    .collect();
                (!fields.is_empty()).then_some(Value::Object(fields))
            }
            Value::Array(values) => {
                let values: Vec<Value> = values
                    .into_iter()
                    .map(|value| present(value).unwrap_or(Value::Null))
                    .collect();
                values
                    .iter()
                    .any(|value| !value.is_null())
                    .then_some(Value::Array(values))
            }
            _ => None,
        }
    }
    let saves_passphrase = fields.get("saves_passphrase").cloned();
    let mut result: BTreeMap<String, Value> = fields
        .into_iter()
        .filter_map(|(key, value)| present(value).map(|value| (key, value)))
        .collect();
    if result.contains_key("passphrase") {
        if let Some(value) = saves_passphrase.filter(|value| !value.is_null()) {
            result.insert("saves_passphrase".into(), value);
        }
    }
    result
}
pub fn overlay(base: &mut Value, patch: &Value) {
    match (base, patch) {
        (Value::Object(base), Value::Object(patch)) => {
            for (k, v) in patch {
                if let Some(old) = base.get_mut(k) {
                    overlay(old, v);
                } else {
                    base.insert(k.clone(), v.clone());
                }
            }
        }
        (Value::Array(base), Value::Array(patch)) if base.len() == patch.len() => {
            for (b, p) in base.iter_mut().zip(patch) {
                if !p.is_null() {
                    overlay(b, p);
                }
            }
        }
        (base, patch) => *base = patch.clone(),
    }
}

/// Legacy conversations had no message IDs. The fallback is stable across replicas.
pub fn message_id(conversation: &str, index: usize, message: &Value) -> String {
    message["id"]
        .as_str()
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
        .unwrap_or_else(|| {
            format!(
                "legacy-{}",
                super::model::hash(&serde_json::json!([conversation, index]))
            )
        })
}
