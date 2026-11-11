//! AI tools adapt to the same vault records used by the native host UI.
use crate::{model::text, tools::redact};
use anyhow::{bail, ensure, Context, Result};
use serde_json::{json, Value};
use std::path::Path;
use termpilot_core::vault::Vault;
pub const NAMES: &[&str] = &[
    "vault_hosts_create",
    "vault_hosts_update",
    "vault_hosts_delete",
    "host_notes_get",
    "host_notes_set",
    "vault_notes_get",
    "vault_notes_create",
    "vault_notes_update",
    "vault_notes_delete",
    "vault_notes_import",
    "vault_groups_create",
    "vault_groups_update",
    "vault_groups_delete",
    "portforward_rules_create",
    "portforward_rules_update",
    "portforward_rules_duplicate",
    "portforward_rules_delete",
];
fn error(e: termpilot_core::connection::CoreError) -> anyhow::Error {
    anyhow::anyhow!("{}", e.message)
}
fn flag(args: &Value, key: &str, default: bool) -> Result<bool> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(default),
        Some(Value::Bool(v)) => Ok(*v),
        Some(Value::String(v)) if v == "true" => Ok(true),
        Some(Value::String(v)) if v == "false" => Ok(false),
        _ => bail!("{key} must be true or false"),
    }
}
fn get(v: &Vault, collection: &str, id: &Value) -> Result<Value> {
    v.get(collection, id)
        .map_err(error)?
        .context("Vault record not found")
}
fn group_path(v: &Vault, path: &str, create: bool) -> Result<Value> {
    let mut parent = Value::Null;
    for component in path.split('/').filter(|s| !s.is_empty()) {
        ensure!(component != "." && component != "..", "Invalid group path");
        let found = v
            .list("groups")
            .map_err(error)?
            .into_iter()
            .find(|g| g["name"] == component && g["parentGroupID"] == parent);
        parent = if let Some(g) = found {
            g["id"].clone()
        } else {
            ensure!(create, "Group path not found");
            v.save(
                "groups",
                json!({"name":component,"parentGroupID":parent}),
                None,
            )
            .map_err(error)?["id"]
                .clone()
        };
    }
    Ok(parent)
}
fn host(v: &Vault, args: &Value, mut item: Value, create_groups: bool) -> Result<Value> {
    let map = [
        ("label", "label"),
        ("name", "label"),
        ("hostname", "hostname"),
        ("host", "hostname"),
        ("ip", "hostname"),
        ("port", "port"),
        ("username", "username"),
        ("password", "password"),
        ("keyPath", "identityFile"),
        ("keypath", "identityFile"),
        ("identityId", "credentialID"),
        ("proxyProfileId", "proxyProfileID"),
    ];
    for (key, value) in args.as_object().context("Invalid host")? {
        if key == "hostId" {
            continue;
        }
        if key == "group" {
            let path = value.as_str().context("Invalid group path")?;
            ensure!(
                !path.split('/').any(|p| p == "." || p == ".."),
                "Invalid group path"
            );
            if create_groups {
                item["groupID"] = group_path(v, path, true)?;
            } else {
                item["groupPath"] = json!(path);
                item["groupID"] = group_path(v, path, false).unwrap_or(Value::Null);
            }
        } else if key == "protocol" {
            ensure!(
                value == "ssh",
                "This connection protocol is not available to AI host tools"
            );
            item["connectionKind"] = json!("ssh");
        } else if let Some((_, to)) = map.iter().find(|(from, _)| key == from) {
            item[*to] = value.clone();
        } else {
            bail!("Host field {key} has no native connection implementation yet")
        }
    }
    termpilot_core::connection::validate_endpoint(
        text(&item, "hostname"),
        item["port"].as_u64().unwrap_or(22),
    )
    .map_err(error)?;
    if item["label"].is_null() {
        item["label"] = item["hostname"].clone();
    }
    if item["port"].is_null() {
        item["port"] = json!(22);
    }
    if !item["identityFile"].is_null() {
        item["authentication"] = json!("identityFile");
    } else if item["authentication"].is_null() {
        item["authentication"] = json!("password");
    }
    Vault::validate_record("hosts", item).map_err(error)
}
pub fn execute(directory: &Path, name: &str, args: &Value) -> Result<Value> {
    let v = Vault::open(directory, None).map_err(error)?;
    execute_in_vault(&v, name, args)
}
pub fn execute_in_vault(v: &Vault, name: &str, args: &Value) -> Result<Value> {
    match name {
        "vault_hosts_create" => {
            let input: Vec<Value> = serde_json::from_str(text(args, "hosts"))?;
            ensure!(input.len() <= 500, "Host batch limit is 500");
            let mut items = input
                .iter()
                .map(|a| host(&v, a, json!({}), false))
                .collect::<Result<Vec<_>>>()?;
            let dry = flag(args, "dryRun", false)?;
            let skip = flag(args, "skipDuplicates", true)?;
            let mut identities: Vec<Value> = v
                .list("hosts")
                .map_err(error)?
                .into_iter()
                .map(|h| {
                    json!([
                        h["hostname"],
                        h["username"].as_str().unwrap_or(""),
                        h["port"].as_u64().unwrap_or(22)
                    ])
                })
                .collect();
            let mut skipped = 0;
            if skip {
                items.retain(|h| {
                    let identity = json!([
                        h["hostname"],
                        h["username"].as_str().unwrap_or(""),
                        h["port"].as_u64().unwrap_or(22)
                    ]);
                    if identities.contains(&identity) {
                        skipped += 1;
                        false
                    } else {
                        identities.push(identity);
                        true
                    }
                });
            }
            if dry {
                return Ok(redact(
                    json!({"dryRun":true,"preview":items,"skipped":skipped,"created":0}),
                ));
            }
            for item in &mut items {
                if let Some(path) = item["groupPath"].as_str().map(str::to_owned) {
                    item["groupID"] = group_path(&v, &path, true)?;
                    item.as_object_mut().unwrap().remove("groupPath");
                }
            }
            let saved = v.save_batch("hosts", items).map_err(error)?;
            Ok(redact(
                json!({"dryRun":false,"created":saved.len(),"hosts":saved,"skipped":skipped}),
            ))
        }
        "vault_hosts_update" => {
            let item = get(&v, "hosts", &args["hostId"])?;
            Ok(redact(
                v.save("hosts", host(&v, args, item, true)?, None)
                    .map_err(error)?,
            ))
        }
        "vault_hosts_delete" => {
            v.delete("hosts", &args["hostId"]).map_err(error)?;
            Ok(json!({"deleted":true}))
        }
        "host_notes_get" => {
            let host = get(&v, "hosts", &args["hostId"])?;
            let note = v
                .list("notes")
                .map_err(error)?
                .into_iter()
                .find(|n| n["hostID"] == host["id"] && n["aiHostNotes"] == true);
            Ok(json!({"notes":note.as_ref().map(|n|text(n,"body")).unwrap_or("")}))
        }
        "host_notes_set" => {
            let host = get(&v, "hosts", &args["hostId"])?;
            let mut item=v.list("notes").map_err(error)?.into_iter().find(|n|n["hostID"]==host["id"]&&n["aiHostNotes"]==true).unwrap_or(json!({"hostID":host["id"],"title":format!("{} · 主机备注",text(&host,"label")),"aiHostNotes":true}));
            item["body"] = args["notes"].clone();
            v.save("notes", item, None).map_err(error)?;
            Ok(json!({"saved":true}))
        }
        "vault_notes_get" => {
            let item = get(&v, "notes", &args["noteId"])?;
            if let Some(expected) = args.get("expectedUpdatedAt") {
                ensure!(
                    *expected == item["updatedAt"],
                    "Note changed since it was read; reload before paging"
                );
            }
            let body = text(&item, "body");
            let utf16: Vec<u16> = body.encode_utf16().collect();
            let max = (args["maxChars"].as_u64().unwrap_or(6000) as usize).clamp(2, 6000);
            let mut offset = args["offset"].as_u64().unwrap_or(0) as usize;
            if let Some(q) = args["query"].as_str() {
                offset = body
                    .find(q)
                    .map(|n| body[..n].encode_utf16().count())
                    .unwrap_or(utf16.len());
            }
            ensure!(offset <= utf16.len(), "Note offset out of range");
            if offset > 0 && offset < utf16.len() && (0xdc00..=0xdfff).contains(&utf16[offset]) {
                offset -= 1;
            }
            let mut end = (offset + max).min(utf16.len());
            if end < utf16.len() && (0xdc00..=0xdfff).contains(&utf16[end]) {
                end -= 1;
            }
            Ok(
                json!({"id":item["id"],"title":item["title"],"content":String::from_utf16_lossy(&utf16[offset..end]),"nextOffset":end,"totalChars":utf16.len(),"updatedAt":item["updatedAt"]}),
            )
        }
        "vault_notes_create" | "vault_notes_update" => {
            let mut item = if name.ends_with("update") {
                get(&v, "notes", &args["noteId"])?
            } else {
                json!({"body":""})
            };
            for (key, value) in args.as_object().unwrap() {
                match key.as_str() {
                    "noteId" => {}
                    "content" => item["body"] = value.clone(),
                    "linkedHostIds" => {
                        let ids: Vec<String> =
                            serde_json::from_str(value.as_str().unwrap_or("[]"))?;
                        for id in &ids {
                            get(&v, "hosts", &json!(id))?;
                        }
                        item["linkedHostIds"] = json!(ids);
                        item["hostID"] = ids.first().map(|s| json!(s)).unwrap_or(Value::Null);
                    }
                    _ => item[key] = value.clone(),
                }
            }
            Ok(v.save("notes", item, None).map_err(error)?)
        }
        "vault_notes_delete" => {
            v.delete("notes", &args["noteId"]).map_err(error)?;
            Ok(json!({"deleted":true}))
        }
        "vault_notes_import" => {
            let documents = if let Some(d) = args["documents"].as_str() {
                serde_json::from_str::<Vec<Value>>(d)?
            } else {
                vec![args.clone()]
            };
            let items=documents.iter().map(|d|{let body=text(d,"content");let title=if !text(d,"title").is_empty(){text(d,"title").to_owned()}else{body.lines().find_map(|s|s.strip_prefix("# ")).unwrap_or(text(d,"fileName")).to_owned()};json!({"title":if title.is_empty(){"Imported note".into()}else{title},"body":body,"group":d["group"]})}).collect();
            Ok(json!(v.save_batch("notes", items).map_err(error)?))
        }
        "vault_groups_create" => {
            ensure!(
                args["defaults"].is_null() || text(args, "defaults") == "{}",
                "Group connection defaults require native resolver support"
            );
            let id = group_path(&v, text(args, "path"), true)?;
            Ok(get(&v, "groups", &id)?)
        }
        "vault_groups_update" => {
            ensure!(
                args["defaults"].is_null(),
                "Group connection defaults require native resolver support"
            );
            let id = group_path(&v, text(args, "path"), false)?;
            let mut group = get(&v, "groups", &id)?;
            if let Some(path) = args["newPath"].as_str() {
                let (parent, name) = path.rsplit_once('/').unwrap_or(("", path));
                group["name"] = json!(name);
                group["parentGroupID"] = group_path(&v, parent, true)?;
            }
            Ok(v.save("groups", group, None).map_err(error)?)
        }
        "vault_groups_delete" => {
            ensure!(
                text(args, "deleteHosts") != "true",
                "Deleting hosts with a group requires explicit host deletion calls"
            );
            let id = group_path(&v, text(args, "path"), false)?;
            v.delete("groups", &id).map_err(error)?;
            Ok(json!({"deleted":true}))
        }
        "portforward_rules_create" | "portforward_rules_update" | "portforward_rules_duplicate" => {
            let mut item = if name.ends_with("create") {
                json!({"name":"Forward","kind":"local","bindAddress":"127.0.0.1","remoteHost":"127.0.0.1","autoStart":false,"status":"inactive"})
            } else {
                get(&v, "forwards", &args["ruleId"])?
            };
            for (k, x) in args.as_object().unwrap() {
                let target = match k.as_str() {
                    "ruleId" => continue,
                    "label" => "name",
                    "type" => "kind",
                    "hostId" => "hostID",
                    x => x,
                };
                if ["autoStart", "autoReconnect"].contains(&target) {
                    let value = flag(args, k, false)?;
                    ensure!(target!="autoReconnect"||!value,"Automatic tunnel reconnect is not implemented in the native forwarding manager");
                    item[target] = json!(value);
                } else {
                    item[target] = x.clone();
                }
            }
            if name.ends_with("duplicate") {
                item["id"] = json!(uuid::Uuid::new_v4().to_string());
                item["name"] = json!(format!("{} copy", text(&item, "name")));
                item["autoStart"] = json!(false);
            }
            Ok(v.save("forwards", item, None).map_err(error)?)
        }
        "portforward_rules_delete" => {
            v.delete("forwards", &args["ruleId"]).map_err(error)?;
            Ok(json!({"deleted":true}))
        }
        _ => bail!("Unknown vault tool"),
    }
}
