//! Windows presentation adapter. Encryption, schema, validation and backups stay in the shared core.
use crate::domain::*;
use parking_lot::Mutex;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{de::DeserializeOwned, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
};
use termpilot_core::vault::{model::backup_dates, Vault};
type Result<T> = std::result::Result<T, String>;
pub struct VaultStore {
    pub directory: PathBuf,
    inner: Mutex<Vault>,
    files: Mutex<()>,
}
pub fn portable_directory(executable: &Path) -> Result<PathBuf> {
    let dir = executable
        .parent()
        .ok_or("Executable directory is missing")?;
    let root = if dir
        .file_name()
        .is_some_and(|s| s.eq_ignore_ascii_case("app"))
        && dir
            .parent()
            .is_some_and(|p| p.join("TermPilot.exe").is_file())
    {
        dir.parent().unwrap()
    } else {
        dir
    };
    Ok(root.join("AppData"))
}
pub fn default_data_directory() -> Result<PathBuf> {
    #[cfg(windows)]
    {
        portable_directory(&std::env::current_exe().map_err(err)?)
    }
    #[cfg(not(windows))]
    {
        Err("Windows UI development requires an isolated TERMPILOT_DATA_DIR".into())
    }
}
// Swift uses ID/CWD and its epoch, whereas React uses Id/Cwd and ISO dates.
// Keep the conversion here; never change records or the shared schema for a UI.
pub fn keys(mut value: Value, to_core: bool) -> Value {
    if let Some(obj) = value.as_object_mut() {
        let old = std::mem::take(obj);
        for (key, v) in old {
            let mapped = match (to_core, key.as_str()) {
                (true, "credentialId") => "credentialID",
                (false, "credentialID") => "credentialId",
                (true, "proxyProfileId") => "proxyProfileID",
                (false, "proxyProfileID") => "proxyProfileId",
                (true, "parentGroupId") => "parentGroupID",
                (false, "parentGroupID") => "parentGroupId",
                (true, "groupId") => "groupID",
                (false, "groupID") => "groupId",
                (true, "hostId") => "hostID",
                (false, "hostID") => "hostId",
                (true, "iconId") => "iconID",
                (false, "iconID") => "iconId",
                (true, "sftpFollowsTerminalCwd") => "sftpFollowsTerminalCWD",
                (false, "sftpFollowsTerminalCWD") => "sftpFollowsTerminalCwd",
                _ => &key,
            };
            obj.insert(mapped.into(), keys(v, to_core));
        }
    } else if let Some(array) = value.as_array_mut() {
        for v in array {
            *v = keys(v.take(), to_core);
        }
    }
    backup_dates(&mut value, !to_core);
    value
}
fn decode<T: DeserializeOwned>(mut value: Value, collection: &str) -> Result<T> {
    value = keys(value, false);
    if collection == "hosts" {
        if let Some(o) = value.as_object_mut() {
            if let Some(k) = o.remove("privateKey") {
                o.insert("identityKey".into(), k);
            }
        }
    }
    serde_json::from_value(value).map_err(err)
}

fn validate_ssh_identity(host: &Value) -> Result<()> {
    if host["connectionKind"].as_str().unwrap_or("ssh") != "ssh"
        || host["authentication"] != "identityFile"
        || host["privateKey"].as_str().is_some_and(|key| !key.trim().is_empty())
    {
        return Ok(());
    }
    let path = host["identityFile"].as_str().filter(|path| !path.trim().is_empty());
    let Some(path) = path else {
        return Err("此设备缺少 SSH 私钥。请选择包含私钥的凭证，或在“设置 → 凭证”中导入私钥。若通过云同步添加，请确认来源设备和当前设备均已开启“密码、私钥和凭证秘密”同步，并完成同步。".into());
    };
    if !Path::new(path).is_file() {
        return Err(format!("SSH 私钥文件不存在或无法访问：{path}。请在此设备重新选择文件，或改用已保存的私钥凭证。"));
    }
    Ok(())
}
impl VaultStore {
    pub fn batch_storage(&self, request: &Value) -> Result<Value> {
        self.inner.lock().batch_storage(request).map_err(err)
    }

    pub fn open_portable(directory: PathBuf) -> Result<Self> {
        #[cfg(windows)]
        if let Some(legacy) = std::env::var_os("LOCALAPPDATA")
            .map(PathBuf::from)
            .map(|p| p.join("TermPilot"))
        {
            if directory != legacy {
                termpilot_core::dispatch(&json!({"apiVersion":1,"method":"vault.prepareDirectory","directory":directory,"legacyDirectory":legacy})).map_err(err)?;
            }
        }
        Self::open(directory)
    }
    pub fn open(directory: PathBuf) -> Result<Self> {
        let inner = Mutex::new(Vault::open(&directory, None).map_err(err)?);
        termpilot_core::sync::dispatch(&json!({"method":"sync.recover","directory":directory}),None).map_err(err)?;
        Ok(Self {
            directory,
            inner,
            files: Mutex::new(()),
        })
    }
    pub fn webview_data_directory(&self) -> PathBuf {
        self.directory.join("WebView2")
    }
    pub fn known_hosts_path(&self) -> PathBuf {
        self.directory.join("known_hosts")
    }
    pub fn list<T: DeserializeOwned>(&self, c: &str) -> Result<Vec<T>> {
        self.inner
            .lock()
            .list(c)
            .map_err(err)?
            .into_iter()
            .map(|v| decode(v, c))
            .collect()
    }
    fn save<T: Serialize + DeserializeOwned>(&self, c: &str, item: T) -> Result<T> {
        let mut value = keys(serde_json::to_value(item).map_err(err)?, true);
        let vault = self.inner.lock();
        if let Some(mut existing) = vault.get(c, &value["id"]).map_err(err)? {
            existing
                .as_object_mut()
                .ok_or("Invalid record")?
                .extend(value.as_object().ok_or("Invalid record")?.clone());
            value = existing;
        }
        let screen = if c == "hosts" {
            value
                .get("screenSharingProfile")
                .filter(|v| v.is_object())
                .cloned()
                .map(|mut p| {
                    p["hostID"] = value["id"].clone();
                    p
                })
        } else {
            None
        };
        let mut saved = vault.save(c, value, screen).map_err(err)?;
        if c == "hosts" {
            saved["screenSharingProfile"] = vault
                .get("screenSharing", &saved["id"])
                .map_err(err)?
                .unwrap_or(Value::Null);
        }
        decode(saved, c)
    }
    fn delete(&self, c: &str, id: &str) -> Result<()> {
        self.inner.lock().delete(c, &json!(id)).map_err(err)
    }
    pub fn bootstrap(&self, platform: String) -> Result<BootstrapSnapshot> {
        let mut hosts: Vec<Host> = self.list("hosts")?;
        let screens = self.inner.lock().list("screenSharing").map_err(err)?;
        for host in &mut hosts {
            host.screen_sharing_profile = screens
                .iter()
                .find(|v| {
                    v["hostID"]
                        .as_str()
                        .is_some_and(|id| id.eq_ignore_ascii_case(&host.id))
                })
                .cloned()
                .map(|v| keys(v, false));
        }
        let mut prefs: Value = if self.directory.join("windows-preferences.json").is_file() {
            self.read_file("windows-preferences.json")?
        } else {
            self.read_file("preferences.json")?
        };
        if !prefs.is_object() {
            prefs = json!({});
        }
        for (old, new) in [
            ("fontFamily", "terminalFontName"),
            ("fontSize", "terminalFontSize"),
            ("openSystemOnConnect", "autoOpenSystemOverview"),
            ("showHiddenFiles", "sftpShowsHiddenFiles"),
            ("fileConcurrency", "sftpFileTransferConcurrency"),
            ("chunkConcurrency", "sftpChunkConcurrency"),
            ("chunkSize", "sftpChunkSizeBytes"),
            ("monitorInterval", "overviewRefreshInterval"),
        ] {
            if prefs[new].is_null() && !prefs[old].is_null() {
                prefs[new] = prefs[old].clone();
            }
        }
        if let Some(n) = prefs["sftpChunkSizeBytes"]
            .as_str()
            .and_then(|s| s.parse::<u64>().ok())
        {
            prefs["sftpChunkSizeBytes"] = json!(n);
        }
        if let Some(theme) = prefs["theme"].as_str() {
            prefs["theme"] = json!(match theme {
                "Light" => "light",
                "Dark" => "dark",
                "Default" => "system",
                v => v,
            });
        }
        let mut initial=serde_json::Map::new();
        for (source,target) in [("theme","theme"),("language","language"),("fontSize","terminalFontSize"),("fontFamily","terminalFontName"),("fps","remoteDesktopFrameRate"),("videoCodec","remoteDesktopVideoCodec")]{if let Some(value)=prefs.get(target).filter(|v|!v.is_null()){initial.insert(source.into(),value.clone());}}
        let sync_preferences=termpilot_core::sync::dispatch(&json!({"method":"sync.preferences","directory":self.directory,"initial":true,"values":initial}),None).map_err(err)?;
        for (source,target) in [("theme","theme"),("language","language"),("fontSize","terminalFontSize"),("fontFamily","terminalFontName"),("fps","remoteDesktopFrameRate"),("videoCodec","remoteDesktopVideoCodec")] {
            if let Some(value)=sync_preferences["preferences"].get(source) {prefs[target]=value.clone();}
        }
        let mut preferences: AppPreferences = serde_json::from_value(prefs).map_err(err)?;
        preferences.normalize();
        Ok(BootstrapSnapshot {
            platform,
            hosts,
            groups: self.list("groups")?,
            credentials: self.list("credentials")?,
            proxies: self.list("proxies")?,
            forwards: self.list("forwards")?,
            scripts: self.list("scripts")?,
            notes: self.list("notes")?,
            history: self.list("history")?,
            snippets: self.snippets()?,
            command_history: vec![],
            known_hosts: self.known_hosts()?,
            workspace: self.workspace()?,
            preferences,
        })
    }
    pub fn save_host(&self, v: Host) -> Result<Host> {
        self.save("hosts", v)
    }
    pub fn save_hosts(&self, v: Vec<Host>) -> Result<Vec<Host>> {
        let items = v
            .into_iter()
            .map(|v| keys(serde_json::to_value(v).unwrap(), true))
            .collect();
        self.inner
            .lock()
            .save_batch("hosts", items)
            .map_err(err)?
            .into_iter()
            .map(|v| decode(v, "hosts"))
            .collect()
    }
    pub fn delete_host(&self, id: &str) -> Result<()> {
        self.delete("hosts", id)
    }
    pub fn save_group(&self, v: HostGroup) -> Result<HostGroup> {
        self.save("groups", v)
    }
    pub fn delete_group(&self, id: &str) -> Result<()> {
        self.delete("groups", id)
    }
    pub fn save_credential(&self, v: Credential) -> Result<Credential> {
        self.save("credentials", v)
    }
    pub fn delete_credential(&self, id: &str) -> Result<()> {
        self.delete("credentials", id)
    }
    pub fn save_proxy(&self, v: ProxyProfile) -> Result<ProxyProfile> {
        self.save("proxies", v)
    }
    pub fn delete_proxy(&self, id: &str) -> Result<()> {
        self.delete("proxies", id)
    }
    pub fn save_forward(&self, v: PortForwardRule) -> Result<PortForwardRule> {
        self.save("forwards", v)
    }
    pub fn save_script(&self, v: AutomationScript) -> Result<AutomationScript> {
        self.save("scripts", v)
    }
    pub fn save_note(&self, v: HostNote) -> Result<HostNote> {
        self.save("notes", v)
    }
    fn ui_database(&self) -> Result<Connection> {
        let db = Connection::open(self.directory.join("vault.sqlite")).map_err(err)?;
        db.busy_timeout(std::time::Duration::from_secs(5))
            .map_err(err)?;
        Ok(db)
    }
    fn snippets(&self) -> Result<Vec<Snippet>> {
        let db = self.ui_database()?;
        let mut stmt = db
            .prepare("SELECT payload FROM snippets ORDER BY updated_at DESC")
            .map_err(err)?;
        let rows = stmt
            .query_map([], |r| r.get::<_, Vec<u8>>(0))
            .map_err(err)?;
        rows.map(|r| {
            decode(
                serde_json::from_slice(&r.map_err(err)?).map_err(err)?,
                "snippets",
            )
        })
        .collect()
    }
    pub fn save_snippet(&self, mut v: Snippet) -> Result<Snippet> {
        if v.title.trim().is_empty() {
            return Err("A name is required".into());
        }
        v.updated_at = now();
        let payload = keys(serde_json::to_value(&v).map_err(err)?, true);
        self.ui_database()?.execute("INSERT INTO snippets(id,payload,updated_at) VALUES(?1,?2,?3) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,updated_at=excluded.updated_at",params![v.id,serde_json::to_vec(&payload).map_err(err)?,v.updated_at]).map_err(err)?;
        Ok(v)
    }
    pub fn delete_entity(&self, kind: &str, id: &str) -> Result<()> {
        match kind {
            "forward" => self.delete("forwards", id),
            "script" => self.delete("scripts", id),
            "note" => self.delete("notes", id),
            "snippet" => self
                .ui_database()?
                .execute("DELETE FROM snippets WHERE id=?", [id])
                .map(|_| ())
                .map_err(err),
            _ => Err("Unknown collection".into()),
        }
    }
    fn workspace(&self) -> Result<WorkspaceSnapshot> {
        let payload: Option<Vec<u8>> = self
            .ui_database()?
            .query_row("SELECT payload FROM workspace_state WHERE id=1", [], |r| {
                r.get(0)
            })
            .optional()
            .map_err(err)?;
        payload
            .map(|v| decode(serde_json::from_slice(&v).map_err(err)?, "workspace"))
            .transpose()
            .map(|v| v.unwrap_or_default())
    }
    pub fn append_history(&self, v: ConnectionHistoryEntry) -> Result<()> {
        self.save("history", v).map(|_: ConnectionHistoryEntry| ())
    }
    // Command history remains session-local, matching the macOS privacy policy.
    pub fn append_command_history(&self, _v: CommandHistoryEntry) -> Result<()> {
        Ok(())
    }
    pub fn save_workspace(&self, v: WorkspaceSnapshot) -> Result<()> {
        let payload = keys(serde_json::to_value(&v).map_err(err)?, true);
        self.ui_database()?.execute("INSERT INTO workspace_state(id,payload,saved_at) VALUES(1,?1,?2) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload,saved_at=excluded.saved_at",params![serde_json::to_vec(&payload).map_err(err)?,now()]).map(|_|()).map_err(err)
    }
    pub fn erase_workspace(&self) -> Result<()> {
        self.save_workspace(WorkspaceSnapshot::default())
    }
    pub fn save_preferences(&self, mut v: AppPreferences) -> Result<()> {
        v.normalize();
        termpilot_core::sync::dispatch(&json!({"method":"sync.preferences","directory":self.directory,
            "values":{"theme":v.theme,"language":v.language,"fontSize":v.terminal_font_size,"fontFamily":v.terminal_font_name,"fps":v.remote_desktop_frame_rate}}),None).map_err(err)?;
        let _lock = self.files.lock();
        let mut merged: Value = self.read_file("windows-preferences.json")?;
        if !merged.is_object() {
            merged = json!({});
        }
        merged.as_object_mut().unwrap().extend(
            serde_json::to_value(v)
                .map_err(err)?
                .as_object()
                .unwrap()
                .clone(),
        );
        self.write_file("windows-preferences.json", &merged)
    }
    pub fn auto_accept_ssh_host_keys(&self) -> Result<bool> {
        let file = if self.directory.join("windows-preferences.json").is_file() { "windows-preferences.json" } else { "preferences.json" };
        let prefs: Value = self.read_file(file)?;
        Ok(prefs["autoAcceptSshHostKeys"].as_bool().unwrap_or(false))
    }
    fn read_file<T: DeserializeOwned + Default>(&self, name: &str) -> Result<T> {
        match fs::read(self.directory.join(name)) {
            Ok(bytes) => serde_json::from_slice(&bytes).map_err(err),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(T::default()),
            Err(e) => Err(err(e)),
        }
    }
    fn write_file<T: Serialize>(&self, name: &str, v: &T) -> Result<()> {
        let path = self.directory.join(name);
        let tmp = path.with_extension("tmp");
        fs::write(&tmp, serde_json::to_vec_pretty(v).map_err(err)?).map_err(err)?;
        fs::rename(tmp, path).map_err(err)
    }
    fn known_hosts(&self) -> Result<Vec<KnownHostRecord>> {
        Ok(fs::read_to_string(self.known_hosts_path())
            .unwrap_or_default()
            .lines()
            .enumerate()
            .filter_map(|(i, line)| {
                let mut f = line.split_whitespace();
                let hosts = f.next()?;
                if hosts.starts_with('#') {
                    return None;
                }
                Some(KnownHostRecord {
                    id: format!("{i}:{line}"),
                    hosts: hosts.into(),
                    algorithm: f.next()?.into(),
                    key: f.next()?.into(),
                    raw_line: line.into(),
                })
            })
            .collect())
    }
    pub fn delete_known_host(&self, id: &str) -> Result<()> {
        self.delete_known_hosts(&HashSet::from([id.into()]))
    }
    pub fn delete_known_hosts(&self, ids: &HashSet<String>) -> Result<()> {
        let _lock = self.files.lock();
        let text = fs::read_to_string(self.known_hosts_path())
            .unwrap_or_default()
            .lines()
            .enumerate()
            .filter(|(i, l)| !ids.contains(&format!("{i}:{l}")))
            .map(|(_, l)| format!("{l}\n"))
            .collect::<String>();
        fs::write(self.known_hosts_path(), text).map_err(err)
    }
    pub fn backup(&self, method: &str, path: String, password: String) -> Result<Value> {
        termpilot_core::dispatch(&json!({"apiVersion":1,"method":method,"directory":self.directory,"path":path,"password":password})).map_err(err)
    }
    pub fn resolve(&self, host: &Host) -> Result<Value> {
        let mut v = keys(serde_json::to_value(host).map_err(err)?, true);
        let vault = self.inner.lock();
        termpilot_core::dispatch(&json!({"apiVersion":termpilot_core::API_VERSION,"method":"sync.checkConnection","directory":self.directory,"host":v})).map_err(|e| e.message.to_string())?;
        let result=termpilot_core::dispatch(&json!({"apiVersion":1,"method":"resolveConnection","host":v,"credentials":vault.list("credentials").map_err(err)?,"proxyProfiles":vault.list("proxies").map_err(err)?})).map_err(|e| e.message.to_string())?;
        v = result["host"].clone();
        v["privateKey"] = v["identityKey"].clone();
        v["proxy"] = v["proxyConfiguration"].clone();
        v["knownHostsFile"] = json!(self.known_hosts_path());
        validate_ssh_identity(&v)?;
        Ok(v)
    }
    pub fn screen_host(&self, id: &str) -> Result<Option<Host>> {
        let vault = self.inner.lock();
        let Some(mut value) = vault.get("hosts", &json!(id)).map_err(err)? else { return Ok(None) };
        value["screenSharingProfile"] = vault.get("screenSharing", &json!(id)).map_err(err)?.unwrap_or(Value::Null);
        decode(value, "hosts").map(Some)
    }
}
fn err(e: impl std::fmt::Debug) -> String {
    format!("{e:?}")
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn presentation_keys_round_trip() {
        let a = json!({"credentialId":"a","groupId":"b","createdAt":"2026-10-05T00:00:00Z","proxyConfiguration":{"credentialId":"c"}});
        assert_eq!(keys(keys(a.clone(), true), false), a);
    }
    #[test]
    fn vault_shared_schema_round_trip() {
        let p = std::env::temp_dir().join(format!("TermPilot-test-{}", uuid::Uuid::new_v4()));
        let store = VaultStore::open(p.clone()).unwrap();
        let mut h:Host=serde_json::from_value(json!({"label":"fixture","hostname":"127.0.0.1","username":"user","authentication":"password","password":"test-secret","connectionKind":"ssh"})).unwrap();
        h = store.save_host(h).unwrap();
        let credential: Credential = serde_json::from_value(json!({"label":"Default elevation","username":"ops","kind":"password","password":"test-secret","elevationMethod":"su"})).unwrap();
        let mut credential = store.save_credential(credential).unwrap();
        let snapshot = store.bootstrap("windows".into()).unwrap();
        assert_eq!(serde_json::to_value(&snapshot.credentials[0]).unwrap()["elevationMethod"], "su");
        credential.elevation_method = None;
        store.save_credential(credential).unwrap();
        let disabled = store.bootstrap("windows".into()).unwrap();
        assert!(serde_json::to_value(&disabled.credentials[0]).unwrap()["elevationMethod"].is_null());
        assert_eq!(snapshot.hosts[0].id, h.id);
        assert_eq!(snapshot.hosts[0].password.as_deref(), Some("test-secret"));
        let bytes = fs::read(p.join("vault.sqlite")).unwrap();
        assert!(!bytes.windows(11).any(|s| s == b"test-secret"));
        drop(store);
        fs::remove_dir_all(p).unwrap();
    }

    #[test]
    fn synchronized_credential_without_secret_cannot_launch_empty_key_path() {
        let p = std::env::temp_dir().join(format!("TermPilot-missing-key-{}", uuid::Uuid::new_v4()));
        let store = VaultStore::open(p.clone()).unwrap();
        // A new device can receive the public credential description before secrets.
        let credential: Credential = serde_json::from_value(json!({"label":"Synced key","kind":"identityKey","username":"user","privateKey":"fixture-key"})).unwrap();
        let credential = store.save_credential(credential).unwrap();
        let db = store.ui_database().unwrap();
        termpilot_core::sync::journal::register(&db, &fs::read(p.join("credential.key")).unwrap()).unwrap();
        db.execute("UPDATE ssh_credentials SET private_key=NULL WHERE id=?1", [&credential.id]).unwrap();
        drop(db);
        let host: Host = serde_json::from_value(json!({"label":"host","hostname":"example.invalid","username":"user","credentialId":credential.id})).unwrap();
        let error = store.resolve(&host).unwrap_err();
        assert!(error.contains("缺少 SSH 私钥"));
        assert!(!error.contains("os error"));
        drop(store);
        fs::remove_dir_all(p).unwrap();
    }

    #[test]
    fn private_key_path_validation_preserves_other_authentication_modes() {
        assert!(validate_ssh_identity(&json!({"authentication":"password"})).is_ok());
        assert!(validate_ssh_identity(&json!({"authentication":"agent"})).is_ok());
        assert!(validate_ssh_identity(&json!({"connectionKind":"rdp","authentication":"identityFile"})).is_ok());
        assert!(validate_ssh_identity(&json!({"authentication":"identityFile","privateKey":"inline-key","identityFile":"missing"})).is_ok());
        let p = std::env::temp_dir().join(format!("TermPilot-key-path-{}", uuid::Uuid::new_v4()));
        let host = json!({"authentication":"identityFile","identityFile":p});
        assert!(validate_ssh_identity(&host).unwrap_err().contains("私钥文件不存在"));
        fs::write(&p, "fixture").unwrap();
        assert!(validate_ssh_identity(&host).is_ok());
        fs::remove_file(p).unwrap();
    }
}

#[cfg(test)]
mod compatibility_tests {
    use super::*;
    struct Temp(PathBuf);
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn credentials_proxy_profiles_and_vnc_survive_the_same_vault() {
        let temp =
            Temp(std::env::temp_dir().join(format!("TermPilot-adapter-{}", uuid::Uuid::new_v4())));
        let store = VaultStore::open(temp.0.clone()).unwrap();
        let credential:Credential=serde_json::from_value(json!({"label":"saved","username":"user","kind":"identityKey","privateKey":"test-key","savesPassphrase":true,"passphrase":"test-pass"})).unwrap();
        let credential = store.save_credential(credential).unwrap();
        let mut host:Host=serde_json::from_value(json!({"label":"host","hostname":"example.invalid","username":"user","credentialId":credential.id})).unwrap();
        let resolved = store.resolve(&host).unwrap();
        assert_eq!(resolved["privateKey"], "test-key");
        assert_eq!(resolved["passphrase"], "test-pass");
        host.credential_id = None;
        host.connection_kind = "screenSharing".into();
        host.screen_sharing_profile =
            Some(json!({"port":5901,"username":"","password":"vnc-secret","mode":"standardVNC"}));
        let saved = store.save_host(host).unwrap();
        assert_eq!(saved.screen_sharing_profile.as_ref().unwrap()["port"], 5901);
        let copy = store.bootstrap("windows".into()).unwrap();
        assert_eq!(copy.hosts[0].connection_kind, "screenSharing");
        assert_eq!(
            copy.hosts[0].screen_sharing_profile.as_ref().unwrap()["password"],
            "vnc-secret"
        );
    }
    #[test]
    fn standalone_ssh_follows_the_current_windows_key_policy_and_legacy_preferences() {
        let temp = Temp(std::env::temp_dir().join(format!("TermPilot-key-policy-{}", uuid::Uuid::new_v4())));
        let store = VaultStore::open(temp.0.clone()).unwrap();
        assert!(!store.auto_accept_ssh_host_keys().unwrap());
        fs::write(temp.0.join("preferences.json"), br#"{"autoAcceptSshHostKeys":true}"#).unwrap();
        assert!(store.auto_accept_ssh_host_keys().unwrap());
        fs::write(temp.0.join("windows-preferences.json"), br#"{"autoAcceptSshHostKeys":false}"#).unwrap();
        assert!(!store.auto_accept_ssh_host_keys().unwrap());
    }

    #[test]
    fn existing_windows_preferences_and_workspace_round_trip() {
        let temp =
            Temp(std::env::temp_dir().join(format!("TermPilot-prefs-{}", uuid::Uuid::new_v4())));
        let store = VaultStore::open(temp.0.clone()).unwrap();
        fs::write(
            temp.0.join("windows-preferences.json"),
            br#"{"fontFamily":"Consolas","fontSize":16,"theme":"Dark","customExistingField":true}"#,
        )
        .unwrap();
        let v = store.bootstrap("windows".into()).unwrap();
        assert_eq!(v.preferences.terminal_font_name, "Consolas");
        assert_eq!(v.preferences.terminal_font_size, 16.0);
        assert_eq!(v.preferences.theme, "dark");
        store.save_preferences(v.preferences).unwrap();
        let saved: Value =
            serde_json::from_slice(&fs::read(temp.0.join("windows-preferences.json")).unwrap())
                .unwrap();
        assert_eq!(saved["customExistingField"], true);
        let workspace = WorkspaceSnapshot::default();
        store.save_workspace(workspace).unwrap();
        assert!(store.workspace().unwrap().sessions.is_empty());
        assert!(!temp.0.join("workspace.json").exists());
    }
}
