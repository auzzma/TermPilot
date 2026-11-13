//! Compact into a fresh immutable generation before retiring any history.
//! Readers/writers hold the same renewable lease. An expired worker can only
//! delete an irrevocably retired namespace, never an active or staged generation.
use super::{
    control::{Head, Namespace},
    err,
    lease::Lease,
    model::{self, State},
    runtime,
    store::Store,
    transport::Objects,
    Result,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet};
const DAY: i64 = 86400;
#[derive(Clone, Serialize, Deserialize, Default)]
pub(super) struct History {
    pub compacted_at: i64,
    pub retired: Vec<Retired>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub staging: Vec<Staged>,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Staged {
    pub generation: String,
    pub started_at: i64,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Retired {
    pub generation: String,
    pub sequence: u64,
    pub retired_at: i64,
}
impl History {
    pub(super) fn validate(&self, head: &Head) -> Result<()> {
        let mut seen = BTreeSet::new();
        if self.retired.len() + self.staging.len() > 64
            || self.compacted_at < 0
            || self.retired.iter().any(|r| {
                r.generation == head.generation
                    || r.sequence >= head.sequence
                    || r.retired_at < 0
                    || (!r.generation.is_empty() && uuid::Uuid::parse_str(&r.generation).is_err())
                    || !seen.insert(r.generation.clone())
            })
            || self.staging.iter().any(|s| {
                s.generation == head.generation
                    || uuid::Uuid::parse_str(&s.generation).is_err()
                    || s.started_at < 0
                    || !seen.insert(s.generation.clone())
            })
        {
            return Err(err("syncCleanup", "云端历史保护信息无效，已停止清理。"));
        }
        Ok(())
    }
}
#[derive(Clone, Copy)]
pub(super) struct Policy {
    pub interval: i64,
    pub grace: i64,
    pub snapshots: i64,
    pub minimum: usize,
    pub batch: usize,
}
impl Default for Policy {
    fn default() -> Self {
        Self {
            interval: DAY,
            grace: 7 * DAY,
            snapshots: 30 * DAY,
            minimum: 64,
            batch: 128,
        }
    }
}
pub(super) fn content_object(name: &str) -> bool {
    let Some((base, hash)) = name.strip_suffix(".tps").and_then(|n| n.rsplit_once('-')) else {
        return false;
    };
    hash.len() == 64
        && hash.bytes().all(|b| b.is_ascii_hexdigit())
        && ["-chunk-", "-batch-", "-snapshot-", "-receipt-", "-catalog-"]
            .iter()
            .any(|kind| base.contains(kind) || base.ends_with(kind.trim_end_matches('-')))
}
fn prefix(library: &str, generation: &str) -> String {
    if generation.is_empty() {
        format!("tp1-{library}-")
    } else {
        format!("tp1-{library}-g-{generation}-")
    }
}
fn in_generation(name: &str, library: &str, generation: &str) -> bool {
    name.strip_prefix(&prefix(library, generation))
        .is_some_and(|suffix| {
            ["chunk-", "batch-", "snapshot-", "receipt-", "catalog-"]
                .iter()
                .any(|p| suffix.starts_with(p))
        })
        && content_object(name)
}
fn physical(name: &str, library: &str, generation: &str) -> Result<String> {
    let suffix = name
        .strip_prefix(&format!("tp1-{library}-"))
        .ok_or_else(|| err("syncCleanup", "历史对象不属于当前同步库。"))?;
    Ok(format!("{}{suffix}", prefix(library, generation)))
}
fn checked(cloud: &mut dyn Objects, name: &str) -> Result<Vec<u8>> {
    let bytes = cloud
        .get(name)?
        .ok_or_else(|| err("syncMissing", "同步对象缺失，保留全部历史文件并停止清理。"))?;
    if !name.ends_with(&format!("-{}.tps", hex::encode(Sha256::digest(&bytes)))) {
        return Err(err("syncIntegrity", "同步对象校验失败，保留全部历史文件。"));
    }
    Ok(bytes)
}
fn verify_current(cloud: &mut dyn Objects, lease: &Lease) -> Result<()> {
    let head = lease.head()?;
    for name in lease.names(cloud)? {
        lease.check(cloud)?;
        checked(cloud, &physical(&name, &head.library, &head.generation)?)?;
    }
    Ok(())
}
fn report(store: &Store<'_>, patch: Value) -> Result<()> {
    let mut value = store
        .get::<Value>("maintenanceStatus")?
        .unwrap_or(json!({}));
    if !value.is_object() {
        value = json!({});
    }
    for (k, v) in patch.as_object().unwrap() {
        value[k] = v.clone();
    }
    store.put("maintenanceStatus", &value)
}
pub(super) fn failed(store: &Store<'_>, message: &str) -> Result<()> {
    report(store, json!({"phase":"deferred","message":message}))
}
pub(super) fn run(
    store: &Store<'_>,
    cloud: &mut dyn Objects,
    lease: &Lease,
    policy: Policy,
) -> Result<bool> {
    lease.check(cloud)?;
    let now = super::lease::cloud_time(cloud)?;
    let last = store.get::<i64>("maintenanceCheck")?.unwrap_or(0);
    if last > 0 && now.saturating_sub(last) < policy.interval {
        return Ok(false);
    }
    store.put("maintenanceCheck", &now)?;
    report(
        store,
        json!({"phase":"checking","checkedAt":now,"deleted":0,"message":Value::Null}),
    )?;
    let config = store.config()?;
    let mut history = lease.head()?.maintenance.unwrap_or_default();
    let eligible: Vec<_> = history
        .retired
        .iter()
        .filter(|r| now.saturating_sub(r.retired_at) >= policy.grace)
        .map(|r| r.generation.clone())
        .chain(
            history
                .staging
                .iter()
                .filter(|s| now.saturating_sub(s.started_at) >= policy.grace)
                .map(|s| s.generation.clone()),
        )
        .collect();
    let mut deleted = 0;
    if !eligible.is_empty() {
        // Revalidate the complete active data, including scopes disabled locally,
        // before releasing even one fallback file.
        verify_current(cloud, lease)?;
        let listed = cloud.list()?;
        for retired in eligible {
            let names: Vec<_> = listed
                .iter()
                .filter(|n| in_generation(n, &config.library, &retired))
                .cloned()
                .collect();
            for name in names.into_iter().take(policy.batch.saturating_sub(deleted)) {
                lease.check(cloud)?;
                cloud.remove_retired(&name)?;
                deleted += 1;
                report(store, json!({"phase":"cleaning","deleted":deleted}))?;
            }
            lease.check(cloud)?;
            if !cloud
                .list()?
                .iter()
                .any(|n| in_generation(n, &config.library, &retired))
            {
                history.retired.retain(|r| r.generation != retired);
                history.staging.retain(|s| s.generation != retired);
                lease.update_history(cloud, history.clone())?;
            }
            if deleted >= policy.batch {
                break;
            }
        }
    }
    report(
        store,
        json!({"phase":"completed","deleted":deleted,"protectedGenerations":history.retired.len()}),
    )?;
    if history.retired.len() + history.staging.len() >= 64
        || (history.compacted_at > 0 && now.saturating_sub(history.compacted_at) < policy.interval)
    {
        return Ok(false);
    }
    let names = lease.names(cloud)?;
    let raw = cloud.list()?;
    if raw
        .iter()
        .filter(|n| in_generation(n, &config.library, &config.generation))
        .count()
        < policy.minimum
    {
        return Ok(false);
    }
    // Never compact a partially received causal history or unpublished payloads.
    let mut states = BTreeMap::new();
    for scope in &config.scopes {
        if !store.state(scope)?.waiting.is_empty() {
            return Ok(false);
        }
        let state = store.published_state(scope)?;
        let mut verify = State::default();
        verify.merge(state.clone())?;
        states.insert(scope.clone(), state);
    }
    let mut keep: BTreeSet<String> = names.iter().cloned().collect();
    let mut documents: BTreeMap<String, Vec<(String, super::runtime::Manifest, Value)>> =
        BTreeMap::new();
    {
        let mut namespace = Namespace {
            cloud,
            library: config.library.clone(),
            generation: config.generation.clone(),
            guard: Some(lease),
        };
        for name in &names {
            let Some(scope) = config.scopes.iter().find(|s| {
                ["batch", "receipt", "snapshot"]
                    .iter()
                    .any(|k| name.starts_with(&format!("tp1-{}-{k}-{s}-", config.library)))
            }) else {
                continue;
            };
            let (manifest, value, _) =
                runtime::open_document_with(&config, &mut namespace, name, scope, None)?;
            documents
                .entry(scope.clone())
                .or_default()
                .push((name.clone(), manifest, value));
        }
    }
    for (scope, docs) in &documents {
        let state = &states[scope];
        let mut snapshots: Vec<_> = docs
            .iter()
            .filter(|(_, m, _)| m.kind == "snapshot")
            .collect();
        snapshots.sort_by_key(|(n, _, v)| (v["at"].as_str().unwrap_or("").to_owned(), n.clone()));
        let recent: BTreeSet<_> = snapshots
            .iter()
            .rev()
            .take(1)
            .map(|(n, _, _)| n.as_str())
            .collect();
        let mut needed = BTreeSet::new();
        for (name, manifest, value) in docs {
            let drop = match manifest.kind.as_str() {
                "batch" => {
                    let ops: Vec<model::Operation> = serde_json::from_value(value.clone())
                        .map_err(|_| err("syncCleanup", "历史增量格式无效。"))?;
                    if ops
                        .iter()
                        .any(|op| state.fingerprints.get(&op.dot.key()) != Some(&model::hash(op)))
                    {
                        return Err(err("syncCleanup", "仍有未纳入快照的操作，暂停历史清理。"));
                    }
                    true
                }
                "receipt" => {
                    let ids: Vec<String> = serde_json::from_value(value["deletions"].clone())
                        .map_err(|_| err("syncCleanup", "历史确认信息无效。"))?;
                    if ids
                        .iter()
                        .any(|id| state.published.get(id).copied() != value["publishedAt"].as_i64())
                    {
                        return Err(err("syncCleanup", "删除保护信息尚未完整归档。"));
                    }
                    true
                }
                "snapshot" => {
                    let snapshot: State =
                        serde_json::from_value(value.get("state").unwrap_or(value).clone())
                            .map_err(|_| err("syncSnapshot", "历史快照无效。"))?;
                    let mut check = State::default();
                    check.merge(snapshot)?;
                    !recent.contains(name.as_str())
                        && value["at"]
                            .as_str()
                            .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
                            .is_some_and(|t| now.saturating_sub(t.timestamp()) > policy.snapshots)
                }
                _ => false,
            };
            if drop {
                keep.remove(name);
            } else {
                needed.extend(manifest.chunks.iter().cloned());
            }
        }
        for name in &names {
            if name.starts_with(&format!("tp1-{}-chunk-{scope}-", config.library))
                && !needed.contains(name)
            {
                keep.remove(name);
            }
        }
    }
    let stale_catalogs = raw
        .iter()
        .filter(|n| {
            in_generation(n, &config.library, &config.generation) && n.contains("-catalog-")
        })
        .count();
    if keep.len() == names.len()
        && stale_catalogs <= lease.head()?.catalog.unwrap_or_default().len() + 16
    {
        return Ok(false);
    }
    report(store, json!({"phase":"compacting"}))?;
    let mut next = config.clone();
    next.generation = uuid::Uuid::new_v4().to_string();
    next.generation_sequence = next
        .generation_sequence
        .checked_add(1)
        .ok_or_else(|| err("syncCleanup", "同步版本已达到上限。"))?;
    // Register staging durably before any upload. After a crash, a future lease
    // may collect this abandoned namespace after the same protection period.
    history.staging.push(Staged {
        generation: next.generation.clone(),
        started_at: now,
    });
    lease.update_history(cloud, history.clone())?;
    let mut published = Vec::new();
    for name in keep {
        lease.check(cloud)?;
        let bytes = checked(
            cloud,
            &physical(&name, &config.library, &config.generation)?,
        )?;
        let target = physical(&name, &config.library, &next.generation)?;
        cloud.put(&target, &bytes)?;
        if checked(cloud, &target)? != bytes {
            return Err(err("syncVerify", "历史整理校验失败，原数据保持不变。"));
        }
        published.push(name);
    }
    let at = chrono::DateTime::from_timestamp(now, 0)
        .ok_or_else(|| err("syncLeaseClock", "云服务时间无效。"))?
        .to_rfc3339();
    let snapshot_id = uuid::Uuid::new_v4().to_string();
    for (scope, state) in states {
        let document = json!({"id":snapshot_id,"at":at,"scopes":config.scopes,"state":state});
        let (manifest, objects) = runtime::encode_document(&next, &scope, "snapshot", &document)?;
        for (name, bytes, _, _) in objects {
            lease.check(cloud)?;
            let target = physical(&name, &config.library, &next.generation)?;
            cloud.put(&target, &bytes)?;
            checked(cloud, &target)?;
            published.push(name);
        }
        let mut target = Namespace {
            cloud,
            library: next.library.clone(),
            generation: next.generation.clone(),
            guard: Some(lease),
        };
        let (_, readback, _) =
            runtime::open_document_with(&next, &mut target, &manifest, &scope, None)?;
        if readback != document {
            return Err(err("syncVerify", "新快照恢复验证失败，原数据保持不变。"));
        }
    }
    history.compacted_at = now;
    history.staging.retain(|s| s.generation != next.generation);
    history.retired.push(Retired {
        generation: config.generation.clone(),
        sequence: config.generation_sequence,
        retired_at: now,
    });
    // This single CAS is the only publication point. A lost reply is recovered
    // through adopt_matching on the next run; no old generation is deleted here.
    lease.compact(cloud, &next, published, history.clone())?;
    super::rekey::switch_local(store, next)?;
    report(
        store,
        json!({"phase":"completed","compactedAt":now,"protectedGenerations":history.retired.len(),"deleted":deleted}),
    )?;
    Ok(true)
}
