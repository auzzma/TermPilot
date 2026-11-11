//! Copy legacy data into an empty portable directory without modifying the source.
use super::*;
use rusqlite::{
    backup::{Backup, StepResult},
    OpenFlags,
};
use std::time::Instant;

fn private_directory(path: &Path) -> Result<()> {
    fs::create_dir_all(path).map_err(io_error)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(io_error)?;
    }
    Ok(())
}

fn writable(path: &Path) -> Result<()> {
    let probe = path.join(format!(".write-check-{}", uuid::Uuid::new_v4()));
    let result = fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe);
    drop(result.map_err(|_| {
        CoreError::new(
            "portableDataReadOnly",
            "AppData is not writable. Move the complete TermPilot folder to a writable location.",
        )
    })?);
    fs::remove_file(probe).map_err(io_error)
}

fn copy_tree(source: &Path, target: &Path, snapshot: bool) -> Result<()> {
    private_directory(target)?;
    for entry in fs::read_dir(source).map_err(io_error)? {
        let entry = entry.map_err(io_error)?;
        let name = entry.file_name();
        let text = name.to_string_lossy();
        // Runtime endpoint tokens and SQLite sidecars belong to the old process.
        if snapshot
            && (text.ends_with("-wal")
                || text.ends_with("-shm")
                || text.ends_with("-journal")
                || text.ends_with(".tmp")
                || text.starts_with("ai-mcp")
                || text.starts_with(".write-check-"))
        {
            continue;
        }
        let kind = entry.file_type().map_err(io_error)?;
        if kind.is_symlink() {
            return Err(CoreError::new(
                "portableDataLink",
                "Legacy data contains a symbolic link. Copy its data explicitly before migrating.",
            ));
        }
        let destination = target.join(&name);
        if kind.is_dir() {
            copy_tree(&entry.path(), &destination, snapshot)?;
        } else if kind.is_file() {
            if snapshot && text.ends_with(".sqlite") {
                snapshot_database(&entry.path(), &destination)?;
            } else {
                fs::copy(entry.path(), destination).map_err(io_error)?;
            }
        }
    }
    Ok(())
}

fn snapshot_database(source: &Path, target: &Path) -> Result<()> {
    let db = Connection::open_with_flags(source, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(database_error)?;
    db.busy_timeout(Duration::from_secs(5))
        .map_err(database_error)?;
    // Pin a read snapshot so an active WAL writer cannot repeatedly restart backup.
    db.execute_batch("BEGIN").map_err(database_error)?;
    db.query_row("SELECT count(*) FROM sqlite_master", [], |row| {
        row.get::<_, i64>(0)
    })
    .map_err(database_error)?;
    let mut destination = Connection::open(target).map_err(database_error)?;
    {
        let backup = Backup::new(&db, &mut destination).map_err(database_error)?;
        let deadline = Instant::now() + Duration::from_secs(30);
        loop {
            match backup.step(256).map_err(database_error)? {
                StepResult::Done => break,
                _ if Instant::now() >= deadline => {
                    return Err(CoreError::new(
                        "portableDataBusy",
                        "Legacy database is busy. Close the older TermPilot and try again.",
                    ))
                }
                StepResult::Busy | StepResult::Locked => {
                    std::thread::sleep(Duration::from_millis(25))
                }
                _ => {}
            }
        }
    }
    destination
        .execute_batch("PRAGMA journal_mode=DELETE;")
        .map_err(database_error)?;
    let check: String = destination
        .query_row("PRAGMA quick_check", [], |row| row.get(0))
        .map_err(database_error)?;
    if check != "ok" {
        return Err(CoreError::new(
            "portableDataCorrupt",
            "The legacy database failed its integrity check.",
        ));
    }
    Ok(())
}

pub fn prepare(directory: &Path, legacy: &Path) -> Result<Value> {
    if !directory.is_absolute() || !legacy.is_absolute() || directory == legacy {
        return Err(invalid());
    }
    if directory.exists()
        && fs::read_dir(directory)
            .map_err(io_error)?
            .next()
            .transpose()
            .map_err(io_error)?
            .is_some()
    {
        writable(directory)?;
        return Ok(json!({"migrated":false}));
    }
    let parent = directory.parent().ok_or_else(invalid)?;
    fs::create_dir_all(parent).map_err(io_error)?;
    if !legacy.is_dir() {
        private_directory(directory)?;
        writable(directory)?;
        return Ok(json!({"migrated":false}));
    }
    let old_path = legacy.canonicalize().map_err(io_error)?;
    let new_path = parent
        .canonicalize()
        .map_err(io_error)?
        .join(directory.file_name().ok_or_else(invalid)?);
    if new_path.starts_with(&old_path) || old_path.starts_with(&new_path) {
        return Err(invalid());
    }
    let key_path = legacy.join("credential.key");
    let key = if key_path.exists() {
        Some(Zeroizing::new(fs::read(&key_path).map_err(io_error)?))
    } else {
        None
    };
    if legacy.join("vault.sqlite").exists() || legacy.join("ai.sqlite").exists() || key.is_some() {
        if key.as_ref().map(|value| value.len()) != Some(32) {
            return Err(CoreError::new(
                "missingCredentialKey",
                "The legacy credential key is missing or invalid. No data was migrated.",
            ));
        }
    }
    let staging = parent.join(format!(".TermPilot-migration-{}", uuid::Uuid::new_v4()));
    let result = (|| {
        let backup = staging.join("backup");
        let data = staging.join("data");
        // Back up first, then build the working copy from that stable snapshot.
        copy_tree(legacy, &backup, true)?;
        if let Some(expected) = key {
            if expected.as_slice() != fs::read(&key_path).map_err(io_error)?.as_slice() {
                return Err(CoreError::new(
                    "credentialKeyChanged",
                    "The legacy credential key changed during migration. Try again.",
                ));
            }
        }
        copy_tree(&backup, &data, false)?;
        fs::rename(&backup, data.join("MigrationBackup")).map_err(io_error)?;
        writable(&data)?;
        if directory.exists() {
            fs::remove_dir(directory).map_err(io_error)?;
        } // Empty only; never replace data.
        fs::rename(&data, directory).map_err(io_error)?;
        Ok(json!({"migrated":true}))
    })();
    let _ = fs::remove_dir_all(staging);
    result
}
