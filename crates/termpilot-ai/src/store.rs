//! Separate encrypted AI records inside the existing TermPilot data directory.
//! The vault schema and credential key are never replaced or migrated here.
use anyhow::{ensure, Context, Result};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{de::DeserializeOwned, Serialize};
use std::{
    fs,
    io::Write,
    path::{Path, PathBuf},
};
use termpilot_core::vault::crypto;
use zeroize::Zeroizing;

pub struct Store {
    db: Connection,
    key: Zeroizing<Vec<u8>>,
    pub directory: PathBuf,
}
impl Store {
    pub fn vault(&self) -> Result<termpilot_core::vault::Vault> {
        termpilot_core::vault::Vault::open_with_key(&self.directory, &self.key)
            .map_err(|e| anyhow::anyhow!(e.message))
    }
    pub fn open(directory: &Path) -> Result<Self> {
        ensure!(
            directory.is_absolute(),
            "AI data directory must be absolute"
        );
        if !directory.exists() {
            #[cfg(unix)]
            {
                use std::os::unix::fs::DirBuilderExt;
                fs::DirBuilder::new()
                    .recursive(true)
                    .mode(0o700)
                    .create(directory)?;
            }
            #[cfg(not(unix))]
            fs::create_dir_all(directory)?;
        }
        let key_path = directory.join("credential.key");
        if !key_path.exists() {
            ensure!(
                !directory.join("vault.sqlite").exists() && !directory.join("ai.sqlite").exists(),
                "Existing TermPilot credential key is missing"
            );
            let mut opts = fs::OpenOptions::new();
            opts.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                opts.mode(0o600);
            }
            match opts.open(&key_path) {
                Ok(mut f) => {
                    f.write_all(&crypto::random_key())?;
                    f.sync_all()?;
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
                Err(e) => return Err(e.into()),
            }
        }
        let key = Zeroizing::new(fs::read(key_path)?);
        Self::open_with_key(directory, &key)
    }

    /// Mobile entry point; the caller retains the platform-protected master key.
    pub fn open_with_key(directory: &Path, key: &[u8]) -> Result<Self> {
        ensure!(
            directory.is_absolute(),
            "AI data directory must be absolute"
        );
        ensure!(key.len() == 32, "Invalid TermPilot credential key");
        fs::create_dir_all(directory)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(directory, fs::Permissions::from_mode(0o700))?;
        }
        let key = Zeroizing::new(key.to_vec());
        let db_path = directory.join("ai.sqlite");
        let db = Connection::open(&db_path)?;
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        let version: i64 = db.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        ensure!(version <= 1, "AI database was written by a newer TermPilot");
        db.execute_batch("PRAGMA journal_mode=WAL; PRAGMA secure_delete=ON; CREATE TABLE IF NOT EXISTS records (collection TEXT NOT NULL,id TEXT NOT NULL,payload BLOB NOT NULL,updated INTEGER NOT NULL,PRIMARY KEY(collection,id)); PRAGMA user_version=1;")?;
        termpilot_core::sync::journal::register(&db, &key)
            .map_err(|e| anyhow::anyhow!(e.message))?;
        termpilot_core::sync::journal::install(&db, true)
            .map_err(|e| anyhow::anyhow!(e.message))?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            fs::set_permissions(db_path, fs::Permissions::from_mode(0o600))?;
        }
        Ok(Self {
            db,
            key,
            directory: directory.to_owned(),
        })
    }
    pub fn put(&self, collection: &str, id: &str, value: &impl Serialize) -> Result<()> {
        let bytes = Zeroizing::new(serde_json::to_vec(value)?);
        ensure!(bytes.len() <= 32 * 1024 * 1024, "AI record exceeds 32 MiB");
        let aad = format!("TermPilot:AI:v1:{collection}:{id}");
        let sealed = crypto::seal(&self.key, &bytes, aad.as_bytes())
            .map_err(|_| anyhow::anyhow!("AI encryption failed"))?;
        self.db.execute("INSERT INTO records VALUES (?1,?2,?3,?4) ON CONFLICT(collection,id) DO UPDATE SET payload=excluded.payload,updated=excluded.updated",params![collection,id,sealed,crate::model::now()])?;
        Ok(())
    }
    pub fn get<T: DeserializeOwned>(&self, collection: &str, id: &str) -> Result<Option<T>> {
        let bytes: Option<Vec<u8>> = self
            .db
            .query_row(
                "SELECT payload FROM records WHERE collection=?1 AND id=?2",
                params![collection, id],
                |r| r.get(0),
            )
            .optional()?;
        bytes
            .map(|b| {
                let aad = format!("TermPilot:AI:v1:{collection}:{id}");
                let data = crypto::unseal(&self.key, &b, aad.as_bytes())
                    .map_err(|_| anyhow::anyhow!("Unable to decrypt AI record"))?;
                serde_json::from_slice(&data).context("Invalid AI record")
            })
            .transpose()
    }
    pub fn put_batch(&self, records: &[(&str, String, serde_json::Value)]) -> Result<()> {
        let transaction = self.db.unchecked_transaction()?;
        for (collection, id, value) in records {
            self.put(collection, id, value)?;
        }
        transaction.commit()?;
        Ok(())
    }
    pub fn list<T: DeserializeOwned>(&self, collection: &str) -> Result<Vec<T>> {
        let mut q = self
            .db
            .prepare("SELECT id FROM records WHERE collection=?1 ORDER BY updated DESC,id")?;
        let ids = q
            .query_map([collection], |r| r.get::<_, String>(0))?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        ids.iter()
            .map(|id| self.get(collection, id)?.context("Missing AI record"))
            .collect()
    }
    pub fn delete(&self, collection: &str, id: &str) -> Result<()> {
        self.db.execute(
            "DELETE FROM records WHERE collection=?1 AND id=?2",
            params![collection, id],
        )?;
        Ok(())
    }
}
