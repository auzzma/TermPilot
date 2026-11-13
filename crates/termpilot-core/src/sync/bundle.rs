//! Self-contained encrypted versions. The existing causal merge and renewable
//! lease remain authoritative; local uploads are acknowledged only after CAS.
use super::{
    control::{self, Namespace},
    db_error, err,
    lease::Lease,
    model::{self, State},
    runtime,
    store::{Config, Store},
    transport::Objects,
    Result,
};
use crate::vault::{crypto, Vault};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use rusqlite::{params, OptionalExtension};
use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeMap,
    io::{Read, Write},
};

const MAGIC: &[u8] = b"TPSFULL1";
pub(super) const LIMIT: usize = 128 * 1024 * 1024;
const GRACE: i64 = 7 * 86400;
#[cfg(test)]
#[path = "bundle_tests.rs"]
mod tests;
pub(super) fn default_keep() -> u32 {
    10
}
pub(super) fn parse_keep(value: &Value) -> Result<u32> {
    value
        .as_u64()
        .filter(|n| (1..=100).contains(n))
        .map(|n| n as u32)
        .ok_or_else(|| {
            err(
                "syncHistorySettings",
                "历史版本保留数量须为 1–100 的整数，不包含当前版本。",
            )
        })
}
fn hash(bytes: &[u8]) -> String {
    hex::encode(Sha256::digest(bytes))
}
fn invalid() -> super::CoreError {
    err("syncBundle", "完整同步包损坏或版本不兼容，本机数据已保留。")
}

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
pub(super) struct Version {
    pub id: String,
    pub path: String,
    pub digest: String,
    pub revision: u64,
    pub at: i64,
    pub size: u64,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Retired {
    pub object: Version,
    pub after: i64,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct History {
    pub current: Option<Version>,
    pub versions: Vec<Version>,
    pub keep: u32,
    #[serde(default)]
    pub retired: Vec<Retired>,
    #[serde(default)]
    pub staged: Vec<Retired>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub legacy_objects: Vec<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub legacy_after: Option<i64>,
}
impl Default for History {
    fn default() -> Self {
        Self {
            current: None,
            versions: vec![],
            keep: default_keep(),
            retired: vec![],
            staged: vec![],
            legacy_objects: vec![],
            legacy_after: None,
        }
    }
}
pub(super) fn content_path(library: &str, path: &str) -> bool {
    ["current", "history"].iter().any(|kind| {
        path.strip_prefix(&format!("{kind}/full-{library}-"))
            // Keep reading earlier local v5 builds until their references have
            // been atomically relocated to the canonical directories.
            .or_else(|| path.strip_prefix(&format!("tp1-{library}-{kind}/full-")))
            .and_then(|s| s.strip_suffix(".tps"))
            .is_some_and(|s| s.len() == 64 && s.bytes().all(|b| b.is_ascii_hexdigit()))
    })
}
fn version_path(library: &str, kind: &str, digest: &str) -> String {
    format!("{kind}/full-{library}-{digest}.tps")
}
impl History {
    pub fn validate(&self, library: &str) -> Result<()> {
        parse_keep(&json!(self.keep))?;
        if self.legacy_objects.iter().any(|n| {
            !n.starts_with(&format!("tp1-{library}-"))
                || n.contains('/')
                || !super::maintenance::content_object(n)
        }) {
            return Err(invalid());
        }
        if self.versions.len() > 100 || self.retired.len() > 4096 || self.staged.len() > 256 {
            return Err(invalid());
        }
        let mut live = std::collections::BTreeSet::new();
        for v in self.current.iter().chain(&self.versions) {
            if !live.insert(v.path.clone()) {
                return Err(invalid());
            }
        }
        if self.retired.iter().any(|v| live.contains(&v.object.path)) {
            return Err(invalid());
        }
        for v in self
            .current
            .iter()
            .chain(&self.versions)
            .chain(self.retired.iter().map(|r| &r.object))
            .chain(self.staged.iter().map(|r| &r.object))
        {
            if uuid::Uuid::parse_str(&v.id).is_err()
                || !content_path(library, &v.path)
                || !v.path.ends_with(&format!("-{}.tps", v.digest))
                || v.size > LIMIT as u64
                || v.revision == 0
            {
                return Err(invalid());
            }
        }
        Ok(())
    }
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(tag = "format", content = "payload")]
enum Scope {
    /// Independently encrypted scopes preserve selective credential sharing.
    State(String),
    /// Unavailable legacy scopes remain complete ciphertext, never discarded.
    Legacy(BTreeMap<String, String>),
}
#[derive(Clone, Serialize, Deserialize)]
struct Package {
    schema: u32,
    library: String,
    id: String,
    revision: u64,
    at: i64,
    generation: String,
    key_sequence: u64,
    scopes: BTreeMap<String, Scope>,
}
fn seal<T: Serialize>(key: &[u8], value: &T, aad: &str) -> Result<Vec<u8>> {
    let bytes = zeroize::Zeroizing::new(serde_json::to_vec(value).map_err(|_| invalid())?);
    if bytes.len() > LIMIT {
        return Err(err(
            "syncSize",
            "完整同步版本超过 128 MiB，尚未发布；请调整同步范围。",
        ));
    }
    let mut z = flate2::write::ZlibEncoder::new(Vec::new(), flate2::Compression::fast());
    z.write_all(&bytes).map_err(|_| invalid())?;
    let compressed = zeroize::Zeroizing::new(z.finish().map_err(|_| invalid())?);
    crypto::seal(key, &compressed, aad.as_bytes())
}
fn open<T: DeserializeOwned>(key: &[u8], bytes: &[u8], aad: &str) -> Result<T> {
    let compressed = crypto::unseal(key, bytes, aad.as_bytes())?;
    let mut plain = zeroize::Zeroizing::new(Vec::new());
    flate2::read::ZlibDecoder::new(compressed.as_slice())
        .take((LIMIT + 1) as u64)
        .read_to_end(&mut plain)
        .map_err(|_| invalid())?;
    if plain.len() > LIMIT {
        return Err(invalid());
    }
    serde_json::from_slice(&plain).map_err(|_| invalid())
}
fn scope_aad(config: &Config, scope: &str) -> String {
    format!("TermPilot:full:1:{}:{scope}", config.library)
}
fn encode(config: &Config, package: &Package) -> Result<Vec<u8>> {
    let id = uuid::Uuid::parse_str(&config.library).map_err(|_| invalid())?;
    let key = config.scope_keys.get("configuration").ok_or_else(invalid)?;
    let cipher = seal(key, package, &scope_aad(config, "envelope"))?;
    let bytes = [MAGIC, id.as_bytes(), cipher.as_slice()].concat();
    if bytes.len() > LIMIT {
        return Err(invalid());
    }
    Ok(bytes)
}
fn decode(config: &Config, bytes: &[u8]) -> Result<Package> {
    if bytes.len() < 52
        || bytes.len() > LIMIT
        || !bytes.starts_with(MAGIC)
        || uuid::Uuid::from_slice(&bytes[8..24])
            .map_err(|_| invalid())?
            .to_string()
            != config.library
    {
        return Err(invalid());
    }
    let key = config.scope_keys.get("configuration").ok_or_else(invalid)?;
    let package: Package = open(key, &bytes[24..], &scope_aad(config, "envelope"))?;
    if package.schema != 1
        || package.library != config.library
        || uuid::Uuid::parse_str(&package.id).is_err()
        || !package.scopes.contains_key("configuration")
    {
        return Err(invalid());
    }
    Ok(package)
}
#[cfg(test)]
pub(super) fn verify_bytes(config: &Config, bytes: &[u8]) -> Result<()> {
    let p = decode(config, bytes)?;
    for scope in &config.scopes {
        if let Some(value) = p.scopes.get(scope) {
            scope_state(config, scope, value)?;
        }
    }
    Ok(())
}
struct Memory {
    objects: BTreeMap<String, Vec<u8>>,
}
impl Objects for Memory {
    fn list(&mut self) -> Result<Vec<String>> {
        Ok(self.objects.keys().cloned().collect())
    }
    fn get(&mut self, n: &str) -> Result<Option<Vec<u8>>> {
        Ok(self.objects.get(n).cloned())
    }
    fn put(&mut self, n: &str, b: &[u8]) -> Result<()> {
        self.objects.insert(n.into(), b.into());
        Ok(())
    }
    fn server_time(&self) -> Option<i64> {
        None
    }
}
fn scope_state(config: &Config, scope: &str, value: &Scope) -> Result<State> {
    let mut state = match value {
        Scope::State(bytes) => open(
            config.scope_keys.get(scope).ok_or_else(invalid)?,
            &B64.decode(bytes).map_err(|_| invalid())?,
            &scope_aad(config, scope),
        )?,
        Scope::Legacy(objects) => {
            let mut memory = Memory {
                objects: objects
                    .iter()
                    .map(|(n, b)| Ok((n.clone(), B64.decode(b).map_err(|_| invalid())?)))
                    .collect::<Result<_>>()?,
            };
            let mut names = memory.list()?;
            names.sort_by_key(|n| (n.contains("-receipt-"), n.clone()));
            let mut state = State::default();
            for name in names.iter().filter(|n| !n.contains("-chunk-")) {
                let (m, v, _) =
                    runtime::open_document_with(config, &mut memory, name, scope, None)?;
                match m.kind.as_str() {
                    "snapshot" => state.merge(
                        serde_json::from_value(v.get("state").unwrap_or(&v).clone())
                            .map_err(|_| invalid())?,
                    )?,
                    "batch" => {
                        for op in serde_json::from_value::<Vec<model::Operation>>(v)
                            .map_err(|_| invalid())?
                        {
                            state.receive(op, &config.library, scope)?;
                        }
                    }
                    "receipt" => {
                        for id in v["deletions"].as_array().ok_or_else(invalid)? {
                            state.publication(
                                id.as_str().ok_or_else(invalid)?,
                                v["publishedAt"].as_i64().ok_or_else(invalid)?,
                            );
                        }
                    }
                    _ => return Err(invalid()),
                }
            }
            state
        }
    };
    if !state.waiting.is_empty() {
        return Err(err("syncGap", "完整版本存在未完成的依赖，已停止发布。"));
    }
    let mut checked = State::default();
    checked.merge(std::mem::take(&mut state))?;
    Ok(checked)
}
fn cache(store: &Store<'_>, v: &Version, bytes: &[u8]) -> Result<()> {
    store.db.execute("INSERT INTO tp_sync_bundle_cache(digest,payload) VALUES(?1,?2) ON CONFLICT(digest) DO UPDATE SET payload=excluded.payload",params![v.digest,bytes]).map_err(db_error)?;
    Ok(())
}
fn tables(store: &Store<'_>) -> Result<()> {
    store.db.execute_batch("CREATE TABLE IF NOT EXISTS tp_sync_bundle_cache(digest TEXT PRIMARY KEY,payload BLOB NOT NULL);").map_err(db_error)
}
fn read_package(
    store: &Store<'_>,
    cloud: &mut dyn Objects,
    config: &Config,
    v: &Version,
    allow_cache: bool,
) -> Result<(Package, Vec<u8>)> {
    tables(store)?;
    let cached: Option<Vec<u8>> = store
        .db
        .query_row(
            "SELECT payload FROM tp_sync_bundle_cache WHERE digest=?1",
            [&v.digest],
            |r| r.get(0),
        )
        .optional()
        .map_err(db_error)?;
    let bytes = if allow_cache { cached.clone() } else { None };
    let bytes=match bytes { Some(b)=>b, None=>match cloud.get(&v.path)? {
        Some(b)=>b,
        None=>cached.ok_or_else(||err("syncMissing","当前完整同步包缺失且本机没有原始密文。请从其他设备或历史版本恢复，本机数据已保留。"))?,
    }};
    if hash(&bytes) != v.digest || bytes.len() as u64 != v.size {
        return Err(invalid());
    }
    let package = decode(config, &bytes)?;
    if package.id != v.id || package.revision != v.revision {
        return Err(invalid());
    }
    cache(store, v, &bytes)?;
    Ok((package, bytes))
}
fn remember_snapshot(
    store: &Store<'_>,
    config: &Config,
    v: &Version,
    p: &Package,
) -> Result<Value> {
    let mut objects = Vec::new();
    for scope in &config.scopes {
        if let Some(payload) = p.scopes.get(scope) {
            let state = scope_state(config, scope, payload)?;
            let name = format!("full:{}:{scope}", v.id);
            store.put(&format!("snapshot:{name}"), &state)?;
            objects.push(json!({"scope":scope,"name":name,"frontier":state.frontier}));
        }
    }
    let at = chrono::DateTime::from_timestamp(v.at, 0)
        .ok_or_else(invalid)?
        .to_rfc3339();
    Ok(
        json!({"id":v.id,"at":at,"scopes":p.scopes.keys().collect::<Vec<_>>(),"objects":objects,"verified":true,"fullVersion":true,"size":v.size}),
    )
}
fn ingest(store: &Store<'_>, config: &Config, p: &Package) -> Result<()> {
    store.transaction(|| {
        for scope in &config.scopes {
            let Some(payload)=p.scopes.get(scope) else {
                if !store.published_state(scope)?.frontier.is_empty() { return Err(err("syncRollback","完整版本缺少已确认的数据范围。")); }
                continue;
            };
            let remote=scope_state(config,scope,payload)?;
            let known=store.published_state(scope)?;
            if !model::covers(&remote.frontier,&known.frontier) { return Err(err("syncRollback","云端完整版本早于本机已确认的数据，已停止同步。")); }
            let mut current=store.state(scope)?; current.merge(remote.clone())?;
            store.save_state(scope,&current)?;
            store.put(&format!("baseline:{scope}"),&remote)?;
            for (writer,seq) in &remote.frontier {
                store.db.execute("UPDATE tp_sync_operations SET published=1 WHERE scope=?1 AND writer=?2 AND seq<=?3",params![scope,writer,seq]).map_err(db_error)?;
            }
        }
        Ok(())
    })
}

/// Repair only byte-identical, content-addressed legacy objects. Received names
/// are not erased. A missing manifest is verified together with its dependencies.
pub(super) fn repair_legacy(
    store: &Store<'_>,
    cloud: &mut dyn Objects,
    lease: &Lease,
) -> Result<usize> {
    let config = store.config()?;
    let mut ns = Namespace {
        cloud,
        library: config.library.clone(),
        generation: config.generation.clone(),
        guard: Some(lease),
    };
    let names = ns.list()?;
    let mut expected = names.clone();
    let mut stmt = store
        .db
        .prepare("SELECT name FROM tp_sync_received")
        .map_err(db_error)?;
    expected.extend(
        stmt.query_map([], |r| r.get::<_, String>(0))
            .map_err(db_error)?
            .collect::<rusqlite::Result<Vec<_>>>()
            .map_err(db_error)?,
    );
    expected.sort();
    expected.dedup();
    let mut repair = BTreeMap::new();
    for name in expected {
        let present = ns.get(&name)?;
        if let Some(bytes) = &present {
            if !name.ends_with(&format!("-{}.tps", hash(bytes))) {
                return Err(invalid());
            }
        }
        if present.is_some() && names.contains(&name) {
            continue;
        }
        let bytes: Option<Vec<u8>> = match present {
            Some(bytes) => Some(bytes),
            None => store
                .db
                .query_row(
                    "SELECT payload FROM tp_sync_objects WHERE name=?1",
                    [&name],
                    |r| r.get(0),
                )
                .optional()
                .map_err(db_error)?,
        };
        let bytes=bytes.ok_or_else(||err("syncMissing","云端缺少已确认对象，且本机没有对应原始密文。请恢复云端备份或在有完整缓存的设备上重试。"))?;
        if !name.ends_with(&format!("-{}.tps", hash(&bytes))) {
            return Err(invalid());
        }
        repair.insert(name, bytes);
    }
    if repair.is_empty() {
        return Ok(0);
    }
    // Read-only overlay validates documents before the first repair write.
    struct Overlay<'a> {
        source: &'a mut dyn Objects,
        patch: &'a BTreeMap<String, Vec<u8>>,
    }
    impl Objects for Overlay<'_> {
        fn list(&mut self) -> Result<Vec<String>> {
            self.source.list()
        }
        fn get(&mut self, n: &str) -> Result<Option<Vec<u8>>> {
            match self.patch.get(n) {
                Some(b) => Ok(Some(b.clone())),
                None => self.source.get(n),
            }
        }
        fn put(&mut self, _: &str, _: &[u8]) -> Result<()> {
            Err(invalid())
        }
        fn server_time(&self) -> Option<i64> {
            self.source.server_time()
        }
    }
    let mut overlay = Overlay {
        source: &mut ns,
        patch: &repair,
    };
    for name in repair.keys().filter(|n| !n.contains("-chunk-")) {
        let scope = config
            .scope_keys
            .keys()
            .find(|s| {
                ["batch", "snapshot", "receipt"]
                    .iter()
                    .any(|k| name.starts_with(&format!("tp1-{}-{k}-{s}-", config.library)))
            })
            .ok_or_else(|| err("syncKey", "缺少校验待恢复文件的同步范围密钥。"))?;
        runtime::open_document_with(&config, &mut overlay, name, scope, None)?;
    }
    let mut order: Vec<_> = repair.iter().collect();
    order.sort_by_key(|(n, _)| !n.contains("-chunk-"));
    for (name, bytes) in order {
        ns.put(name, bytes)?;
    }
    store.put(
        "objectRecovery",
        &json!({"restored":repair.len(),"at":chrono::Utc::now().to_rfc3339()}),
    )?;
    Ok(repair.len())
}

fn backup(vault: &Vault, store: &Store<'_>, migration: bool) -> Result<()> {
    if migration
        && store
            .get::<bool>("fullVersionMigrationBackup")?
            .unwrap_or(false)
    {
        return Ok(());
    }
    let path = vault.directory.join(format!(
        "vault.before-full-sync-{}.sqlite",
        uuid::Uuid::new_v4()
    ));
    vault
        .db
        .backup(rusqlite::DatabaseName::Main, &path, None)
        .map_err(db_error)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))
            .map_err(|_| err("syncBackup", "无法保护同步升级备份。"))?;
    }
    if migration {
        store.put("fullVersionMigrationBackup", &true)?;
    }
    Ok(())
}
pub(super) fn repair(
    vault: &Vault,
    store: &Store<'_>,
    cloud: &mut dyn Objects,
    lease: &Lease,
) -> Result<usize> {
    backup(vault, store, false)?;
    if let Some(v) = lease.head()?.bundles.and_then(|h| h.current) {
        let (_, bytes) = read_package(store, cloud, &store.config()?, &v, false)?;
        lease.check(cloud)?;
        let missing = cloud.get(&v.path)?.is_none();
        cloud.put(&v.path, &bytes)?;
        check_reference(&v, &cloud.get(&v.path)?.ok_or_else(invalid)?)?;
        lease.check(cloud)?;
        Ok(usize::from(missing))
    } else {
        repair_legacy(store, cloud, lease)
    }
}
fn legacy_scopes(
    store: &Store<'_>,
    cloud: &mut dyn Objects,
    lease: &Lease,
) -> Result<BTreeMap<String, Scope>> {
    let config = store.config()?;
    let mut ns = Namespace {
        cloud,
        library: config.library.clone(),
        generation: config.generation.clone(),
        guard: Some(lease),
    };
    let mut result: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    for name in ns.list()? {
        let suffix = name
            .strip_prefix(&format!("tp1-{}-", config.library))
            .ok_or_else(invalid)?;
        let rest = suffix.split_once('-').ok_or_else(invalid)?.1;
        let scope = rest.split_once('-').ok_or_else(invalid)?.0;
        if config.scopes.iter().any(|s| s == scope) {
            continue;
        }
        let bytes = ns.get(&name)?.ok_or_else(|| {
            err(
                "syncMissing",
                "停用范围的云端数据缺失，不能迁移为完整版本。",
            )
        })?;
        if !name.ends_with(&format!("-{}.tps", hash(&bytes))) {
            return Err(invalid());
        }
        result
            .entry(scope.into())
            .or_default()
            .insert(name, B64.encode(bytes));
    }
    Ok(result
        .into_iter()
        .map(|(s, v)| (s, Scope::Legacy(v)))
        .collect())
}
fn check_reference(v: &Version, bytes: &[u8]) -> Result<()> {
    if bytes.len() as u64 != v.size || hash(bytes) != v.digest {
        return Err(invalid());
    }
    Ok(())
}
fn upload(
    store: &Store<'_>,
    cloud: &mut dyn Objects,
    lease: &Lease,
    h: &mut History,
    v: &Version,
    bytes: &[u8],
) -> Result<()> {
    check_reference(v, bytes)?;
    // Register before PUT so a crashed writer never leaves undiscoverable files.
    if !h.staged.iter().any(|s| s.object.path == v.path) {
        h.staged.push(Retired {
            object: v.clone(),
            after: super::lease::cloud_time(cloud)? + GRACE,
        });
        // Do not publish v5 until a complete current package exists. On legacy
        // migration the exact staged ciphertext is also cached durably locally.
        lease.publish_bundles(cloud, h.clone())?;
    }
    cache(store, v, bytes)?;
    lease.check(cloud)?;
    super::progress::stage("uploading", 0, Some(1));
    cloud.put(&v.path, bytes)?;
    let readback = cloud.get(&v.path)?.ok_or_else(invalid)?;
    check_reference(v, &readback)?;
    super::progress::bytes("uploadedBytes", bytes.len());
    super::progress::bytes("verifiedBytes", readback.len());
    lease.check(cloud)
}
fn relocate_layout(
    vault: &Vault,
    store: &Store<'_>,
    cloud: &mut dyn Objects,
    lease: &Lease,
    h: &mut History,
) -> Result<()> {
    let config = store.config()?;
    let moves: Vec<_> = h
        .current
        .iter()
        .map(|v| ("current", v))
        .chain(h.versions.iter().map(|v| ("history", v)))
        .filter_map(|(kind, old)| {
            let path = version_path(&config.library, kind, &old.digest);
            (path != old.path).then(|| {
                (
                    old.clone(),
                    Version {
                        path,
                        ..old.clone()
                    },
                )
            })
        })
        .collect();
    if moves.is_empty() {
        return Ok(());
    }
    backup(vault, store, false)?;
    // Validate every source before publishing any new references. An interrupted
    // copy leaves the original current/history references and all data intact.
    for (old, _) in &moves {
        read_package(store, cloud, &config, old, false)?;
    }
    for (old, new) in &moves {
        let (_, bytes) = read_package(store, cloud, &config, old, true)?;
        upload(store, cloud, lease, h, new, &bytes)?;
    }
    let mut committed = h.clone();
    let after = super::lease::cloud_time(cloud)? + GRACE;
    for (old, new) in moves {
        for reference in committed
            .current
            .iter_mut()
            .chain(committed.versions.iter_mut())
        {
            if reference.path == old.path {
                *reference = new.clone();
            }
        }
        committed.staged.retain(|r| r.object.path != new.path);
        committed.retired.push(Retired { object: old, after });
    }
    lease.publish_bundles(cloud, committed.clone())?;
    *h = committed;
    Ok(())
}

fn catalog(store: &Store<'_>, h: &History) -> Result<()> {
    let config = store.config()?;
    let mut entries = Vec::new();
    for v in h.current.iter().chain(&h.versions) {
        let at = chrono::DateTime::from_timestamp(v.at, 0)
            .ok_or_else(invalid)?
            .to_rfc3339();
        let bytes: Option<Vec<u8>> = store
            .db
            .query_row(
                "SELECT payload FROM tp_sync_bundle_cache WHERE digest=?1",
                [&v.digest],
                |r| r.get(0),
            )
            .optional()
            .map_err(db_error)?;
        entries.push(if let Some(bytes)=bytes {
            let p=decode(&config,&bytes)?; remember_snapshot(store,&config,v,&p)?
        } else {json!({"id":v.id,"at":at,"verified":true,"fullVersion":true,"size":v.size,"objects":[],"scopes":[]})});
    }
    // A background sync must not remove a file the user is still previewing.
    entries.extend(
        store
            .get::<Vec<Value>>("snapshots")?
            .unwrap_or_default()
            .into_iter()
            .filter(|entry| entry["importedFile"] == true),
    );
    store.put("snapshots", &entries)?;
    store.put("bundleHistory", h)
}
fn acknowledge(store: &Store<'_>, config: &Config, p: &Package) -> Result<()> {
    // Ingest rechecks operation fingerprints, and only acknowledges sequences
    // contained in this committed package. Newer local edits remain pending.
    ingest(store, config, p)?;
    store.transaction(|| {
        store
            .db
            .execute("DELETE FROM tp_sync_received", [])
            .map_err(db_error)?;
        store
            .db
            .execute("UPDATE tp_sync_objects SET published=1", [])
            .map_err(db_error)?;
        store.put("bundleRevision", &p.revision)?;
        store.put(
            "lastCheck",
            &json!({"at":chrono::Utc::now().to_rfc3339(),"revision":p.revision}),
        )?;
        store.remove("forceFullVersion")?;
        Ok(())
    })
}
fn cleanup(
    store: &Store<'_>,
    cloud: &mut dyn Objects,
    lease: &Lease,
    h: &mut History,
) -> Result<()> {
    let now = super::lease::cloud_time(cloud)?;
    if let Some(v) = &h.current {
        // Verify the actual cloud package before deleting ANY recovery copy.
        let bytes = cloud
            .get(&v.path)?
            .ok_or_else(|| err("syncMissing", "当前完整包缺失，已暂停历史清理。"))?;
        check_reference(v, &bytes)?;
    }
    let mut deleted = 0;
    let targets: Vec<_> = h
        .retired
        .iter()
        .chain(&h.staged)
        .filter(|r| r.after <= now)
        .take(32)
        .cloned()
        .collect();
    for r in targets {
        if h.current
            .iter()
            .chain(&h.versions)
            .any(|v| v.path == r.object.path)
        {
            continue;
        }
        lease.check(cloud)?;
        cloud.remove_retired(&r.object.path)?;
        h.retired.retain(|v| v.object.path != r.object.path);
        h.staged.retain(|v| v.object.path != r.object.path);
        deleted += 1;
    }
    if h.legacy_after.is_some_and(|at| at <= now) {
        for path in h.legacy_objects.clone().into_iter().take(32) {
            lease.check(cloud)?;
            cloud.remove_retired(&path)?;
            h.legacy_objects.retain(|n| n != &path);
            deleted += 1;
        }
        if h.legacy_objects.is_empty() {
            h.legacy_after = None;
        }
    }
    if deleted > 0 {
        lease.publish_bundles(cloud, h.clone())?;
    }
    store.put("maintenanceStatus",&json!({"phase":"completed","checkedAt":now,"deleted":deleted,"historyCount":h.versions.len(),"historyLimit":h.keep,"protectedVersions":h.retired.len()+h.staged.len(),"protectedLegacyObjects":h.legacy_objects.len(),"fullVersions":true}))
}

pub(super) fn run(
    vault: &Vault,
    store: &Store<'_>,
    cloud: &mut dyn Objects,
    lease: &Lease,
) -> Result<()> {
    tables(store)?;
    let config = store.config()?;
    let original = lease.head()?;
    if original
        .bundles
        .as_ref()
        .is_some_and(|h| h.current.is_some())
        && original.catalog.as_ref().is_some_and(|c| !c.is_empty())
    {
        return Err(err(
            "syncVersion",
            "完整版本目录中出现旧格式或未知内容，请升级所有客户端并检查云端。",
        ));
    }
    let migrating = original
        .bundles
        .as_ref()
        .is_none_or(|h| h.current.is_none());
    let mut h = original.bundles.clone().unwrap_or_default();
    let mut p = if let Some(v) = &h.current {
        let (p, bytes) = read_package(store, cloud, &config, v, false)?;
        // If exact original ciphertext was recovered from the local cache, a
        // create-only PUT repairs it. Existing objects must match byte-for-byte.
        lease.check(cloud)?;
        cloud.put(&v.path, &bytes)?;
        lease.check(cloud)?;
        if p.generation != config.generation
            || p.key_sequence != config.generation_sequence
            || p.revision < store.get::<u64>("bundleRevision")?.unwrap_or(0)
        {
            return Err(err("syncRollback", "云端完整版本发生回退，已停止同步。"));
        }
        ingest(store, &config, &p)?;
        p
    } else {
        backup(vault, store, true)?;
        repair_legacy(store, cloud, lease)?;
        {
            let mut ns = Namespace {
                cloud,
                library: config.library.clone(),
                generation: config.generation.clone(),
                guard: Some(lease),
            };
            if !ns.list()?.is_empty() {
                runtime::exchange(store, &mut ns)?;
            }
        }
        let mut scopes = legacy_scopes(store, cloud, lease)?;
        // Explicit destination moves retain opaque disabled ranges from the
        // previous self-contained package, even when this device lacks their keys.
        if let Some(previous) = store
            .get::<History>("bundleHistory")?
            .and_then(|h| h.current)
        {
            let cached: Option<Vec<u8>> = store
                .db
                .query_row(
                    "SELECT payload FROM tp_sync_bundle_cache WHERE digest=?1",
                    [&previous.digest],
                    |r| r.get(0),
                )
                .optional()
                .map_err(db_error)?;
            if let Some(bytes) = cached {
                check_reference(&previous, &bytes)?;
                for (scope, payload) in decode(&config, &bytes)?.scopes {
                    scopes.entry(scope).or_insert(payload);
                }
            } else {
                return Err(err(
                    "syncMissing",
                    "迁移目标前缺少上一完整版本的本机缓存，请先恢复原同步位置并完成同步。",
                ));
            }
        }
        Package {
            schema: 1,
            library: config.library.clone(),
            id: uuid::Uuid::new_v4().to_string(),
            revision: 0,
            at: 0,
            generation: config.generation.clone(),
            key_sequence: config.generation_sequence,
            scopes,
        }
    };
    relocate_layout(vault, store, cloud, lease, &mut h)?;
    runtime::expire_recycle(store, cloud.server_time())?;
    let now = super::lease::cloud_time(cloud)?;
    if migrating && h.legacy_objects.is_empty() {
        let head = lease.head()?;
        let prefix = if config.generation.is_empty() {
            format!("tp1-{}-", config.library)
        } else {
            format!("tp1-{}-g-{}-", config.library, config.generation)
        };
        h.legacy_objects = lease
            .names(cloud)?
            .iter()
            .map(|n| {
                format!(
                    "{prefix}{}",
                    n.strip_prefix(&format!("tp1-{}-", config.library)).unwrap()
                )
            })
            .collect();
        h.legacy_objects.extend(head.catalog.unwrap_or_default());
        h.legacy_objects
            .extend(cloud.list()?.into_iter().filter(|n| {
                n.strip_prefix(&prefix).is_some_and(|s| {
                    ["chunk-", "batch-", "snapshot-", "receipt-", "catalog-"]
                        .iter()
                        .any(|p| s.starts_with(p))
                }) && super::maintenance::content_object(n)
            }));
        h.legacy_objects.sort();
        h.legacy_objects.dedup();
        if !h.legacy_objects.is_empty() {
            h.legacy_after = Some(now + GRACE);
        }
    }
    let mut changed = migrating || store.get::<bool>("forceFullVersion")?.unwrap_or(false);
    for scope in &config.scopes {
        let mut state = store.state(scope)?;
        if !state.waiting.is_empty() {
            return Err(err("syncGap", "尚有缺失的修改依赖，不能生成完整版本。"));
        }
        for id in state.recycle.keys().cloned().collect::<Vec<_>>() {
            state.publication(&id, now);
        }
        let before = p
            .scopes
            .get(scope)
            .map(|s| scope_state(&config, scope, s))
            .transpose()?;
        if before.as_ref() != Some(&state) {
            let cipher = seal(
                config.scope_keys.get(scope).ok_or_else(invalid)?,
                &state,
                &scope_aad(&config, scope),
            )?;
            p.scopes
                .insert(scope.clone(), Scope::State(B64.encode(cipher)));
            changed = true;
        }
    }
    if let Some(keep) = store.get::<u32>("pendingHistoryKeep")? {
        h.keep = parse_keep(&json!(keep))?;
    }
    if changed {
        p.id = uuid::Uuid::new_v4().to_string();
        p.revision = h
            .current
            .as_ref()
            .map_or(1, |v| v.revision.saturating_add(1));
        p.at = now;
        let bytes = encode(&config, &p)?;
        let digest = hash(&bytes);
        let v = Version {
            id: p.id.clone(),
            path: version_path(&config.library, "current", &digest),
            digest,
            revision: p.revision,
            at: now,
            size: bytes.len() as u64,
        };
        upload(store, cloud, lease, &mut h, &v, &bytes)?;
        if let Some(previous) = h.current.clone() {
            let (_, old_bytes) = read_package(store, cloud, &config, &previous, true)?;
            let mut archived = previous.clone();
            archived.path = version_path(&config.library, "history", &archived.digest);
            upload(store, cloud, lease, &mut h, &archived, &old_bytes)?;
            h.staged.retain(|r| r.object.path != archived.path);
            h.versions.insert(0, archived);
            // The previous current object has an identical, verified history
            // copy. Readers are serialized by this lease; retire the old alias.
            h.retired.push(Retired {
                object: previous,
                after: now,
            });
        }
        h.current = Some(v.clone());
        h.staged.retain(|r| r.object.path != v.path);
    }
    while h.versions.len() > h.keep as usize {
        h.retired.push(Retired {
            object: h.versions.pop().unwrap(),
            after: now + GRACE,
        });
    }
    lease.publish_bundles(cloud, h.clone())?;
    store.remove("pendingHistoryKeep")?;
    acknowledge(store, &config, &p)?;
    catalog(store, &h)?;
    // Cleanup is independent of successful publication, and may safely retry.
    if let Err(e) = cleanup(store, cloud, lease, &mut h) {
        store.put(
            "maintenanceStatus",
            &json!({"phase":"failed","message":e.message,"fullVersions":true}),
        )?;
    }
    store.put("bundleHistory", &h)?;
    Ok(())
}

pub(super) fn load_snapshot(store: &Store<'_>, id: &str) -> Result<()> {
    let Some(h) = store.get::<History>("bundleHistory")? else {
        return Ok(());
    };
    let Some(v) = h.current.iter().chain(&h.versions).find(|v| v.id == id) else {
        return Ok(());
    };
    let config = store.config()?;
    let mut cloud = super::transport::Backend::new(config.provider.clone(), &config.library)?;
    let lease = control::acquire(store, &mut cloud, "history")?;
    let result = (|| {
        let (p, _) = read_package(store, &mut cloud, &config, v, true)?;
        let entry = remember_snapshot(store, &config, v, &p)?;
        let mut snapshots = store.get::<Vec<Value>>("snapshots")?.unwrap_or_default();
        snapshots.retain(|s| s["id"] != id);
        snapshots.push(entry);
        store.put("snapshots", &snapshots)
    })();
    let released = control::release(store, &mut cloud, &lease);
    result.and(released)
}

/// Import one file without cloud control/history objects. Only the explicitly
/// enabled local scopes are exposed to the existing preview/copy restoration UI.
pub(super) fn import_file(store: &Store<'_>, request: &Value) -> Result<Value> {
    let path = std::path::Path::new(request["path"].as_str().ok_or_else(invalid)?);
    if !path.is_absolute() || std::fs::metadata(path).map_err(|_| invalid())?.len() > LIMIT as u64 {
        return Err(invalid());
    }
    let mut bytes = Vec::new();
    std::fs::File::open(path)
        .map_err(|_| invalid())?
        .take((LIMIT + 1) as u64)
        .read_to_end(&mut bytes)
        .map_err(|_| invalid())?;
    if bytes.len() > LIMIT {
        return Err(invalid());
    }
    if bytes.len() < 24 || !bytes.starts_with(MAGIC) {
        return Err(invalid());
    }
    let mut config = store.config()?;
    config.library = uuid::Uuid::from_slice(&bytes[8..24])
        .map_err(|_| invalid())?
        .to_string();
    config.scope_keys = runtime::derive_keys(
        request["passphrase"].as_str().unwrap_or(""),
        &config.library,
    )?;
    let package = decode(&config, &bytes)?;
    let id = uuid::Uuid::new_v4().to_string();
    let v = Version {
        id: id.clone(),
        path: String::new(),
        digest: hash(&bytes),
        revision: package.revision,
        at: package.at,
        size: bytes.len() as u64,
    };
    store.transaction(|| {
        let mut entry = remember_snapshot(store, &config, &v, &package)?;
        entry["importedFile"] = json!(true);
        let mut entries = store.get::<Vec<Value>>("snapshots")?.unwrap_or_default();
        entries.push(entry);
        store.put("snapshots", &entries)
    })?;
    Ok(json!({"id":id,"imported":true,"scopes":config.scopes}))
}

/// Re-encrypt each retained self-contained version before one atomic key epoch
/// switch. Durable ciphertext mappings make interrupted retries idempotent.
pub(super) fn rotate(
    store: &Store<'_>,
    cloud: &mut dyn Objects,
    lease: &Lease,
    old: &Config,
    new: &Config,
) -> Result<()> {
    let mut source = lease.head()?.bundles.ok_or_else(invalid)?;
    let mut target = History {
        keep: source.keep,
        retired: source.retired.clone(),
        staged: source.staged.clone(),
        legacy_objects: source.legacy_objects.clone(),
        legacy_after: source.legacy_after,
        ..History::default()
    };
    let versions: Vec<_> = source
        .current
        .iter()
        .chain(&source.versions)
        .cloned()
        .collect();
    // Verify every retained source package before emitting new ciphertext.
    for v in &versions {
        read_package(store, cloud, old, v, false)?;
    }
    for (index, v) in versions.iter().enumerate() {
        let mapping = format!("bundleRekey:{}:{}", new.generation, v.digest);
        let (mut p, _) = read_package(store, cloud, old, v, true)?;
        let (mapped, bytes) = if let Some(mapped) = store.get::<Version>(&mapping)? {
            let (_, bytes) = read_package(store, cloud, new, &mapped, true)?;
            (mapped, bytes)
        } else {
            for (scope, bytes) in p.scopes.iter_mut() {
                let state = scope_state(old, scope, bytes)?;
                *bytes = Scope::State(B64.encode(seal(
                    new.scope_keys.get(scope).ok_or_else(invalid)?,
                    &state,
                    &scope_aad(new, scope),
                )?));
            }
            p.generation = new.generation.clone();
            p.key_sequence = new.generation_sequence;
            let bytes = encode(new, &p)?;
            let digest = hash(&bytes);
            let kind = if index == 0 { "current" } else { "history" };
            let mapped = Version {
                path: version_path(&new.library, kind, &digest),
                digest,
                size: bytes.len() as u64,
                ..v.clone()
            };
            cache(store, &mapped, &bytes)?;
            store.put(&mapping, &mapped)?;
            (mapped, bytes)
        };
        upload(store, cloud, lease, &mut source, &mapped, &bytes)?;
        if index == 0 {
            target.current = Some(mapped);
        } else {
            target.versions.push(mapped);
        }
        target.retired.push(Retired {
            object: v.clone(),
            after: super::lease::cloud_time(cloud)? + GRACE,
        });
    }
    lease.cutover_bundles(cloud, new, target)
}
