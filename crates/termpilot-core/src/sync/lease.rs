//! Renewable ownership and fenced publication for every native client.
//! A delayed object PUT is harmless: only catalog pages referenced by the
//! authenticated, conditionally updated head are visible to synchronization.
use super::{
    control::{self, Head},
    err,
    store::Config,
    transport::Objects,
    Result,
};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    sync::{mpsc, Arc, Mutex, MutexGuard},
    thread::JoinHandle,
    time::Duration,
};

pub(super) fn default_timeout() -> u32 {
    60
}
pub(super) fn timeout(request: &Value, previous: u32) -> Result<u32> {
    match request.get("lockTimeoutMinutes") {
        None => Ok(previous),
        Some(value) => value
            .as_u64()
            .filter(|n| (1..=1440).contains(n))
            .map(|n| n as u32)
            .ok_or_else(|| err("syncLeaseSettings", "锁超时时长须为 1–1440 分钟的整数。")),
    }
}
pub(super) fn cloud_time(cloud: &dyn Objects) -> Result<i64> {
    cloud.server_time().ok_or_else(|| {
        err(
            "syncLeaseClock",
            "云服务未提供可靠时间，无法安全续期或接管同步锁。",
        )
    })
}
fn lost() -> super::CoreError {
    err(
        "syncLeaseLost",
        "同步锁已过期、被接管或续期失败。本机修改已保留，请重新同步。",
    )
}
fn prefix(library: &str, generation: &str) -> String {
    if generation.is_empty() {
        format!("tp1-{library}-")
    } else {
        format!("tp1-{library}-g-{generation}-")
    }
}
fn valid_object(library: &str, name: &str) -> bool {
    name.strip_prefix(&format!("tp1-{library}-"))
        .is_some_and(|n| {
            ["chunk-", "batch-", "snapshot-", "receipt-"]
                .iter()
                .any(|p| n.starts_with(p))
        })
        && name.len() <= 220
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'.')
}
const PAGE_SIZE: usize = 1024;
const MAX_PAGES: usize = 256;
#[derive(Clone, Default)]
struct Catalog {
    pages: Vec<Vec<String>>,
    names: BTreeSet<String>,
}
fn load_catalog(cloud: &mut dyn Objects, head: &Head) -> Result<Catalog> {
    let refs = head
        .catalog
        .as_ref()
        .ok_or_else(|| err("syncControl", "云端缺少已提交的同步目录。"))?;
    if refs.len() > MAX_PAGES {
        return Err(err("syncSize", "同步目录超过支持范围。"));
    }
    let mut result = Catalog::default();
    for name in refs {
        if !name.starts_with(&format!(
            "{}catalog-",
            prefix(&head.library, &head.generation)
        )) {
            return Err(err("syncControl", "同步目录引用无效。"));
        }
        let bytes = cloud
            .get(name)?
            .ok_or_else(|| err("syncRollback", "已提交的同步目录缺失，请检查云端。"))?;
        if !name.ends_with(&format!("-{}.tps", hex::encode(Sha256::digest(&bytes)))) {
            return Err(err("syncIntegrity", "同步目录校验失败。"));
        }
        let page: Vec<String> =
            serde_json::from_slice(&bytes).map_err(|_| err("syncControl", "同步目录格式无效。"))?;
        if page.is_empty()
            || page.len() > PAGE_SIZE
            || page
                .iter()
                .any(|n| !valid_object(&head.library, n) || !result.names.insert(n.clone()))
        {
            return Err(err("syncControl", "同步目录包含无效或重复对象。"));
        }
        result.pages.push(page);
    }
    Ok(result)
}
fn save_page(
    cloud: &mut dyn Objects,
    library: &str,
    generation: &str,
    page: &[String],
) -> Result<String> {
    let bytes = serde_json::to_vec(page).map_err(|_| err("syncControl", "无法编码同步目录。"))?;
    let name = format!(
        "{}catalog-{}.tps",
        prefix(library, generation),
        hex::encode(Sha256::digest(&bytes))
    );
    cloud.put(&name, &bytes)?;
    if cloud.get(&name)?.as_deref() != Some(&bytes) {
        return Err(err("syncVerify", "同步目录回读校验失败。"));
    }
    Ok(name)
}
pub(super) fn catalog_build(
    cloud: &mut dyn Objects,
    library: &str,
    generation: &str,
    names: Vec<String>,
) -> Result<Vec<String>> {
    let names: Vec<_> = names
        .into_iter()
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect();
    if names.len() > PAGE_SIZE * MAX_PAGES || names.iter().any(|n| !valid_object(library, n)) {
        return Err(err("syncSize", "同步目录包含无效对象或超过支持范围。"));
    }
    names
        .chunks(PAGE_SIZE)
        .map(|page| save_page(cloud, library, generation, page))
        .collect()
}
pub(super) fn catalog_existing(
    cloud: &mut dyn Objects,
    library: &str,
    generation: &str,
) -> Result<Vec<String>> {
    let prefix = prefix(library, generation);
    let names = cloud
        .list()?
        .into_iter()
        .filter_map(|name| {
            name.strip_prefix(&prefix)
                .map(|n| format!("tp1-{library}-{n}"))
        })
        .filter(|n| valid_object(library, n))
        .collect();
    catalog_build(cloud, library, generation, names)
}
pub(super) fn catalog_names(cloud: &mut dyn Objects, head: &Head) -> Result<Vec<String>> {
    Ok(load_catalog(cloud, head)?.names.into_iter().collect())
}
struct State {
    config: Config,
    head: Head,
    bytes: Vec<u8>,
    active: bool,
    catalog: Option<Catalog>,
}
impl State {
    fn check(&mut self, cloud: &mut dyn Objects) -> Result<i64> {
        if !self.active {
            return Err(lost());
        }
        let result = (|| {
            if cloud.get(&control::name(&self.head.library))?.as_deref() != Some(&self.bytes) {
                return Err(lost());
            }
            let now = cloud_time(cloud)?;
            if self
                .head
                .lock
                .as_ref()
                .and_then(|l| l.expires_at)
                .is_none_or(|t| now >= t)
            {
                return Err(lost());
            }
            Ok(now)
        })();
        if result.is_err() {
            self.active = false;
        }
        result
    }
    fn exchange(&mut self, cloud: &mut dyn Objects, next: Head, config: &Config) -> Result<()> {
        self.check(cloud)?;
        let bytes = next.signed(config)?;
        let result =
            cloud.compare_exchange(&control::name(&next.library), Some(&self.bytes), &bytes);
        match result {
            Ok(true) => {
                self.head = next;
                self.bytes = bytes;
                Ok(())
            }
            Ok(false) => {
                self.active = false;
                Err(lost())
            }
            Err(e) => {
                self.active = false;
                Err(e)
            }
        }
    }
    fn renew(&mut self, cloud: &mut dyn Objects) -> Result<()> {
        let now = self.check(cloud)?;
        let mut next = self.head.clone();
        next.lock.as_mut().ok_or_else(lost)?.expires_at =
            Some(now + i64::from(self.config.lock_timeout_minutes) * 60);
        let config = self.config.clone();
        self.exchange(cloud, next, &config)
    }
}
pub(super) struct Lease {
    state: Arc<Mutex<State>>,
    stop: Option<mpsc::Sender<()>>,
    worker: Option<JoinHandle<()>>,
}
impl Lease {
    pub(super) fn start(
        config: Config,
        head: Head,
        bytes: Vec<u8>,
        cloud: &mut dyn Objects,
    ) -> Result<Self> {
        let interval = Duration::from_secs(
            (u64::from(config.lock_timeout_minutes) * 60 / 3)
                .min(60)
                .max(1),
        );
        Self::start_with_interval(config, head, bytes, cloud, interval)
    }
    pub(super) fn start_with_interval(
        config: Config,
        head: Head,
        bytes: Vec<u8>,
        cloud: &mut dyn Objects,
        interval: Duration,
    ) -> Result<Self> {
        let connection = cloud.lease_connection()?;
        let state = Arc::new(Mutex::new(State {
            config,
            head,
            bytes,
            active: true,
            catalog: None,
        }));
        let (stop, receiver) = mpsc::channel();
        let worker = connection.map(|mut cloud| {
            let state = state.clone();
            std::thread::spawn(move || {
                while receiver.recv_timeout(interval) == Err(mpsc::RecvTimeoutError::Timeout) {
                    let Ok(mut state) = state.lock() else { break };
                    if !state.active || state.renew(cloud.as_mut()).is_err() {
                        break;
                    }
                }
            })
        });
        Ok(Self {
            state,
            stop: Some(stop),
            worker,
        })
    }
    fn state(&self) -> Result<MutexGuard<'_, State>> {
        self.state.lock().map_err(|_| lost())
    }
    pub(super) fn check(&self, cloud: &mut dyn Objects) -> Result<()> {
        self.state()?.check(cloud).map(|_| ())
    }
    #[cfg(test)]
    pub(super) fn renew(&self, cloud: &mut dyn Objects) -> Result<()> {
        self.state()?.renew(cloud)
    }
    pub(super) fn generation(&self) -> Result<String> {
        Ok(self.state()?.head.generation.clone())
    }
    fn ensure_catalog(&self, cloud: &mut dyn Objects) -> Result<()> {
        let head = {
            let mut state = self.state()?;
            state.check(cloud)?;
            if state.catalog.is_some() {
                return Ok(());
            }
            state.head.clone()
        };
        // Catalog downloads may be large. Do not block the heartbeat mutex.
        let catalog = load_catalog(cloud, &head)?;
        let mut state = self.state()?;
        state.check(cloud)?;
        if state.head.catalog != head.catalog {
            return Err(lost());
        }
        state.catalog = Some(catalog);
        Ok(())
    }
    pub(super) fn names(&self, cloud: &mut dyn Objects) -> Result<Vec<String>> {
        self.ensure_catalog(cloud)?;
        Ok(self
            .state()?
            .catalog
            .as_ref()
            .unwrap()
            .names
            .iter()
            .cloned()
            .collect())
    }
    pub(super) fn publish(&self, cloud: &mut dyn Objects, name: &str) -> Result<()> {
        self.ensure_catalog(cloud)?;
        // Stage the immutable page outside the heartbeat mutex. Only the CAS
        // below publishes it, using the latest renewed head and owner token.
        let (head, mut page, append) = {
            let state = self.state()?;
            if !valid_object(&state.head.library, name) {
                return Err(err("syncObject", "同步对象不属于当前库。"));
            }
            let catalog = state.catalog.as_ref().unwrap();
            if catalog.names.contains(name) {
                return Ok(());
            }
            let append = catalog.pages.last().is_none_or(|p| p.len() == PAGE_SIZE);
            if append && catalog.pages.len() >= MAX_PAGES {
                return Err(err("syncSize", "同步目录超过支持范围。"));
            }
            let page = if append {
                Vec::new()
            } else {
                catalog.pages.last().unwrap().clone()
            };
            (state.head.clone(), page, append)
        };
        page.push(name.into());
        let reference = save_page(cloud, &head.library, &head.generation, &page)?;
        let mut state = self.state()?;
        if state.head.catalog != head.catalog {
            return Err(lost());
        }
        let mut next = state.head.clone();
        let refs = next.catalog.as_mut().ok_or_else(lost)?;
        if append {
            refs.push(reference);
        } else {
            *refs.last_mut().unwrap() = reference;
        }
        let config = state.config.clone();
        state.exchange(cloud, next, &config)?;
        let catalog = state.catalog.as_mut().unwrap();
        catalog.names.insert(name.into());
        if append {
            catalog.pages.push(page);
        } else {
            *catalog.pages.last_mut().unwrap() = page;
        }
        Ok(())
    }
    pub(super) fn release(&self, cloud: &mut dyn Objects) -> Result<()> {
        let mut state = self.state()?;
        let mut head = state.head.clone();
        head.lock = None;
        let config = state.config.clone();
        state.exchange(cloud, head, &config)?;
        state.active = false;
        Ok(())
    }
    pub(super) fn head(&self) -> Result<Head> {
        Ok(self.state()?.head.clone())
    }
    pub(super) fn active(&self) -> Result<bool> {
        Ok(self.state()?.active)
    }
    /// The lease token and latest heartbeat participate in the same conditional
    /// publication. Never replace a live bundle by an unconditional object PUT.
    pub(super) fn publish_bundles(
        &self,
        cloud: &mut dyn Objects,
        history: super::bundle::History,
    ) -> Result<()> {
        let mut state = self.state()?;
        history.validate(&state.head.library)?;
        let mut head = state.head.clone();
        head.version = 5;
        head.bundles = Some(history);
        if head.bundles.as_ref().is_some_and(|h| h.current.is_some()) {
            head.catalog = Some(Vec::new());
        }
        let config = state.config.clone();
        state.exchange(cloud, head, &config)
    }
    pub(super) fn cutover_bundles(
        &self,
        cloud: &mut dyn Objects,
        config: &Config,
        history: super::bundle::History,
    ) -> Result<()> {
        history.validate(&config.library)?;
        let mut state = self.state()?;
        let mut head = Head::new(config);
        head.version = 5;
        head.bundles = Some(history);
        head.maintenance = state.head.maintenance.clone();
        state.exchange(cloud, head, config)?;
        state.active = false;
        Ok(())
    }
    pub(super) fn update_history(
        &self,
        cloud: &mut dyn Objects,
        history: super::maintenance::History,
    ) -> Result<()> {
        let mut state = self.state()?;
        let mut head = state.head.clone();
        head.maintenance = Some(history);
        let config = state.config.clone();
        head.maintenance.as_ref().unwrap().validate(&head)?;
        state.exchange(cloud, head, &config)
    }
    pub(super) fn compact(
        &self,
        cloud: &mut dyn Objects,
        new: &Config,
        names: Vec<String>,
        history: super::maintenance::History,
    ) -> Result<()> {
        self.replace_generation(cloud, new, names, Some(history))
    }
    pub(super) fn cutover(
        &self,
        cloud: &mut dyn Objects,
        new: &Config,
        names: Vec<String>,
    ) -> Result<()> {
        let history = self.head()?.maintenance;
        self.replace_generation(cloud, new, names, history)
    }
    fn replace_generation(
        &self,
        cloud: &mut dyn Objects,
        new: &Config,
        names: Vec<String>,
        history: Option<super::maintenance::History>,
    ) -> Result<()> {
        self.check(cloud)?;
        let catalog = catalog_build(cloud, &new.library, &new.generation, names)?;
        let mut state = self.state()?;
        let mut head = Head::new(new);
        head.catalog = Some(catalog);
        head.maintenance = history;
        if let Some(history) = &head.maintenance {
            history.validate(&head)?;
        }
        state.exchange(cloud, head, new)?;
        state.active = false;
        Ok(())
    }
}
impl Drop for Lease {
    fn drop(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}
