//! Authenticated, renewable leases. Version 3 fences publication through an
//! authenticated catalog; delayed immutable uploads cannot publish after takeover.
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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub expires_at: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub timeout_minutes: Option<u32>,
}
#[derive(Clone, Serialize, Deserialize)]
pub(super) struct Head {
    pub version: u32,
    pub library: String,
    pub generation: String,
    pub sequence: u64,
    pub lock: Option<Lock>,
    pub authentication: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub catalog: Option<Vec<String>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub maintenance: Option<super::maintenance::History>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub bundles: Option<super::bundle::History>,
}
impl Head {
    pub fn new(config: &Config) -> Self {
        Self {
            version: 4,
            library: config.library.clone(),
            generation: config.generation.clone(),
            sequence: config.generation_sequence,
            lock: None,
            authentication: String::new(),
            catalog: Some(Vec::new()),
            maintenance: None,
            bundles: None,
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
        mac.update(format!("TermPilot:sync:control:{}:", self.version).as_bytes());
        mac.update(&value.message()?);
        value.authentication = hex::encode(mac.finalize().into_bytes());
        serde_json::to_vec(&value).map_err(|_| err("syncControl", "无法编码同步控制信息。"))
    }
    pub fn verify(&self, config: &Config) -> Result<()> {
        if !matches!(self.version, 2 | 3 | 4 | 5)
            || self.library != config.library
            || (!self.generation.is_empty() && uuid::Uuid::parse_str(&self.generation).is_err())
        {
            return Err(err(
                "syncControl",
                "云端同步控制信息无效，请更新应用或检查云端。",
            ));
        }
        if self.version >= 3
            && (self.catalog.is_none()
                || self.lock.as_ref().is_some_and(|lock| {
                    lock.expires_at.is_none()
                        || !lock
                            .timeout_minutes
                            .is_some_and(|n| (1..=1440).contains(&n))
                }))
        {
            return Err(err("syncControl", "云端租约信息无效，已停止同步。"));
        }
        if let Some(history) = &self.maintenance {
            history.validate(self)?;
        }
        if self.version == 5 && self.bundles.is_none() {
            return Err(err("syncControl", "整包同步缺少版本目录。"));
        }
        if let Some(history) = &self.bundles {
            history.validate(&self.library)?;
        }
        let key = config
            .scope_keys
            .get("configuration")
            .ok_or_else(|| err("syncKey", "缺少同步密钥。"))?;
        let mut mac =
            Hmac::<Sha256>::new_from_slice(key).map_err(|_| err("syncKey", "同步密钥无效。"))?;
        mac.update(format!("TermPilot:sync:control:{}:", self.version).as_bytes());
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
pub(super) use super::lease::Lease;
pub(super) fn acquire(store: &Store<'_>, cloud: &mut dyn Objects, kind: &str) -> Result<Lease> {
    let config = store.config()?;
    super::lease::timeout(
        &json!({"lockTimeoutMinutes":config.lock_timeout_minutes}),
        60,
    )?;
    let previous = read(cloud, &config.library)?;
    let mut head = previous
        .as_ref()
        .map(|(h, _)| h.clone())
        .unwrap_or_else(|| Head::new(&config));
    if previous.is_none()
        && (!config.generation.is_empty()
            || config.generation_sequence > 0
            || store
                .get::<super::bundle::History>("bundleHistory")?
                .is_some())
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
    let pending = store.get::<String>("cloudLockPending")?;
    let now = super::lease::cloud_time(cloud)?;
    if let Some(lock) = &head.lock {
        let owned = lock.device == config.device
            && [saved.as_deref(), pending.as_deref()].contains(&Some(lock.token.as_str()));
        let expired = head.version >= 3 && lock.expires_at.is_some_and(|expiry| now >= expiry);
        if !owned && !expired {
            store.put(
                "remoteSyncBusy",
                &json!({"device":lock.device,"kind":lock.kind,
                "expiresAt":lock.expires_at,"legacy":head.version == 2}),
            )?;
            return Err(err(
                "syncCloudBusy",
                if head.version == 2 {
                    "旧版设备留下了无到期时间的同步锁。原设备已不可用时，请停止其他设备同步，再使用“恢复旧锁并同步”。"
                } else {
                    "其它设备正在同步。若该设备中断，锁超时后重试即可自动接管。"
                },
            ));
        }
    }
    // Prepare the legacy catalog before atomically fencing old clients. Never
    // interpret an old lock's missing timestamp as permission to steal it.
    if head.version == 2 || previous.is_none() {
        cloud.check_conditionals(&config.library)?;
        head.catalog = Some(super::lease::catalog_existing(
            cloud,
            &head.library,
            &head.generation,
        )?);
    }
    cloud.get(&name(&config.library))?;
    let now = super::lease::cloud_time(cloud)?;
    let token = uuid::Uuid::new_v4().to_string();
    store.put("cloudLockPending", &token)?;
    head.version = head.version.max(4);
    head.lock = Some(Lock {
        device: config.device.clone(),
        token: token.clone(),
        kind: kind.into(),
        expires_at: Some(now + i64::from(config.lock_timeout_minutes) * 60),
        timeout_minutes: Some(config.lock_timeout_minutes),
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
    store.put("cloudLockToken", &token)?;
    store.remove("cloudLockPending")?;
    store.put("allowControlCreate", &false)?;
    store.put("remoteSyncBusy", &Value::Null)?;
    Lease::start(config, head, bytes, cloud)
}
pub(super) fn release(store: &Store<'_>, cloud: &mut dyn Objects, lease: &Lease) -> Result<()> {
    lease.release(cloud)?;
    store.remove("cloudLockToken")?;
    store.remove("cloudLockPending")?;
    Ok(())
}
/// The exchange engine keeps content-addressed logical names. A generation has
/// an isolated physical namespace so staging never overwrites a working library.
pub(super) struct Namespace<'a> {
    pub cloud: &'a mut dyn Objects,
    pub library: String,
    pub generation: String,
    pub guard: Option<&'a Lease>,
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
        if let Some(lease) = self.guard {
            lease.check(self.cloud)?;
        }
        Ok(())
    }
}
impl Objects for Namespace<'_> {
    fn list(&mut self) -> Result<Vec<String>> {
        self.check()?;
        if let Some(lease) = self.guard {
            if lease.generation()? == self.generation {
                return lease.names(self.cloud);
            }
        } else if let Some((head, _)) = read(self.cloud, &self.library)? {
            if head.version >= 3 && head.generation == self.generation {
                return super::lease::catalog_names(self.cloud, &head);
            }
        }
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
        self.check()?;
        let result = self.cloud.get(&self.physical(name)?)?;
        self.check()?;
        Ok(result)
    }
    fn put(&mut self, name: &str, data: &[u8]) -> Result<()> {
        self.check()?;
        self.cloud.put(&self.physical(name)?, data)?;
        self.check()?;
        if let Some(lease) = self.guard {
            if lease.generation()? == self.generation {
                lease.publish(self.cloud, name)?;
            }
        }
        Ok(())
    }
    fn server_time(&self) -> Option<i64> {
        self.cloud.server_time()
    }
}
