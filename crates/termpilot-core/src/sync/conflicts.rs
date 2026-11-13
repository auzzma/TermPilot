//! Human-readable conflict descriptions. Secrets never enter the status payload;
//! revealing a selected candidate is a separate, explicit in-memory request.
use super::{
    err,
    model::{Candidate, Record, State},
    policy,
    store::{Config, Store},
    Result,
};
use hmac::{Hmac, Mac};
use serde_json::{json, Value};
use sha2::Sha256;
fn label(collection: &str) -> &str {
    match collection {
        "hosts" => "主机",
        "host_groups" => "主机分组",
        "ssh_credentials" => "SSH 凭证",
        "ssh_proxy_profiles" => "代理",
        "screen_sharing_profiles" => "屏幕共享配置",
        "automation_scripts" => "自动化脚本",
        "host_notes" => "主机笔记",
        "port_forward_rules" => "端口转发",
        "preferences" => "应用偏好",
        "ai:providers" => "AI 服务",
        "ai:models" => "AI 模型",
        "ai:settings" => "AI 设置",
        "ai:prompts" => "AI 提示词",
        "ai:conversations" => "AI 对话",
        "ai:messages" => "AI 消息",
        _ => "记录",
    }
}
fn field_label(field: &str) -> String {
    match field {
        "label" | "name" | "title" => "名称",
        "hostname" | "host" | "address" | "ip" => "主机地址 / IP",
        "port" => "端口",
        "username" | "user" => "登录用户名",
        "sort_order" | "sortOrder" => "排列顺序",
        "group_id" | "groupID" => "所属分组",
        "credential_id" | "credentialID" | "credential_reference" => "使用的 SSH 凭证",
        "proxy_profile_id" => "使用的代理",
        "password" => "登录密码",
        "private_key" | "privateKey" | "private_key_pem" => "SSH 私钥",
        "passphrase" | "key_passphrase" => "私钥口令",
        "authentication" => "认证方式",
        "$authentication" => "登录与认证配置",
        "connection_kind" => "连接类型",
        "protocol" => "连接协议",
        "kind" | "type" => "类型",
        "note" | "notes" | "content" => "内容",
        "script" | "body" => "脚本内容",
        "enabled" => "是否启用",
        "proxy" => "代理配置",
        "color" => "颜色",
        "icon" => "图标",
        "tags" => "标签",
        "api_key" | "apiKey" => "API Key",
        "endpoint" | "baseURL" => "服务地址",
        "headers" | "customHeaders" => "认证请求头",
        "local_port" => "本地端口",
        "remote_port" => "远端端口",
        "remote_host" => "远端地址",
        "parent_id" => "上级分组",
        "theme" => "主题",
        "font_size" => "字体大小",
        _ => return format!("配置项：{field}"),
    }
    .into()
}
fn text(value: &Value) -> String {
    match value {
        Value::Null => "未设置".into(),
        Value::Bool(true) => "开启".into(),
        Value::Bool(false) => "关闭".into(),
        Value::String(s) if s.is_empty() => "空值".into(),
        Value::String(s) => s.clone(),
        _ => serde_json::to_string_pretty(value).unwrap_or_default(),
    }
}
fn secret(scope: &str, field: &str) -> bool {
    matches!(scope, "credentials" | "aiSecrets") || policy::secret(field)
}
fn identity(record: &Record) -> Option<String> {
    ["label", "name", "title"].into_iter().find_map(|field| {
        record.fields.get(field).and_then(|values| {
            let names: std::collections::BTreeSet<_> = values
                .iter()
                .filter_map(|c| c.value.as_str())
                .filter(|s| !s.is_empty())
                .collect();
            (!names.is_empty()).then(|| names.into_iter().collect::<Vec<_>>().join(" / "))
        })
    })
}
fn revision(store: &Store<'_>, scope: &str, id: &str, record: &Record) -> Result<String> {
    let config = store.config()?;
    let key = config
        .scope_keys
        .get("configuration")
        .ok_or_else(|| err("syncKey", "缺少同步密钥。"))?;
    let mut mac =
        Hmac::<Sha256>::new_from_slice(key).map_err(|_| err("syncKey", "同步密钥无效。"))?;
    mac.update(b"TermPilot:conflict:1:");
    mac.update(&serde_json::to_vec(&(scope, id, record)).unwrap());
    Ok(hex::encode(mac.finalize().into_bytes()))
}
pub(super) fn check_revision(
    store: &Store<'_>,
    request: &Value,
    state: &State,
    id: &str,
) -> Result<()> {
    let record = state
        .records
        .get(id)
        .filter(|r| r.conflicted())
        .ok_or_else(|| err("syncConflict", "此冲突已解决，请刷新列表。"))?;
    if request.get("revision").is_some()
        && request["revision"].as_str()
            != Some(
                revision(
                    store,
                    request["scope"].as_str().unwrap_or("configuration"),
                    id,
                    record,
                )?
                .as_str(),
            )
    {
        return Err(err(
            "syncConflict",
            "冲突已有新版本，请刷新后重新比较，尚未保存选择。",
        ));
    }
    Ok(())
}
fn source(candidate: &Candidate, state: &State, config: &Config) -> Value {
    let source = state.sources.get(&candidate.dot.key());
    json!({"name":source.map(|s|s.name.as_str()).filter(|s|!s.is_empty()).unwrap_or("旧版本：未记录来源设备"),
        "at":source.map(|s|s.at.as_str()),"local":source.is_some_and(|s|s.device==config.device),
        "version":candidate.dot.key(),"writer":candidate.dot.writer})
}
pub(super) fn describe(
    store: &Store<'_>,
    config: &Config,
    scope: &str,
    id: &str,
    record: &Record,
    state: &State,
) -> Result<Value> {
    let (collection, record_id) = id.split_once('/').unwrap_or(("", id));
    let context = store.state("configuration")?;
    let related = context.records.get(id);
    let name = identity(record)
        .or_else(|| related.and_then(identity))
        .unwrap_or_else(|| {
            format!(
                "未命名{} · {}",
                label(collection),
                record_id.chars().take(8).collect::<String>()
            )
        });
    let contextual = related.unwrap_or(record).value();
    let address = ["hostname", "address", "host", "ip"]
        .iter()
        .find_map(|key| contextual[*key].as_str())
        .unwrap_or("");
    let subtitle = if !address.is_empty() {
        format!(
            "{}{}",
            address,
            contextual["port"]
                .as_u64()
                .map(|p| format!(":{p}"))
                .unwrap_or_default()
        )
    } else {
        label(collection).into()
    };
    let mut details = Vec::new();
    for (field, candidates) in &record.fields {
        let different = candidates
            .iter()
            .any(|c| candidates.first().is_some_and(|f| f.value != c.value));
        let concurrent = record.deleted()
            && candidates
                .iter()
                .any(|c| record.deletes.values().all(|d| !c.dot.observed(&d.basis)));
        if !different && !concurrent {
            continue;
        }
        let hidden = secret(scope, field);
        let mut choices = Vec::new();
        for candidate in candidates {
            let mut display = if hidden {
                "敏感内容已隐藏".into()
            } else if field == "$authentication" {
                candidate.value.as_object().map(|fields| fields.iter().map(|(key,value)| {
                    let value = if key == "credential_reference" {
                        value.as_str().and_then(|id| context.records.get(&format!("ssh_credentials/{id}"))).and_then(identity).unwrap_or_else(||text(value))
                    } else { text(value) };
                    format!("{}：{value}",field_label(key))
                }).collect::<Vec<_>>().join("\n")).unwrap_or_else(||text(&candidate.value))
            } else {
                text(&candidate.value)
            };
            let target = match field.as_str() {
                "group_id" | "groupID" => Some("host_groups"),
                "credential_id" | "credentialID" | "credential_reference" => Some("ssh_credentials"),
                "proxy_profile_id" => Some("ssh_proxy_profiles"),
                _ => None,
            };
            if let (Some(target), Some(id)) = (target, candidate.value.as_str()) {
                if let Some(title) = context
                    .records
                    .get(&format!("{target}/{id}"))
                    .and_then(identity)
                {
                    display = format!("{title}（{id}）");
                }
            }
            choices.push(json!({"dot":candidate.dot,"display":display,"source":source(candidate,state,config),"secret":hidden}));
        }
        details.push(json!({"key":field,"label":field_label(field),"secret":hidden,"candidates":choices,
            "hint":if matches!(field.as_str(),"sort_order"|"sortOrder"){"这是列表中的排列顺序，不是主机地址或连接信息。数值越小越靠前。"}else if hidden {"仅在需要比较时显示内容；选择会应用到已启用此同步范围的设备。"}else{"请比较各版本，选择需要保留的值。"}}));
    }
    // Retain the old shape for existing internal consumers, with exactly the
    // same secret boundary as the richer presentation.
    let mut fields = record.fields.clone();
    for (field, candidates) in &mut fields {
        if secret(scope, field) {
            for c in candidates {
                c.value = json!("••••••");
            }
        }
    }
    Ok(
        json!({"id":id,"scope":scope,"collection":collection,"title":format!("{}：{name}",label(collection)),"subtitle":subtitle,
        "deleted":record.deleted(),"revision":revision(store,scope,id,record)?,"fields":fields,"details":details,
        "deletions":record.deletes.values().map(|c|source(c,state,config)).collect::<Vec<_>>(),
        "recycleIds":record.deletes.keys().cloned().collect::<Vec<_>>()}),
    )
}
pub(super) fn preview(store: &Store<'_>, request: &Value) -> Result<Value> {
    if request["reveal"] != true {
        return Err(err("syncConfirmation", "请明确选择显示此版本的敏感内容。"));
    }
    let scope = request["scope"].as_str().unwrap_or("");
    if !store.config()?.scopes.iter().any(|s| s == scope) {
        return Err(err("syncScope", "当前设备未启用此同步范围。"));
    }
    let id = request["id"].as_str().unwrap_or("");
    let state = store.state(scope)?;
    check_revision(store, request, &state, id)?;
    let field = request["field"].as_str().unwrap_or("");
    let dot: super::model::Dot = serde_json::from_value(request["dot"].clone())
        .map_err(|_| err("syncConflict", "请选择要查看的版本。"))?;
    let candidate = state.records[id]
        .fields
        .get(field)
        .and_then(|v| v.iter().find(|c| c.dot == dot))
        .ok_or_else(|| err("syncConflict", "版本已变化，请刷新后再查看。"))?;
    Ok(json!({"display":text(&candidate.value)}))
}
