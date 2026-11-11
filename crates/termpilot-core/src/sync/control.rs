//! Conditional, authenticated library control. A lock is deliberately not stolen
//! on a timer: a timed-out uploader may still be executing at the storage server.
//! Its originating vault can resume after a crash using its durable token.
use super::{
    err,
    store::{Config, Store},
    transport::Objects,
    Result,
};
use hmac::{Hmac, Mac};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::Sha256;

#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Lock {
    pub device: String,
    pub token: String,
    pub kind: String,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Head {
    pub version: u32,
    pub library: String,
    pub generation: String,
    pub sequence: u64,
    pub lock: Option<Lock>,
    pub authentication: String,
}
impl Head {
    pub fn new(config: &Config) -> Self {
        Self {
            version: 2,
            library: config.library.clone(),
            generation: config.generation.clone(),
            sequence: config.generation_sequence,
            lock: None,
            authentication: String::new(),
        }
    }
    fn message(&self) -> Result<Vec<u8>> {
        let mut value = self.clone();
        value.authentication.clear();
        serde_json::to_vec(&value).map_err(|_| err("syncControl", "无法编码同步控制信息。"))
    }
    pub fn signed(&self, config: &Config) -> Result<Vec<u8>> {
        let mut value = self.clone();
        let key = config
            .scope_keys
            .get("configuration")
            .ok_or_else(|| err("syncKey", "缺少同步密钥。"))?;
        let mut mac =
            Hmac::<Sha256>::new_from_slice(key).map_err(|_| err("syncKey", "同步密钥无效。"))?;
        mac.update(b"TermPilot:sync:control:2:");
        mac.update(&value.message()?);
        value.authentication = hex::encode(mac.finalize().into_bytes());
        serde_json::to_vec(&value).map_err(|_| err("syncControl", "无法编码同步控制信息。"))
    }
    pub fn verify(&self, config: &Config) -> Result<()> {
        if self.version != 2
            || self.library != config.library
            || (!self.generation.is_empty() && uuid::Uuid::parse_str(&self.generation).is_err())
        {
            return Err(err(
                "syncControl",
                "云端同步控制信息无效，请更新应用或检查云端。",
            ));
        }
        let key = config
            .scope_keys
            .get("configuration")
            .ok_or_else(|| err("syncKey", "缺少同步密钥。"))?;
        let mut mac =
            Hmac::<Sha256>::new_from_slice(key).map_err(|_| err("syncKey", "同步密钥无效。"))?;
        mac.update(b"TermPilot:sync:control:2:");
        mac.update(&self.message()?);
        let signature = hex::decode(&self.authentication)
            .map_err(|_| err("syncControl", "同步控制信息校验失败。"))?;
        mac.verify_slice(&signature).map_err(|_| {
            err(
                "syncPasswordChanged",
                "同步 Key 已更改或 Key 不正确，请输入当前同步 Key。",
            )
        })
    }
}
pub(super) fn name(library: &str) -> String {
    format!("tp1-{library}-control.tps")
}
pub(super) fn read(cloud: &mut dyn Objects, library: &str) -> Result<Option<(Head, Vec<u8>)>> {
    cloud
        .get(&name(library))?
        .map(|bytes| {
            let head: Head = serde_json::from_slice(&bytes)
                .map_err(|_| err("syncControl", "云端同步控制信息损坏，已停止同步。"))?;
            Ok((head, bytes))
        })
        .transpose()
}
pub(super) struct Lease {
    pub head: Head,
    pub bytes: Vec<u8>,
}
pub(super) fn acquire(store: &Store<'_>, cloud: &mut dyn Objects, kind: &str) -> Result<Lease> {
    let config = store.config()?;
    let previous = read(cloud, &config.library)?;
    let mut head = previous
        .as_ref()
        .map(|(h, _)| h.clone())
        .unwrap_or_else(|| Head::new(&config));
    if previous.is_none()
        && (!config.generation.is_empty() || config.generation_sequence > 0)
        && !store.get::<bool>("allowControlCreate")?.unwrap_or(false)
    {
        return Err(err(
            "syncRollback",
            "云端缺少已确认的 Key 版本，已停止同步。",
        ));
    }
    if head.sequence < config.generation_sequence {
        return Err(err("syncRollback", "云端 Key 版本回退，已停止同步。"));
    }
    if head.generation != config.generation || head.sequence != config.generation_sequence {
        store.put("passwordRequired", &true)?;
        return Err(err(
            "syncPasswordChanged",
            "同步 Key 已更改，请输入当前 Key；本机未同步修改已保留。",
        ));
    }
    if previous.is_some() {
        if let Err(error) = head.verify(&config) {
            if error.code == "syncPasswordChanged" {
                store.put("passwordRequired", &true)?;
            }
            return Err(error);
        }
    } else {
        // Verify an existing legacy library before installing its first control
        // header. A typo in the password must never claim someone else's data.
        for name in cloud.list()? {
            if config.scope_keys.keys().any(|scope| {
                ["snapshot", "batch", "receipt"].iter().any(|kind| {
                    name.starts_with(&format!("tp1-{}-{kind}-{scope}-", config.library))
                })
            }) {
                let scope = config
                    .scope_keys
                    .keys()
                    .find(|scope| name.contains(&format!("-{scope}-")))
                    .unwrap();
                let bytes = cloud
                    .get(&name)?
                    .ok_or_else(|| err("syncMissing", "已有同步对象暂时缺失。"))?;
                crate::vault::crypto::unseal(
                    &config.scope_keys[scope],
                    &bytes,
                    format!("TermPilot:sync:1:{}:{scope}", config.library).as_bytes(),
                )
                .map_err(|_| err("syncPassword", "同步 Key 不正确，未创建云端控制信息。"))?;
                break;
            }
        }
    }
    let saved = store.get::<String>("cloudLockToken")?;
    if let Some(lock) = &head.lock {
        if lock.device != config.device || saved.as_deref() != Some(lock.token.as_str()) {
            store.put(
                "remoteSyncBusy",
                &json!({"device":lock.device,"kind":lock.kind}),
            )?;
            return Err(err(
                "syncCloudBusy",
                "其它设备正在同步或更改 Key。若操作中断，请在该设备重新打开同步设置并重试。",
            ));
        }
    }
    let token = saved.unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
    store.put("cloudLockToken", &token)?;
    head.lock = Some(Lock {
        device: config.device.clone(),
        token,
        kind: kind.into(),
    });
    let bytes = head.signed(&config)?;
    if !cloud.compare_exchange(
        &name(&config.library),
        previous.as_ref().map(|(_, b)| b.as_slice()),
        &bytes,
    )? {
        return Err(err(
            "syncCloudBusy",
            "云端同步状态已变化，请重试；本机修改已保留。",
        ));
    }
    store.put("allowControlCreate", &false)?;
    store.put("remoteSyncBusy", &Value::Null)?;
    Ok(Lease { head, bytes })
}
pub(super) fn release(store: &Store<'_>, cloud: &mut dyn Objects, lease: &Lease) -> Result<()> {
    let config = store.config()?;
    let mut head = lease.head.clone();
    head.lock = None;
    let bytes = head.signed(&config)?;
    if !cloud.compare_exchange(&name(&config.library), Some(&lease.bytes), &bytes)? {
        return Err(err(
            "syncCloudBusy",
            "同步控制信息已变化，未解除其它操作的锁。",
        ));
    }
    store.remove("cloudLockToken")?;
    Ok(())
}
/// The exchange engine keeps content-addressed logical names. A generation has
/// an isolated physical namespace so staging never overwrites a working library.
pub(super) struct Namespace<'a> {
    pub cloud: &'a mut dyn Objects,
    pub library: String,
    pub generation: String,
    pub guard: Option<Vec<u8>>,
}
impl Namespace<'_> {
    fn prefix(&self) -> String {
        if self.generation.is_empty() {
            format!("tp1-{}-", self.library)
        } else {
            format!("tp1-{}-g-{}-", self.library, self.generation)
        }
    }
    fn physical(&self, name: &str) -> Result<String> {
        let suffix = name
            .strip_prefix(&format!("tp1-{}-", self.library))
            .ok_or_else(|| err("syncObject", "同步对象不属于当前库。"))?;
        if !["batch-", "snapshot-", "receipt-", "chunk-"]
            .iter()
            .any(|p| suffix.starts_with(p))
        {
            return Err(err("syncObject", "同步对象类型无效。"));
        }
        Ok(format!("{}{suffix}", self.prefix()))
    }
    pub fn check(&mut self) -> Result<()> {
        if let Some(bytes) = &self.guard {
            if self.cloud.get(&name(&self.library))?.as_ref() != Some(bytes) {
                return Err(err("syncCloudBusy", "云端同步锁已变化，已停止发布。"));
            }
        }
        Ok(())
    }
}
impl Objects for Namespace<'_> {
    fn list(&mut self) -> Result<Vec<String>> {
        let prefix = self.prefix();
        Ok(self
            .cloud
            .list()?
            .into_iter()
            .filter_map(|name| name.strip_prefix(&prefix).map(str::to_owned))
            .filter(|s| {
                ["batch-", "snapshot-", "receipt-", "chunk-"]
                    .iter()
                    .any(|p| s.starts_with(p))
            })
            .map(|s| format!("tp1-{}-{s}", self.library))
            .collect())
    }
    fn get(&mut self, name: &str) -> Result<Option<Vec<u8>>> {
        self.cloud.get(&self.physical(name)?)
    }
    fn put(&mut self, name: &str, data: &[u8]) -> Result<()> {
        self.check()?;
        self.cloud.put(&self.physical(name)?, data)
    }
    fn server_time(&self) -> Option<i64> {
        self.cloud.server_time()
    }
}
