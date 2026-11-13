use super::{
    db_error, err, journal,
    model::*,
    policy, projection,
    store::{Config, Store},
    transport::{Backend, Objects, Provider},
    Result,
};
use crate::vault::{crypto, Vault};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{collections::BTreeMap, path::Path};

#[derive(Serialize, Deserialize)]
pub(super) struct Manifest {
    version: u32,
    pub kind: String,
    scope: String,
    pub(super) chunks: Vec<String>,
    digest: String,
    size: usize,
    #[serde(default)]
    compression: Option<String>,
    #[serde(default)]
    operations: BTreeMap<String, String>,
    #[serde(skip)]
    covered: bool,
}
fn digest(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn aad(library: &str, scope: &str) -> String {
    format!("TermPilot:sync:1:{library}:{scope}")
}
fn key<'a>(config: &'a Config, scope: &str) -> Result<&'a [u8]> {
    config
        .scope_keys
        .get(scope)
        .map(Vec::as_slice)
        .ok_or_else(|| err("syncKey", "此设备尚未获得当前范围的密钥。"))
}
pub(super) type EncodedObjects = Vec<(String, Vec<u8>, String, String)>;
pub(super) fn encode_document(
    config: &super::store::Config,
    scope: &str,
    kind: &str,
    value: &impl Serialize,
) -> Result<(String, EncodedObjects)> {
    let mut objects = Vec::new();
    let clear = zeroize::Zeroizing::new(
        serde_json::to_vec(value).map_err(|_| err("syncEncode", "无法编码同步内容。"))?,
    );
    if clear.len() > 128 * 1024 * 1024 {
        return Err(err(
            "syncSize",
            "单个同步文档超过允许大小，请缩小历史范围。",
        ));
    }
    use std::io::Write;
    let mut compressor = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::fast());
    compressor
        .write_all(&clear)
        .map_err(|_| err("syncEncode", "无法压缩同步数据。"))?;
    let compressed = zeroize::Zeroizing::new(
        compressor
            .finish()
            .map_err(|_| err("syncEncode", "无法压缩同步数据。"))?,
    );
    let use_compression = clear.len() > 2048 && compressed.len() < clear.len() * 4 / 5;
    let input = if use_compression {
        compressed.as_slice()
    } else {
        clear.as_slice()
    };
    let cipher = crypto::seal(
        key(&config, scope)?,
        input,
        aad(&config.library, scope).as_bytes(),
    )?;
    let mut chunks = Vec::new();
    for part in cipher.chunks(384 * 1024) {
        let name = format!(
            "tp1-{}-chunk-{}-{}.tps",
            config.library,
            scope,
            digest(part)
        );
        objects.push((name.clone(), part.to_vec(), "chunk".into(), scope.into()));
        chunks.push(name);
    }
    let manifest = Manifest {
        version: 1,
        kind: kind.into(),
        scope: scope.into(),
        chunks,
        digest: digest(&cipher),
        size: cipher.len(),
        compression: use_compression.then(|| "zlib".into()),
        operations: if kind == "batch" {
            serde_json::from_slice::<Vec<Operation>>(&clear)
                .map_err(|_| err("syncEncode", "增量格式无效。"))?
                .iter()
                .map(|op| (op.dot.key(), hash(op)))
                .collect()
        } else {
            BTreeMap::new()
        },
        covered: false,
    };
    let sealed = crypto::seal(
        key(&config, scope)?,
        &serde_json::to_vec(&manifest).unwrap(),
        aad(&config.library, scope).as_bytes(),
    )?;
    let name = format!(
        "tp1-{}-{}-{}-{}.tps",
        config.library,
        kind,
        scope,
        digest(&sealed)
    );
    objects.push((name.clone(), sealed, kind.into(), scope.into()));
    Ok((name, objects))
}
fn queue(store: &Store<'_>, scope: &str, kind: &str, value: &impl Serialize) -> Result<String> {
    let (name, objects) = encode_document(&store.config()?, scope, kind, value)?;
    for (name, payload, kind, scope) in objects {
        store.db.execute("INSERT OR IGNORE INTO tp_sync_objects(name,payload,kind,scope) VALUES(?1,?2,?3,?4)",params![name,payload,kind,scope]).map_err(db_error)?;
    }
    Ok(name)
}
fn open_document(
    store: &Store<'_>,
    cloud: &mut dyn Objects,
    name: &str,
    scope: &str,
) -> Result<(Manifest, Value, String)> {
    open_document_with(&store.config()?, cloud, name, scope, Some(store))
}
pub(super) fn open_document_with(
    config: &super::store::Config,
    cloud: &mut dyn Objects,
    name: &str,
    scope: &str,
    store: Option<&Store<'_>>,
) -> Result<(Manifest, Value, String)> {
    let data = cloud
        .get(name)?
        .ok_or_else(|| err("syncMissing", "同步对象尚未完整发布，稍后重试。"))?;
    super::progress::bytes("downloadedBytes", data.len());
    let fingerprint = digest(&data);
    if !name.ends_with(&format!("-{fingerprint}.tps")) {
        return Err(err("syncIntegrity", "云端对象校验失败。"));
    }
    let mut manifest: Manifest = serde_json::from_slice(&crypto::unseal(
        key(&config, scope)?,
        &data,
        aad(&config.library, scope).as_bytes(),
    )?)
    .map_err(|_| err("syncManifest", "快照或增量清单损坏。"))?;
    if manifest.version != 1
        || !name.starts_with(&format!(
            "tp1-{}-{}-{scope}-",
            config.library, manifest.kind
        ))
        || manifest.scope != scope
        || manifest.size > 128 * 1024 * 1024
        || manifest.chunks.len() > 512
    {
        return Err(err("syncVersion", "同步清单版本或大小无效。"));
    }
    if let Some(store) =
        store.filter(|_| manifest.kind == "batch" && !manifest.operations.is_empty())
    {
        let state = store.state(scope)?;
        let covered = manifest.operations.iter().all(|(id, digest)| {
            state.fingerprints.get(id) == Some(digest)
                && id.rsplit_once(':').is_some_and(|(writer, seq)| {
                    seq.parse::<u64>()
                        .is_ok_and(|seq| seq <= state.frontier.get(writer).copied().unwrap_or(0))
                })
        });
        if covered {
            manifest.covered = true;
            return Ok((manifest, json!([]), fingerprint));
        }
    }
    let mut content = Vec::new();
    for part in &manifest.chunks {
        if !part.starts_with(&format!("tp1-{}-chunk-{scope}-", config.library)) {
            return Err(err("syncManifest", "同步分块引用无效。"));
        }
        let bytes = cloud
            .get(part)?
            .ok_or_else(|| err("syncMissing", "同步分块缺失，本机数据未替换。"))?;
        if !part.ends_with(&format!("-{}.tps", digest(&bytes))) {
            return Err(err("syncIntegrity", "同步分块校验失败。"));
        }
        super::progress::bytes("downloadedBytes", bytes.len());
        content.extend_from_slice(&bytes);
        if content.len() > manifest.size {
            return Err(err("syncSize", "同步分块长度超出清单。"));
        }
    }
    if content.len() != manifest.size || digest(&content) != manifest.digest {
        return Err(err("syncIntegrity", "同步内容未完整接收。"));
    }
    let clear = crypto::unseal(
        key(&config, scope)?,
        &content,
        aad(&config.library, scope).as_bytes(),
    )?;
    let decoded = if let Some(codec) = manifest.compression.as_deref() {
        if codec != "zlib" {
            return Err(err("syncVersion", "不支持此同步压缩格式，请更新应用。"));
        }
        use std::io::Read;
        let mut decoded = zeroize::Zeroizing::new(Vec::new());
        flate2::read::ZlibDecoder::new(clear.as_slice())
            .take(128 * 1024 * 1024 + 1)
            .read_to_end(&mut decoded)
            .map_err(|_| err("syncDecode", "压缩数据损坏。"))?;
        if decoded.len() > 128 * 1024 * 1024 {
            return Err(err("syncSize", "解压内容超过允许大小。"));
        }
        decoded
    } else {
        clear
    };
    let value =
        serde_json::from_slice(&decoded).map_err(|_| err("syncDecode", "同步内容格式无效。"))?;
    Ok((manifest, value, fingerprint))
}
fn prepare_outbox(store: &Store<'_>) -> Result<()> {
    store.db.execute_batch("CREATE TABLE IF NOT EXISTS tp_sync_object_ops(name TEXT NOT NULL,scope TEXT NOT NULL,writer TEXT NOT NULL,seq INTEGER NOT NULL,PRIMARY KEY(scope,writer,seq));").map_err(db_error)?;
    for scope in &store.config()?.scopes {
        let mut statement=store.db.prepare("SELECT payload FROM tp_sync_operations o WHERE scope=?1 AND published=0 AND NOT EXISTS(SELECT 1 FROM tp_sync_object_ops b WHERE b.scope=o.scope AND b.writer=o.writer AND b.seq=o.seq) ORDER BY writer,seq LIMIT 100").map_err(db_error)?;
        loop {
            let blobs = statement
                .query_map([scope], |r| r.get::<_, Vec<u8>>(0))
                .map_err(db_error)?
                .collect::<rusqlite::Result<Vec<_>>>()
                .map_err(db_error)?;
            if blobs.is_empty() {
                break;
            }
            let operations = blobs
                .iter()
                .map(|b| store.decode::<Operation>(b))
                .collect::<Result<Vec<_>>>()?;
            let name = queue(store, scope, "batch", &operations)?;
            for op in operations {
                store
                    .db
                    .execute(
                        "INSERT INTO tp_sync_object_ops VALUES(?1,?2,?3,?4)",
                        params![name, scope, op.dot.writer, op.dot.seq],
                    )
                    .map_err(db_error)?;
            }
        }
    }
    Ok(())
}
pub(super) fn exchange(store: &Store<'_>, cloud: &mut dyn Objects) -> Result<Value> {
    let config = store.config()?;
    super::progress::stage("listing", 0, None);
    let mut names = cloud.list()?;
    // Receipts are meaningful only after their source batch is verified.
    names.sort_by_key(|n| {
        if n.contains("-receipt-") {
            2
        } else if n.contains("-snapshot-") {
            0
        } else {
            1
        }
    });
    let listed: std::collections::BTreeSet<_> = names.iter().cloned().collect();
    let mut seen = store
        .db
        .prepare("SELECT name FROM tp_sync_received")
        .map_err(db_error)?;
    let seen = seen
        .query_map([], |r| r.get::<_, String>(0))
        .map_err(db_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(db_error)?;
    if seen.iter().any(|name| !listed.contains(name)) {
        return Err(err(
            "syncRollback",
            "云端缺少此前已确认的对象。已暂停同步并保留本机数据，请检查云端版本或权限。",
        ));
    }
    let total_downloads = names
        .iter()
        .filter(|name| {
            !seen.contains(name)
                && config.scopes.iter().any(|scope| {
                    ["batch", "snapshot", "receipt"].iter().any(|kind| {
                        name.starts_with(&format!("tp1-{}-{kind}-{scope}-", config.library))
                    })
                })
        })
        .count();
    super::progress::stage("downloading", 0, Some(total_downloads));
    let mut downloaded = 0;
    // Validate and commit one complete object at a time. Failure never acknowledges a partial batch.
    for name in names {
        let scope = config.scopes.iter().find(|s| {
            ["batch", "snapshot", "receipt"]
                .iter()
                .any(|kind| name.starts_with(&format!("tp1-{}-{kind}-{s}-", config.library)))
        });
        let Some(scope) = scope else { continue };
        let known: bool = store
            .db
            .query_row(
                "SELECT EXISTS(SELECT 1 FROM tp_sync_received WHERE name=?1)",
                [&name],
                |r| r.get(0),
            )
            .map_err(db_error)?;
        if known {
            continue;
        }
        let (manifest, value, fingerprint) = open_document(store, cloud, &name, scope)?;
        store.transaction(|| {
            match manifest.kind.as_str() {
                "batch" => {
                    let operations: Vec<Operation> = serde_json::from_value(value)
                        .map_err(|_| err("syncOperation", "增量批次无效。"))?;
                    for operation in operations {
                        store.receive(&operation, true)?;
                    }
                }
                // A snapshot is an acceleration checkpoint, never a deletion signal for absent records.
                "snapshot" => {
                    let snapshot: State = serde_json::from_value(value.get("state").unwrap_or(&value).clone())
                        .map_err(|_| err("syncSnapshot", "快照内容无效。"))?;
                    store.put(&format!("snapshot:{name}"),&snapshot)?;
                    let snapshot_id=value["id"].as_str().unwrap_or(&name);
                    let mut catalog=store.get::<Vec<Value>>("snapshots")?.unwrap_or_default();
                    if let Some(entry)=catalog.iter_mut().find(|v|v["id"]==snapshot_id){
                        let objects=entry["objects"].as_array_mut().ok_or_else(||err("syncSnapshot","快照目录无效。"))?;
                        if !objects.iter().any(|v|v["name"]==name){objects.push(json!({"scope":scope,"name":name,"frontier":snapshot.frontier}));}
                    }else{catalog.push(json!({"id":snapshot_id,"at":value["at"],"scopes":value["scopes"],"objects":[{"scope":scope,"name":name,"frontier":snapshot.frontier}],"verified":true}));}
                    store.put("snapshots",&catalog)?;
                    let mut baseline = store
                        .get::<State>(&format!("baseline:{scope}"))?
                        .unwrap_or_default();
                    baseline.merge(snapshot.clone())?;
                    store.put(&format!("baseline:{scope}"), &baseline)?;
                    let mut current = store.state(scope)?;
                    current.merge(snapshot)?;
                    store.save_state(scope, &current)?;
                }
                "receipt" => {
                    let source = value["source"].as_str().unwrap_or("");
                    if !source.starts_with(&format!("tp1-{}-batch-{scope}-", config.library))
                        || !store
                            .db
                            .query_row(
                                "SELECT EXISTS(SELECT 1 FROM tp_sync_received WHERE name=?1)",
                                [source],
                                |r| r.get::<_, bool>(0),
                            )
                            .map_err(db_error)?
                    {
                        return Err(err("syncReceipt", "发布确认缺少已验证的增量批次。"));
                    }
                    let time = value["publishedAt"]
                        .as_i64()
                        .ok_or_else(|| err("syncReceipt", "发布确认时间无效。"))?;
                    let ids: Vec<String> = serde_json::from_value(value["deletions"].clone())
                        .map_err(|_| err("syncReceipt", "发布确认格式无效。"))?;
                    let mut state = store.state(scope)?;
                    for id in ids {
                        state.publication(&id, time);
                    }
                    store.save_state(scope, &state)?;
                }
                _ => return Err(err("syncVersion", "未知同步文档类型。")),
            }
            store
                .db
                .execute(
                    "INSERT INTO tp_sync_received VALUES(?1,?2)",
                    params![name, fingerprint],
                )
                .map_err(db_error)?;
            for chunk in manifest.chunks.iter().filter(|_|!manifest.covered) {
                let hash = chunk
                    .trim_end_matches(".tps")
                    .rsplit('-')
                    .next()
                    .unwrap_or("");
                store
                    .db
                    .execute(
                        "INSERT OR IGNORE INTO tp_sync_received VALUES(?1,?2)",
                        params![chunk, hash],
                    )
                    .map_err(db_error)?;
            }
            Ok(())
        })?;
        downloaded += 1;
        super::progress::stage("downloading", downloaded, Some(total_downloads));
    }
    super::progress::stage("encrypting", 0, None);
    store.transaction(|| prepare_outbox(store))?;
    let mut statement=store.db.prepare("SELECT name,payload,kind,scope FROM tp_sync_objects WHERE published=0 ORDER BY CASE WHEN kind='chunk' THEN 0 ELSE 1 END,name").map_err(db_error)?;
    let pending = statement
        .query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, Vec<u8>>(1)?,
                r.get::<_, String>(2)?,
                r.get::<_, String>(3)?,
            ))
        })
        .map_err(db_error)?
        .collect::<rusqlite::Result<Vec<_>>>()
        .map_err(db_error)?;
    let total_uploads = pending
        .iter()
        .filter(|(_, _, _, scope)| config.scopes.contains(scope))
        .count();
    super::progress::stage("uploading", 0, Some(total_uploads));
    let mut uploaded = 0;
    for (name, data, kind, scope) in pending {
        if !config.scopes.contains(&scope) {
            continue;
        }
        super::progress::stage("uploading", uploaded, Some(total_uploads));
        cloud.put(&name, &data)?;
        super::progress::bytes("uploadedBytes", data.len());
        super::progress::stage("verifying", uploaded, Some(total_uploads));
        // Read-back is required even for providers returning a successful upload response.
        if cloud.get(&name)?.as_deref() != Some(&data) {
            return Err(err("syncVerify", "云端重新读取不一致，未确认上传。"));
        }
        super::progress::bytes("verifiedBytes", data.len());
        store.transaction(||{
            store.db.execute("UPDATE tp_sync_objects SET published=1 WHERE name=?1",[&name]).map_err(db_error)?;
            if kind=="batch"{
                store.db.execute("UPDATE tp_sync_operations SET published=1 WHERE EXISTS(SELECT 1 FROM tp_sync_object_ops b WHERE b.name=?1 AND b.scope=tp_sync_operations.scope AND b.writer=tp_sync_operations.writer AND b.seq=tp_sync_operations.seq)",[&name]).map_err(db_error)?;
                if let Some(time)=cloud.server_time(){
                    let mut q=store.db.prepare("SELECT o.scope,o.payload FROM tp_sync_operations o JOIN tp_sync_object_ops b ON b.scope=o.scope AND b.writer=o.writer AND b.seq=o.seq WHERE b.name=?1").map_err(db_error)?;
                    let values=q.query_map([&name],|r|Ok((r.get::<_,String>(0)?,r.get::<_,Vec<u8>>(1)?))).map_err(db_error)?.collect::<rusqlite::Result<Vec<_>>>().map_err(db_error)?;
                    let mut deletions:BTreeMap<String,Vec<String>>=BTreeMap::new();
                    for (scope,bytes) in values {let op:Operation=store.decode(&bytes)?;if matches!(op.action,Action::Delete{..}){deletions.entry(scope).or_default().push(op.dot.key());}}
                    for (scope,ids) in deletions {let mut state=store.state(&scope)?;for id in &ids{state.publication(id,time);}store.save_state(&scope,&state)?;queue(store,&scope,"receipt",&json!({"source":name,"deletions":ids,"publishedAt":time}))?;}
                }
            }
            store.db.execute("INSERT OR IGNORE INTO tp_sync_received VALUES(?1,?2)",params![name,digest(&data)]).map_err(db_error)?;
            Ok(())
        })?;
        uploaded += 1;
        super::progress::stage("uploading", uploaded, Some(total_uploads));
    }
    store.put(
        "lastCheck",
        &json!({"at":chrono::Utc::now().to_rfc3339(),"uploaded":uploaded,"downloaded":downloaded}),
    )?;
    Ok(json!({"uploaded":uploaded,"downloaded":downloaded}))
}
pub(super) fn ai_database(vault: &Vault) -> Result<Option<Connection>> {
    let path = vault.directory.join("ai.sqlite");
    if !path.exists() {
        return Ok(None);
    }
    let db = Connection::open(path).map_err(db_error)?;
    db.busy_timeout(std::time::Duration::from_secs(5))
        .map_err(db_error)?;
    journal::register(&db, &vault.key)?;
    journal::install(&db, true)?;
    let store = Store::new(vault)?;
    if store.get::<Config>("config")?.is_some() {
        let enabled: bool = db
            .query_row("SELECT enabled FROM tp_sync_context WHERE id=1", [], |r| {
                r.get(0)
            })
            .map_err(db_error)?;
        if !enabled {
            let tx = db.unchecked_transaction().map_err(db_error)?;
            journal::seed(&db, &vault.key, true)?;
            journal::set_context(&db, &store.context()?, true)?;
            tx.commit().map_err(db_error)?;
        }
    }
    Ok(Some(db))
}
pub(super) fn drain(store: &Store<'_>, ai: Option<&Connection>) -> Result<()> {
    store.transaction(|| {
        store.drain(store.db)?;
        if let Some(ai) = ai {
            store.drain(ai)?;
        }
        journal::set_context(store.db, &store.context()?, true)
    })?;
    store.prune_journal(store.db)?;
    if let Some(ai) = ai {
        store.prune_journal(ai)?;
    }
    Ok(())
}
fn status(store: &Store<'_>) -> Result<Value> {
    let Some(config) = store.get::<Config>("config")? else {
        return Ok(
            json!({"configured":false,"profiles":super::profiles::list(store)?,"activeProfile":super::profiles::active(store)?}),
        );
    };
    let mut pending: i64 = store
        .db
        .query_row(
            "SELECT COUNT(*) FROM tp_sync_operations WHERE published=0",
            [],
            |r| r.get(0),
        )
        .map_err(db_error)?;
    // Native writes are durable before normalization; do not report an empty queue
    // merely because the automatic worker has not drained the journal yet.
    pending += store.db.query_row("SELECT COUNT(*) FROM tp_sync_journal WHERE id>COALESCE((SELECT seq FROM tp_sync_cursors WHERE origin=(SELECT origin FROM tp_sync_context WHERE id=1)),0)", [], |r| r.get::<_,i64>(0)).map_err(db_error)?;
    let mut conflicts = Vec::new();
    let mut recycle = Vec::new();
    let mut gaps = 0;
    for scope in &config.scopes {
        let state = store.state(scope)?;
        gaps += state.waiting.len();
        for (id, record) in &state.records {
            if record.conflicted() {
                conflicts.push(super::conflicts::describe(
                    store, &config, scope, id, record, &state,
                )?);
            }
        }
        for (id, item) in &state.recycle {
            if !item.purged && !matches!(scope.as_str(), "credentials" | "aiSecrets") {
                recycle.push(json!({"id":id,"scope":scope,"collection":item.collection,"record":item.record,"deletedAt":item.deleted_at,"publishedAt":item.published_at,"retentionDays":item.retention_days,"restored":!item.restored.is_empty(),"label":item.recovery.as_ref().and_then(|v|v.get("label").or_else(||v.get("name"))).cloned().unwrap_or(json!(item.record))}));
            }
        }
    }
    let mut snapshots = store.get::<Vec<Value>>("snapshots")?.unwrap_or_default();
    for snapshot in &mut snapshots {
        if snapshot["fullVersion"] == true {
            continue;
        }
        let mut verified = true;
        for object in snapshot["objects"].as_array().into_iter().flatten() {
            let exists: bool = store
                .db
                .query_row(
                    "SELECT EXISTS(SELECT 1 FROM tp_sync_objects WHERE name=?1 AND published=1 UNION ALL SELECT 1 FROM tp_sync_received WHERE name=?1)",
                    [object["name"].as_str().unwrap_or("")],
                    |r| r.get(0),
                )
                .map_err(db_error)?;
            verified &= exists;
        }
        snapshot["verified"] = json!(verified);
    }
    Ok(
        json!({"configured":true,"profiles":super::profiles::list(store)?,"activeProfile":super::profiles::active(store)?,"passwordChange":super::rekey::progress(store)?,"passwordRequired":store.get::<bool>("passwordRequired")?.unwrap_or(false),"keyVersion":config.generation_sequence,"remoteSyncBusy":store.get::<Value>("remoteSyncBusy")?,"library":config.library,"device":config.device,"name":config.name,"auto":config.auto && !matches!(config.provider, Provider::Unavailable),"providerUnavailable":matches!(config.provider, Provider::Unavailable),"scopes":config.scopes,"retentionDays":config.retention_days,"lockTimeoutMinutes":config.lock_timeout_minutes,"historyVersionCount":store.get::<super::bundle::History>("bundleHistory")?.map(|h|h.keep).unwrap_or(10),"pendingHistoryVersionCount":store.get::<u32>("pendingHistoryKeep")?,"fullVersionSync":store.get::<super::bundle::History>("bundleHistory")?.is_some(),"objectRecovery":store.get::<Value>("objectRecovery")?,"maintenance":store.get::<Value>("maintenanceStatus")?,"lockRecoveryBackup":store.get::<Value>("lockRecoveryBackup")?,"provider":config.provider.public(),"pending":pending,"gaps":gaps,"conflicts":conflicts,"recycle":recycle,"lastCheck":store.get::<Value>("lastCheck")?,"lastError":store.get::<Value>("lastError")?,"preferences":store.get::<Value>("preferences")?.unwrap_or(json!({})),"snapshots":snapshots}),
    )
}
pub fn dispatch(request: &Value, supplied_key: Option<&[u8]>) -> Result<Value> {
    if request["method"] == "sync.checkConnection" {
        return check_connection_readonly(request, supplied_key);
    }
    if request["method"] == "sync.prepare" && request["databasePath"].is_string() {
        let path = Path::new(request["databasePath"].as_str().unwrap());
        let key_path = Path::new(request["keyPath"].as_str().unwrap_or(""));
        if !path.is_absolute() || !path.is_file() || !key_path.is_absolute() {
            return Err(err("syncPath", "原生数据库路径无效。"));
        }
        let bytes = zeroize::Zeroizing::new(
            std::fs::read(key_path).map_err(|_| err("syncKey", "无法读取本机数据库密钥。"))?,
        );
        if bytes.len() != 32 {
            return Err(err("syncKey", "本机数据库密钥无效。"));
        }
        let db = Connection::open(path).map_err(db_error)?;
        db.busy_timeout(std::time::Duration::from_secs(5))
            .map_err(db_error)?;
        journal::register(&db, &bytes)?;
        journal::install(&db, false)?;
        return Ok(json!({"ready":true}));
    }

    let directory = Path::new(request["directory"].as_str().unwrap_or(""));
    let vault = match supplied_key {
        Some(key) => Vault::open_with_key(directory, key)?,
        None => Vault::open(directory, request["keyPath"].as_str().map(Path::new))?,
    };
    let store = Store::new(&vault)?;
    let method = request["method"].as_str().unwrap_or("");
    if method == "sync.prepare" {
        return Ok(json!({"ready":true}));
    }
    if method == "sync.preferences" {
        return store.transaction(|| {
            let mut current = store
                .get::<BTreeMap<String, Value>>("preferences")?
                .unwrap_or_default();
            let mut changed = BTreeMap::new();
            if request["initial"] == true && !current.is_empty() {
                return Ok(json!({"preferences":current}));
            }
            if let Some(values) = request["values"].as_object() {
                for (field, value) in values {
                    let valid = match field.as_str() {
                        "theme" => matches!(value.as_str(), Some("dark" | "light" | "system")),
                        "language" => matches!(value.as_str(), Some("en" | "zh-Hans" | "system")),
                        "videoCodec" => matches!(value.as_str(), Some("h264" | "h265")),
                        "fps" => matches!(value.as_u64(), Some(30 | 60)),
                        "fontSize" => value.as_f64().is_some_and(|n| (8.0..=48.0).contains(&n)),
                        "fontFamily" => value.as_str().is_some_and(|s| s.len() < 256),
                        _ => false,
                    };
                    if !valid {
                        return Err(err("syncPreference", "偏好设置的字段或值无效。"));
                    }
                    if current.get(field) != Some(value) {
                        changed.insert(field.clone(), value.clone());
                        current.insert(field.clone(), value.clone());
                    }
                }
            }
            if !changed.is_empty() {
                if let Some(_config) = store
                    .get::<Config>("config")?
                    .filter(|c| c.scopes.iter().any(|s| s == "preferences"))
                {
                    store.append(
                        "preferences",
                        &store.writer()?,
                        &store.state("preferences")?.frontier,
                        "preferences",
                        "main",
                        Action::Patch { fields: changed },
                    )?;
                }
                store.put("preferences", &current)?;
            }
            Ok(json!({"preferences":current}))
        });
    }
    if method == "sync.describe" {
        let description = json!({"providers":[
        {"id":"webdav","name":"WebDAV","fields":[["endpoint","HTTPS 地址",false],["auth_type","认证方式",false],["username","用户名",false],["password","密码",true],["token","Bearer Token（Token 认证）",true]]},
        {"id":"s3","name":"S3 / S3 Compatible","fields":[["endpoint","HTTPS Endpoint",false],["bucket","Bucket",false],["region","Region",false],["prefix","Prefix（可选）",false],["access_key","Access Key",true],["secret_key","Secret Key",true],["session_token","Session Token（可选）",true]]},
        {"id":"r2","name":"Cloudflare R2","help":"使用 R2 控制台提供的 S3 API 地址（不含桶名）。区域自动设为 auto；凭证仅需该私有桶的对象读写权限。无需开启公开访问。","fields":[["endpoint","R2 S3 API Endpoint",false],["bucket","Bucket",false],["prefix","Prefix（可选）",false],["access_key","Access Key ID",true],["secret_key","Secret Access Key",true]]}
    ],"scopes":[["configuration","主机、分组、凭证描述、代理、脚本、笔记和 AI 配置"],["credentials","密码、私钥和凭证秘密"],["aiSecrets","AI API Key 与认证请求头"],["preferences","外观、语言和终端偏好"],["aiHistory","AI 对话历史"]]});
        return Ok(description);
    }
    super::profiles::ensure(&vault, &store)?;
    if method.starts_with("sync.invite.") {
        return super::invite::dispatch(&vault, &store, request, supplied_key);
    }
    if method.starts_with("sync.profile.") {
        super::profiles::dispatch(&vault, &store, request)?;
        return status(&store);
    }
    if method == "sync.status" {
        return status(&store);
    }
    if method == "sync.password.begin" {
        let (config, _, _) = super::rekey::validate(&store, request)?;
        let mut backend = Backend::new(config.provider.clone(), &config.library)?;
        if let Some((head, _)) = super::control::read(&mut backend, &config.library)? {
            if head.generation != config.generation || head.sequence != config.generation_sequence {
                store.put("passwordRequired", &true)?;
                return Err(err(
                    "syncPasswordChanged",
                    "云端 Key 已更新，请先输入当前 Key。",
                ));
            }
            head.verify(&config)?;
        }
        backend.check_conditionals(&config.library)?;
        super::rekey::begin(&vault, &store, request)?;
        return status(&store);
    }
    if method == "sync.password.resume" {
        let config = store.config()?;
        let mut backend = Backend::new(config.provider.clone(), &config.library)?;
        if let Err(error) = super::rekey::resume(&vault, &store, &mut backend) {
            super::rekey::failed(&store, &error)?;
            return Err(error);
        }
        return status(&store);
    }
    if method == "sync.password.unlock" {
        let config = store.config()?;
        let mut backend = Backend::new(config.provider.clone(), &config.library)?;
        super::rekey::unlock(
            &store,
            &mut backend,
            request["passphrase"].as_str().unwrap_or(""),
        )?;
        return status(&store);
    }
    if super::rekey::active(&store)? && method != "sync.provider" {
        if method == "sync.tick" {
            return Ok(json!({"skipped":true,"passwordChange":super::rekey::progress(&store)?}));
        }
        return Err(err(
            "syncPasswordBusy",
            "同步 Key 迁移尚未完成，请在同步设置中继续修改 Key。",
        ));
    }
    if method == "sync.tick" {
        let Some(config) = store.get::<Config>("config")? else {
            return Ok(json!({"skipped":true}));
        };
        let now = chrono::Utc::now().timestamp();
        if matches!(config.provider, Provider::Unavailable)
            || !config.auto
            || store.get::<bool>("passwordRequired")?.unwrap_or(false)
            || store.get::<i64>("nextAttempt")?.unwrap_or(0) > now
        {
            return Ok(json!({"skipped":true}));
        }
        let mut run = request.clone();
        run["method"] = json!("sync.run");
        return match dispatch(&run, supplied_key) {
            Ok(result) => {
                store.put("nextAttempt", &(now + 30))?;
                store.put("failures", &0u32)?;
                store.put("lastError", &Value::Null)?;
                Ok(result)
            }
            Err(error) => {
                let failures = store
                    .get::<u32>("failures")?
                    .unwrap_or(0)
                    .saturating_add(1)
                    .min(10);
                let delay =
                    (5_i64 * 2_i64.pow(failures)).min(900) + i64::from(rand::random::<u8>() % 10);
                store.put("nextAttempt", &(now + delay))?;
                store.put("failures", &failures)?;
                store.put(
                    "lastError",
                    &json!({"code":error.code,"message":error.message}),
                )?;
                Err(error)
            }
        };
    }
    if method == "sync.configure" {
        if request["confirmed"] != true {
            return Err(err(
                "syncConfirmation",
                "请确认首次合并及同步范围后再启用同步。",
            ));
        }
        let existing = store.get::<Config>("config")?;
        if let Some(mut config) = existing {
            config.lock_timeout_minutes =
                super::lease::timeout(request, config.lock_timeout_minutes)?;
            if let Some(value) = request.get("historyVersionCount") {
                store.put("pendingHistoryKeep", &super::bundle::parse_keep(value)?)?;
            }
            let ai = ai_database(&vault)?;
            drain(&store, ai.as_ref())?;
            let requested = if request["scopes"].is_array() {
                parse_scopes(&request["scopes"])?
            } else {
                config.scopes.clone()
            };
            let added: Vec<String> = requested
                .iter()
                .filter(|s| !config.scopes.contains(s))
                .cloned()
                .collect();
            if !added.is_empty() {
                let keys = derive_keys(
                    request["passphrase"].as_str().unwrap_or(""),
                    &config.library,
                )?;
                if keys.get("configuration") != config.scope_keys.get("configuration") {
                    return Err(err("syncPassword", "同步 Key 不正确，尚未更改同步范围。"));
                }
                for scope in &added {
                    config.scope_keys.insert(scope.clone(), keys[scope].clone());
                }
            }
            if request.get("provider").is_some() {
                return Err(err("syncProviderChange","请先导出备份并断开同步，再配置其它云端位置；不会把已确认对象静默迁移到空云端。"));
            }
            if let Some(auto) = request["auto"].as_bool() {
                if auto && matches!(config.provider, Provider::Unavailable) {
                    return Err(err(
                        "syncProviderUnavailable",
                        "请先选择支持的同步服务，再开启自动同步。",
                    ));
                }
                config.auto = auto;
            }
            if let Some(name) = request["name"].as_str() {
                config.name = name.into();
            }
            config.scopes = requested;
            store.transaction(|| {
                store.put("config", &config)?;
                if !added.is_empty() {
                    journal::seed_scopes(store.db, store.key, false, Some(&added))?;
                }
                journal::set_context(store.db, &store.context()?, true)?;
                if added.iter().any(|s| s == "preferences") {
                    if let Some(fields) = store.get::<BTreeMap<String, Value>>("preferences")? {
                        store.append(
                            "preferences",
                            &store.writer()?,
                            &store.state("preferences")?.frontier,
                            "preferences",
                            "main",
                            Action::Patch { fields },
                        )?;
                    }
                }
                Ok(())
            })?;
            if let Some(ai) = ai.as_ref() {
                let tx = ai.unchecked_transaction().map_err(db_error)?;
                if !added.is_empty() {
                    journal::seed_scopes(ai, store.key, true, Some(&added))?;
                }
                journal::set_context(ai, &store.context()?, true)?;
                tx.commit().map_err(db_error)?;
            }
            return status(&store);
        }
        let password = request["passphrase"].as_str().unwrap_or("");
        if password.chars().count() < 12 {
            return Err(err("syncPassword", "同步 Key 至少需要 12 个字符。"));
        }
        let library = match request["library"].as_str().filter(|s| !s.trim().is_empty()) {
            Some(id) => {
                uuid::Uuid::parse_str(id).map_err(|_| err("syncLibrary", "同步库 ID 无效。"))?
            }
            None => uuid::Uuid::new_v4(),
        }
        .to_string();
        let scopes = if request["scopes"].is_array() {
            parse_scopes(&request["scopes"])?
        } else {
            policy::DEFAULT_SCOPES.iter().map(|s| (*s).into()).collect()
        };
        let mut scope_keys = derive_keys(password, &library)?;
        scope_keys.retain(|scope, _| scopes.contains(scope));
        let provider: Provider = serde_json::from_value(request["provider"].clone())
            .map_err(|_| err("syncProvider", "云服务配置不完整。"))?;
        let _ = Backend::new(provider.clone(), &library)?;
        let config = Config {
            generation: String::new(),
            generation_sequence: 0,
            library,
            device: uuid::Uuid::new_v4().to_string(),
            name: request["name"].as_str().unwrap_or("TermPilot").into(),
            auto: request["auto"].as_bool().unwrap_or(false),
            scopes,
            lock_timeout_minutes: super::lease::timeout(request, super::lease::default_timeout())?,
            retention_days: Some(30),
            scope_keys,
            provider,
        };
        store.transaction(|| {
            store.put("config", &config)?;
            journal::seed(store.db, store.key, false)?;
            journal::set_context(store.db, &json!({}), true)?;
            if config.scopes.iter().any(|s| s == "preferences") {
                if let Some(fields) = store.get::<BTreeMap<String, Value>>("preferences")? {
                    store.append(
                        "preferences",
                        &store.writer()?,
                        &Vector::new(),
                        "preferences",
                        "main",
                        Action::Patch { fields },
                    )?;
                }
            }
            Ok(())
        })?;
        if let Some(ai) = ai_database(&vault)? {
            let tx = ai.unchecked_transaction().map_err(db_error)?;
            // ai_database seeds the store exactly once when it enables capture.
            journal::set_context(&ai, &store.context()?, true)?;
            tx.commit().map_err(db_error)?;
        }
        return status(&store);
    }
    let ai = ai_database(&vault)?;
    if method == "sync.recover" {
        if store.get::<Config>("config")?.is_some()
            && store.get::<bool>("projectionPending")?.unwrap_or(false)
        {
            drain(&store, ai.as_ref())?;
            store.transaction(|| projection::vault(&store))?;
            if let Some(ai) = ai.as_ref() {
                projection::ai(&store, ai)?;
            }
            project_preferences(&store)?;
            store.put("projectionPending", &false)?;
        }
        return status(&store);
    }
    drain(&store, ai.as_ref())?;
    match method {
        "sync.snapshot.import" => super::bundle::import_file(&store, request),
        "sync.repair" => {
            let config = store.config()?;
            let mut cloud = Backend::new(config.provider.clone(), &config.library)?;
            let lease = super::control::acquire(&store, &mut cloud, "repair")?;
            let result = super::bundle::repair(&vault, &store, &mut cloud, &lease);
            let released = super::control::release(&store, &mut cloud, &lease);
            let restored = result?;
            released?;
            store.put(
                "objectRecovery",
                &json!({"restored":restored,"at":chrono::Utc::now().to_rfc3339()}),
            )?;
            store.put("lastError", &Value::Null)?;
            status(&store)
        }
        "sync.lock.inspect" => {
            let config = store.config()?;
            let mut cloud = Backend::new(config.provider.clone(), &config.library)?;
            super::legacy_lock::inspect(&store, &mut cloud)
        }
        "sync.run" | "sync.lock.recover" => {
            super::progress::stage("connecting", 0, None);
            let config = store.config()?;
            let mut cloud = Backend::new(config.provider.clone(), &config.library)?;
            let recovering = method == "sync.lock.recover";
            let lease = if recovering {
                super::legacy_lock::recover(&vault, &store, &mut cloud, request)?
            } else {
                super::rekey::adopt_matching(&store, &mut cloud)?;
                super::control::acquire(&store, &mut cloud, "sync")?
            };
            let result = super::bundle::run(&vault, &store, &mut cloud, &lease);
            let released = super::control::release(&store, &mut cloud, &lease);
            result?;
            released?;
            project_current(&vault, &store)?;
            status(&store)
        }
        "sync.provider" => {
            if request["confirmed"] != true {
                return Err(err(
                    "syncConfirmation",
                    "请确认云端配置变更；更换位置会发布完整快照，原云端保留不动。",
                ));
            }
            let mut config = store.config()?;
            let provider = super::profiles::merge_provider(&config.provider, &request["provider"])?;
            let _ = Backend::new(provider.clone(), &config.library)?;
            let migrating =
                request["migrate"] == true || provider.public() != config.provider.public();
            if migrating && super::rekey::active(&store)? {
                return Err(err(
                    "syncPasswordBusy",
                    "修改 Key 期间只能更新原位置的认证信息，不能更换云端位置。",
                ));
            }
            if migrating {
                let path = vault.directory.join(format!(
                    "vault.before-sync-provider-{}.sqlite",
                    uuid::Uuid::new_v4()
                ));
                store
                    .db
                    .backup(rusqlite::DatabaseName::Main, &path, None)
                    .map_err(db_error)?;
                #[cfg(unix)]
                {
                    use std::os::unix::fs::PermissionsExt;
                    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
                        .map_err(|_| err("syncBackup", "无法保护迁移备份。"))?;
                }
            }
            if matches!(config.provider, Provider::Unavailable) {
                config.auto = false;
            }
            config.provider = provider;
            store.transaction(|| {
                store.put("config", &config)?;
                if migrating {
                    store.put("allowControlCreate", &true)?;
                    store
                        .db
                        .execute("DELETE FROM tp_sync_received", [])
                        .map_err(db_error)?;
                    store
                        .db
                        .execute("UPDATE tp_sync_objects SET published=0", [])
                        .map_err(db_error)?;
                    maybe_snapshot(&store, true)?;
                }
                store.put("lastError", &Value::Null)?;
                store.put("nextAttempt", &0i64)?;
                Ok(())
            })?;
            status(&store)
        }
        "sync.snapshot" => {
            if store
                .get::<super::bundle::History>("bundleHistory")?
                .is_some()
            {
                store.put("forceFullVersion", &true)?;
                return status(&store);
            }
            store.transaction(|| maybe_snapshot(&store, true))?;
            status(&store)
        }
        "sync.retention" => {
            let days = if request["days"].is_null() {
                None
            } else {
                Some(
                    request["days"]
                        .as_u64()
                        .filter(|d| *d >= 1 && *d <= 36500)
                        .ok_or_else(|| {
                            err("syncRetention", "保留期应为 1–36500 天，或长期保留。")
                        })? as u32,
                )
            };
            store.transaction(|| {
                let mut config = store.config()?;
                config.retention_days = days;
                let basis = store.state("configuration")?.frontier;
                store.append(
                    "configuration",
                    &store.writer()?,
                    &basis,
                    "library",
                    "policy",
                    Action::Patch {
                        fields: BTreeMap::from([
                            ("retentionDays".into(), json!(days)),
                            (
                                format!("protection/{}", uuid::Uuid::new_v4()),
                                json!({"days":days,"frontiers":store.context()?}),
                            ),
                        ]),
                    },
                )?;
                store.put("config", &config)
            })?;
            status(&store)
        }
        "sync.snapshot.preview" | "sync.snapshot.restore" => {
            super::bundle::load_snapshot(&store, request["id"].as_str().unwrap_or(""))?;
            let result = restore_snapshot(&store, request)?;
            if request["confirmed"] == true {
                if let Some(ai) = ai.as_ref() {
                    projection::ai(&store, ai)?;
                }
                project_preferences(&store)?;
            }
            Ok(result)
        }
        "sync.restore" => {
            let result = restore(&store, request)?;
            if request["confirmed"] == true {
                if let Some(ai) = ai.as_ref() {
                    projection::ai(&store, ai)?;
                }
                project_preferences(&store)?;
            }
            Ok(result)
        }
        "sync.conflict.preview" => super::conflicts::preview(&store, request),
        "sync.resolve" => {
            let scope = request["scope"].as_str().unwrap_or("configuration");
            let id = request["id"].as_str().unwrap_or("");
            let (collection, record) = id
                .split_once('/')
                .ok_or_else(|| err("syncRecord", "冲突记录无效。"))?;
            let state = store.state(scope)?;
            super::conflicts::check_revision(&store, request, &state, id)?;
            if let Some(record) = state.records.get(id).filter(|r| r.deleted()) {
                if request["keepDeleted"] != true {
                    return Err(err(
                        "syncDeleted",
                        "此记录已删除，请从回收站恢复，或确认保留删除。",
                    ));
                }
                store.transaction(|| {
                    store.append(
                        scope,
                        &store.writer()?,
                        &state.frontier,
                        collection,
                        record_id(id),
                        Action::Delete {
                            recovery: record.value(),
                            retention_days: store.config()?.retention_days,
                            deleted_at: chrono::Utc::now().to_rfc3339(),
                        },
                    )?;
                    projection::vault(&store)
                })?;
                return status(&store);
            }
            let fields: BTreeMap<String, Value> =
                if let Some(choices) = request["choices"].as_object() {
                    let record = state
                        .records
                        .get(id)
                        .ok_or_else(|| err("syncRecord", "冲突记录不存在。"))?;
                    let mut fields = BTreeMap::new();
                    for (field, dot) in choices {
                        let dot: Dot = serde_json::from_value(dot.clone())
                            .map_err(|_| err("syncRecord", "冲突候选无效。"))?;
                        let candidate = record
                            .fields
                            .get(field)
                            .and_then(|v| v.iter().find(|c| c.dot == dot))
                            .ok_or_else(|| err("syncConflict", "冲突已更新，请刷新后重新选择。"))?;
                        fields.insert(field.clone(), candidate.value.clone());
                    }
                    fields
                } else {
                    serde_json::from_value(request["fields"].clone())
                        .map_err(|_| err("syncRecord", "请选择要保留的字段。"))?
                };
            store.transaction(|| {
                store.append(
                    scope,
                    &store.writer()?,
                    &state.frontier,
                    collection,
                    record,
                    Action::Patch { fields },
                )?;
                projection::vault(&store)
            })?;
            project_preferences(&store)?;
            status(&store)
        }
        "sync.purge" => {
            if request["confirmed"] != true {
                return Err(err("syncConfirmation", "请确认永久清理所选回收站内容。"));
            }
            let scope = request["scope"].as_str().unwrap_or("configuration");
            let state = store.state(scope)?;
            let ids: Vec<String> = serde_json::from_value(request["ids"].clone())
                .map_err(|_| err("syncRecord", "请选择回收站条目。"))?;
            for id in &ids {
                let item = state
                    .recycle
                    .get(id)
                    .ok_or_else(|| err("syncRecord", "回收站条目不存在。"))?;
                if state
                    .records
                    .get(&record_key(&item.collection, &item.record))
                    .is_some_and(Record::conflicted)
                {
                    return Err(err("syncConflict", "请先处理删除记录的并发冲突。"));
                }
            }
            store.transaction(|| {
                store.append(
                    scope,
                    &store.writer()?,
                    &state.frontier,
                    "recycle",
                    "purge",
                    Action::Purge { recycle_ids: ids },
                )?;
                Ok(())
            })?;
            status(&store)
        }
        _ => Err(err("unknownMethod", "未知同步操作。")),
    }
}
pub(super) fn maybe_snapshot(store: &Store<'_>, force: bool) -> Result<()> {
    let mut snapshots = store.get::<Vec<Value>>("snapshots")?.unwrap_or_default();
    let scopes = store.config()?.scopes;
    let mut states = Vec::new();
    let mut frontier = BTreeMap::new();
    let mut size = 0usize;
    for scope in &scopes {
        let state = store.published_state(scope)?;
        size += serde_json::to_vec(&state).unwrap().len();
        frontier.insert(scope.clone(), state.frontier.clone());
        states.push((scope.clone(), state));
    }
    let now = chrono::Utc::now().timestamp();
    let previous = store
        .get::<BTreeMap<String, Vector>>("snapshotFrontier")?
        .unwrap_or_default();
    let count: u64 = frontier
        .iter()
        .map(|(scope, v)| {
            v.iter()
                .map(|(writer, seq)| {
                    seq.saturating_sub(
                        previous
                            .get(scope)
                            .and_then(|v| v.get(writer))
                            .copied()
                            .unwrap_or(0),
                    )
                })
                .sum::<u64>()
        })
        .sum();
    let old_size = store.get::<usize>("snapshotSize")?.unwrap_or(0);
    if !force
        && !snapshots.is_empty()
        && (count == 0
            || (count < 1000
                && size.saturating_sub(old_size) < 16 * 1024 * 1024
                && now - store.get::<i64>("snapshotAt")?.unwrap_or(0) < 86400))
    {
        return Ok(());
    }
    let mut names = Vec::new();
    let snapshot_id = uuid::Uuid::new_v4().to_string();
    let at = chrono::Utc::now().to_rfc3339();
    for (scope, state) in states {
        let name = queue(
            store,
            &scope,
            "snapshot",
            &json!({"id":snapshot_id,"at":at,"scopes":scopes,"state":state}),
        )?;
        store.put(&format!("snapshot:{name}"), &state)?;
        names.push(json!({"scope":scope,"name":name,"frontier":state.frontier}));
    }
    snapshots
        .push(json!({"id":snapshot_id,"at":at,"scopes":scopes,"objects":names,"verified":false}));
    store.put("snapshots", &snapshots)?;
    store.put("snapshotFrontier", &frontier)?;
    store.put("snapshotAt", &now)?;
    store.put("snapshotSize", &size)
}
pub(super) fn expire_recycle(store: &Store<'_>, server_time: Option<i64>) -> Result<()> {
    let Some(now) = server_time else {
        return Ok(());
    };
    let mut config = store.config()?;
    if let Some(record) = store.state("configuration")?.records.get("library/policy") {
        let candidates = record
            .fields
            .get("retentionDays")
            .cloned()
            .unwrap_or_default();
        config.retention_days = if candidates.iter().any(|v| v.value.is_null()) {
            None
        } else {
            candidates
                .iter()
                .filter_map(|v| v.value.as_u64().map(|v| v as u32))
                .max()
                .or(config.retention_days)
        };
        store.put("config", &config)?;
    }
    for scope in &config.scopes {
        let state = store.state(scope)?;
        if !state.waiting.is_empty() {
            continue;
        }
        let ids = state
            .recycle
            .iter()
            .filter_map(|(id, item)| {
                let published = item.published_at?;
                let mut days = item.retention_days?;
                if let Some(policy) = store
                    .state("configuration")
                    .ok()?
                    .records
                    .get("library/policy")
                {
                    for (field, candidates) in &policy.fields {
                        if !field.starts_with("protection/") {
                            continue;
                        }
                        for candidate in candidates {
                            let frontier: Vector =
                                serde_json::from_value(candidate.value["frontiers"][scope].clone())
                                    .unwrap_or_default();
                            if item.deletion.observed(&frontier) {
                                days = days.max(candidate.value["days"].as_u64()? as u32);
                            }
                        }
                    }
                }
                if item.purged
                    || now < published.saturating_add(i64::from(days) * 86400)
                    || state
                        .records
                        .get(&record_key(&item.collection, &item.record))
                        .is_some_and(Record::conflicted)
                {
                    return None;
                }
                Some(id.clone())
            })
            .collect::<Vec<_>>();
        if !ids.is_empty() {
            store.append(
                scope,
                &store.writer()?,
                &state.frontier,
                "recycle",
                "expiry",
                Action::Purge { recycle_ids: ids },
            )?;
        }
    }
    Ok(())
}
fn restore(store: &Store<'_>, request: &Value) -> Result<Value> {
    let action = request["actionId"]
        .as_str()
        .filter(|s| uuid::Uuid::parse_str(s).is_ok())
        .ok_or_else(|| err("syncAction", "恢复操作需要唯一 ID。"))?;
    if let Some(bytes) = store
        .db
        .query_row(
            "SELECT payload FROM tp_sync_actions WHERE id=?1",
            [action],
            |r| r.get::<_, Vec<u8>>(0),
        )
        .optional()
        .map_err(db_error)?
    {
        return store.decode(&bytes);
    }
    let scope = request["scope"].as_str().unwrap_or("configuration");
    if !store.config()?.scopes.iter().any(|s| s == scope) {
        return Err(err("syncScope", "此同步范围未启用。"));
    }
    let state = store.state(scope)?;
    let mut ids: Vec<String> = serde_json::from_value(request["ids"].clone())
        .map_err(|_| err("syncRecord", "请选择回收站条目。"))?;
    let hosts = ids
        .iter()
        .filter_map(|id| state.recycle.get(id))
        .filter(|item| item.collection == "hosts")
        .map(|item| item.record.clone())
        .collect::<Vec<_>>();
    for (id, item) in &state.recycle {
        if item.collection == "screen_sharing_profiles"
            && hosts.contains(&item.record)
            && !item.purged
            && !ids.contains(id)
        {
            ids.push(id.clone());
        }
    }
    let conversations = ids
        .iter()
        .filter_map(|id| state.recycle.get(id))
        .filter(|r| r.collection == "ai:conversations")
        .map(|r| r.record.clone())
        .collect::<Vec<_>>();
    for (id, item) in &state.recycle {
        if item.collection == "ai:messages"
            && !item.purged
            && item
                .recovery
                .as_ref()
                .and_then(|v| v["conversationId"].as_str())
                .is_some_and(|id| conversations.iter().any(|c| c == id))
            && !ids.contains(id)
        {
            ids.push(id.clone());
        }
    }
    let mut mapping = BTreeMap::new();
    for id in &ids {
        let item = state
            .recycle
            .get(id)
            .filter(|r| !r.purged && r.recovery.is_some())
            .ok_or_else(|| err("syncRecycle", "恢复内容已清理或尚未同步。"))?;
        mapping
            .entry(item.record.clone())
            .or_insert_with(|| uuid::Uuid::new_v4().to_string().to_uppercase());
    }
    if request["confirmed"] != true {
        return Ok(
            json!({"preview":true,"count":ids.len(),"secretsIncluded":store.config()?.scopes.iter().any(|s|s=="credentials"),"mapping":mapping}),
        );
    }
    store.transaction(|| {
        let writer = store.writer()?;
        for id in &ids {
            let item = &state.recycle[id];
            let mut recovery = item.recovery.clone().unwrap();
            if request["edited"] == true {
                if let Some(record) = state
                    .records
                    .get(&record_key(&item.collection, &item.record))
                {
                    policy::overlay(&mut recovery, &record.value());
                }
            }
            replace_references(&mut recovery, &mapping);
            let fields = serde_json::from_value(recovery)
                .map_err(|_| err("syncRecycle", "恢复内容无效。"))?;
            store.append(
                scope,
                &writer,
                &store.state(scope)?.frontier,
                &item.collection,
                &mapping[&item.record],
                Action::Patch { fields },
            )?;
            for extra_scope in store
                .config()?
                .scopes
                .iter()
                .filter(|s| s.as_str() != scope)
            {
                let extra = store.state(extra_scope)?;
                let content = extra
                    .recycle
                    .values()
                    .find(|r| {
                        r.record == item.record && r.collection == item.collection && !r.purged
                    })
                    .and_then(|r| r.recovery.clone());
                if let Some(content) = content {
                    let fields = serde_json::from_value(content)
                        .map_err(|_| err("syncRecycle", "恢复内容无效。"))?;
                    store.append(
                        extra_scope,
                        &writer,
                        &extra.frontier,
                        &item.collection,
                        &mapping[&item.record],
                        Action::Patch { fields },
                    )?;
                }
            }
        }
        store.append(
            scope,
            &writer,
            &store.state(scope)?.frontier,
            "recycle",
            "restore",
            Action::Restored {
                recycle_ids: ids.clone(),
                mapping: mapping.clone(),
            },
        )?;
        let result = json!({"restored":mapping});
        store
            .db
            .execute(
                "INSERT INTO tp_sync_actions VALUES(?1,?2)",
                params![action, store.encode(&result)?],
            )
            .map_err(db_error)?;
        projection::vault(store)?;
        store
            .db
            .execute("UPDATE tp_sync_context SET suppressed=1 WHERE id=1", [])
            .map_err(db_error)?;
        for id in &ids {
            let item = &state.recycle[id];
            if let Some(new) = mapping.get(&item.record) {
                if let Some(mut full) = store.get::<Value>(&format!("recovery:{scope}:{id}"))? {
                    if let Some((table, pk)) = policy::TABLES
                        .iter()
                        .find(|(table, _)| *table == item.collection)
                    {
                        replace_references(&mut full, &mapping);
                        if let Some(current) = store
                            .state(scope)?
                            .records
                            .get(&record_key(&item.collection, new))
                        {
                            policy::overlay(&mut full, &policy::expand(current.value()));
                        }
                        projection::write_row(store.db, store.key, table, pk, new, &full)?;
                    }
                }
            }
        }
        store
            .db
            .execute("UPDATE tp_sync_context SET suppressed=0 WHERE id=1", [])
            .map_err(db_error)?;
        Ok(result)
    })
}
fn replace_references(value: &mut Value, mapping: &BTreeMap<String, String>) {
    if let Value::Object(fields) = value {
        for (field, v) in fields {
            if matches!(
                field.as_str(),
                "host_id"
                    | "hostID"
                    | "group_id"
                    | "parent_group_id"
                    | "credential_reference"
                    | "proxy_profile_reference"
                    | "providerId"
                    | "providerID"
                    | "conversationId"
                    | "conversationID"
            ) {
                if let Some(new) = v.as_str().and_then(|s| mapping.get(s)) {
                    *v = json!(new);
                }
            } else if field == "messageOrder" {
                if let Some(ids) = v.as_array_mut() {
                    for id in ids {
                        if let Some(new) = id.as_str().and_then(|id| mapping.get(id)) {
                            *id = json!(new);
                        }
                    }
                }
            } else if v.is_object() {
                replace_references(v, mapping);
            }
        }
    }
}

/// Complete native materialization after a normal exchange or password cutover.
pub(super) fn project_current(vault: &Vault, store: &Store<'_>) -> Result<()> {
    let ai = ai_database(vault)?;
    drain(store, ai.as_ref())?;
    super::progress::stage("applying", 0, Some(3));
    store.transaction(|| {
        store.put("projectionPending", &true)?;
        projection::vault(store)
    })?;
    if let Some(ai) = ai.as_ref() {
        projection::ai(store, ai)?;
    }
    project_preferences(store)?;
    store.put("projectionPending", &false)?;
    store.put("lastError", &Value::Null)
}

fn project_preferences(store: &Store<'_>) -> Result<()> {
    if !store.config()?.scopes.iter().any(|s| s == "preferences") {
        return Ok(());
    }
    if let Some(record) = store.state("preferences")?.records.get("preferences/main") {
        let mut value = store.get::<Value>("preferences")?.unwrap_or(json!({}));
        policy::overlay(&mut value, &record.value());
        store.put("preferences", &value)?;
    }
    Ok(())
}

pub(super) fn parse_scopes(value: &Value) -> Result<Vec<String>> {
    let mut scopes: Vec<String> =
        serde_json::from_value(value.clone()).map_err(|_| err("syncScope", "同步范围无效。"))?;
    scopes.sort();
    scopes.dedup();
    if !scopes.iter().all(|s| policy::SCOPES.contains(&s.as_str()))
        || !scopes.iter().any(|s| s == "configuration")
    {
        return Err(err("syncScope", "请至少启用配置同步。"));
    }
    Ok(scopes)
}
pub(super) fn derive_keys(password: &str, library: &str) -> Result<BTreeMap<String, Vec<u8>>> {
    if password.chars().count() < 12 {
        return Err(err("syncPassword", "同步 Key 至少需要 12 个字符。"));
    }
    let mut master = zeroize::Zeroizing::new([0u8; 32]);
    pbkdf2::pbkdf2_hmac::<Sha256>(
        password.as_bytes(),
        format!("TermPilot:sync:1:{library}").as_bytes(),
        600_000,
        &mut *master,
    );
    use hmac::{Hmac, Mac};
    Ok(policy::SCOPES
        .iter()
        .map(|scope| {
            let mut mac = Hmac::<Sha256>::new_from_slice(&*master).unwrap();
            mac.update(format!("scope:{scope}").as_bytes());
            ((*scope).into(), mac.finalize().into_bytes().to_vec())
        })
        .collect())
}

fn restore_snapshot(store: &Store<'_>, request: &Value) -> Result<Value> {
    let id = request["id"].as_str().unwrap_or("");
    let catalog = store.get::<Vec<Value>>("snapshots")?.unwrap_or_default();
    let entry = catalog
        .iter()
        .find(|v| v["id"] == id)
        .ok_or_else(|| err("syncSnapshot", "快照不存在，请先同步。"))?;
    let config = store.config()?;
    let mut states = BTreeMap::new();
    for object in entry["objects"].as_array().into_iter().flatten() {
        let scope = object["scope"].as_str().unwrap_or("");
        if !config.scopes.iter().any(|s| s == scope) {
            continue;
        }
        let name = object["name"].as_str().unwrap_or("");
        let state = store
            .get::<State>(&format!("snapshot:{name}"))?
            .ok_or_else(|| err("syncSnapshot", "快照分块未完整验证，请先同步。"))?;
        states.insert(scope.to_owned(), state);
    }
    for scope in entry["scopes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(Value::as_str)
    {
        if config.scopes.iter().any(|s| s == scope) && !states.contains_key(scope) {
            return Err(err("syncSnapshot", "快照所需范围尚未完整下载。"));
        }
    }
    let mut mapping = BTreeMap::new();
    let mut counts = BTreeMap::<String, usize>::new();
    for state in states.values() {
        for (key, record) in &state.records {
            if record.deleted() {
                continue;
            }
            let Some((collection, id)) = key.split_once('/') else {
                continue;
            };
            if !snapshot_collection(collection) {
                continue;
            }
            if !matches!(collection, "preferences" | "ai:settings") {
                mapping
                    .entry(id.to_owned())
                    .or_insert_with(|| uuid::Uuid::new_v4().to_string().to_uppercase());
            }
            *counts.entry(collection.into()).or_default() += 1;
        }
    }
    if request["method"] == "sync.snapshot.preview" || request["confirmed"] != true {
        return Ok(
            json!({"preview":true,"collections":counts,"copies":mapping.len(),"changesPreferences":counts.contains_key("preferences"),"changesAISettings":counts.contains_key("ai:settings")}),
        );
    }
    let action = request["actionId"]
        .as_str()
        .filter(|s| uuid::Uuid::parse_str(s).is_ok())
        .ok_or_else(|| err("syncAction", "恢复操作需要唯一 ID。"))?;
    if let Some(bytes) = store
        .db
        .query_row(
            "SELECT payload FROM tp_sync_actions WHERE id=?1",
            [action],
            |r| r.get::<_, Vec<u8>>(0),
        )
        .optional()
        .map_err(db_error)?
    {
        return store.decode(&bytes);
    }
    store.transaction(|| {
        for (scope, state) in states {
            for (key, record) in state.records {
                if record.deleted() {
                    continue;
                }
                let Some((collection, id)) = key.split_once('/') else {
                    continue;
                };
                if !snapshot_collection(collection) {
                    continue;
                }
                let mut value = record.value();
                replace_references(&mut value, &mapping);
                let fields = serde_json::from_value(value)
                    .map_err(|_| err("syncSnapshot", "快照记录格式无效。"))?;
                store.append(
                    &scope,
                    &store.writer()?,
                    &store.state(&scope)?.frontier,
                    collection,
                    mapping.get(id).map(String::as_str).unwrap_or(id),
                    Action::Patch { fields },
                )?;
            }
        }
        projection::vault(store)?;
        let result = json!({"restored":mapping,"collections":counts});
        store
            .db
            .execute(
                "INSERT INTO tp_sync_actions VALUES(?1,?2)",
                params![action, store.encode(&result)?],
            )
            .map_err(db_error)?;
        Ok(result)
    })
}
fn snapshot_collection(collection: &str) -> bool {
    policy::TABLES.iter().any(|(t, _)| *t == collection)
        || matches!(
            collection,
            "preferences"
                | "ai:providers"
                | "ai:prompts"
                | "ai:settings"
                | "ai:conversations"
                | "ai:messages"
        )
}

fn record_id(key: &str) -> &str {
    key.split_once('/').map(|(_, id)| id).unwrap_or(key)
}
fn check_connection_readonly(request: &Value, supplied_key: Option<&[u8]>) -> Result<Value> {
    let directory = Path::new(request["directory"].as_str().unwrap_or(""));
    if !directory.is_absolute() {
        return Err(err("invalidPath", "Vault path must be absolute."));
    }
    let key = zeroize::Zeroizing::new(match supplied_key {
        Some(key) => key.to_vec(),
        None => std::fs::read(
            request["keyPath"]
                .as_str()
                .map(std::path::PathBuf::from)
                .unwrap_or_else(|| directory.join("credential.key")),
        )
        .map_err(|_| {
            err(
                "missingCredentialKey",
                "The existing vault's credential key is missing.",
            )
        })?,
    });
    if key.len() != 32 {
        return Err(err("invalidCredentialKey", "Invalid credential key."));
    }
    let database = request["databasePath"]
        .as_str()
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| directory.join("vault.sqlite"));
    if !database.is_absolute() {
        return Err(err("invalidPath", "Vault path must be absolute."));
    }
    let mut db = Connection::open_with_flags(
        database,
        rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY | rusqlite::OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .map_err(db_error)?;
    db.busy_timeout(std::time::Duration::from_secs(5))
        .map_err(db_error)?;
    // One consistent WAL snapshot, with no migrations, trigger installation or writes.
    let tx = db.transaction().map_err(db_error)?;
    let installed: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE name='tp_sync_values')",
            [],
            |row| row.get(0),
        )
        .map_err(db_error)?;
    if installed {
        check_connection(&Store { db: &tx, key: &key }, &request["host"])?;
    }
    tx.commit().map_err(db_error)?;
    Ok(json!({"allowed":true}))
}

fn check_connection(store: &Store<'_>, host: &Value) -> Result<()> {
    let Some(config) = store.get::<Config>("config")? else {
        return Ok(());
    };
    let mut keys = Vec::new();
    for (field, collection) in [
        ("id", "hosts"),
        ("credentialID", "ssh_credentials"),
        ("proxyProfileID", "ssh_proxy_profiles"),
    ] {
        if let Some(id) = host[field].as_str() {
            keys.push(record_key(collection, &id.to_ascii_uppercase()));
        }
    }
    if let Some(id) = host["proxyConfiguration"]["credentialID"].as_str() {
        keys.push(record_key("ssh_credentials", &id.to_ascii_uppercase()));
    }
    for scope in &config.scopes {
        if !matches!(scope.as_str(), "configuration" | "credentials") {
            continue;
        }
        let state = store.state(scope)?;
        for key in &keys {
            if let Some(record) = state.records.get(key) {
                if record.deleted() {
                    return Err(err(
                        "syncDeleted",
                        "连接使用的主机、凭证或代理已被删除，请重新选择配置。",
                    ));
                }
                if record.fields.iter().any(|(field, candidates)| {
                    let authentication = scope == "credentials"
                        || field == "$authentication"
                        || field.contains("credential")
                        || key.starts_with("ssh_proxy_profiles/");
                    authentication
                        && candidates.iter().any(|c| {
                            candidates
                                .first()
                                .is_some_and(|first| first.value != c.value)
                        })
                }) {
                    return Err(err(
                        "syncAuthenticationConflict",
                        "认证配置存在同步冲突。请在“数据同步 → 冲突”中选择要使用的配置后再连接。",
                    ));
                }
            }
        }
    }
    Ok(())
}
