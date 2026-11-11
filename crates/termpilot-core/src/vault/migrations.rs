use super::*;

pub const CREDENTIAL_ELEVATION: &str = "v19-credential-elevation-method";

pub fn credential_elevation(db: &Connection, directory: &Path) -> Result<()> {
    let backup = directory.join(format!(
        "vault.sqlite.before-credential-elevation-v19-{}",
        uuid::Uuid::new_v4()
    ));
    db.backup(rusqlite::DatabaseName::Main, &backup, None)
        .map_err(database_error)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&backup, fs::Permissions::from_mode(0o600)).map_err(io_error)?;
    }
    let tx = db.unchecked_transaction().map_err(database_error)?;
    // Another process may have completed the migration while the backup ran.
    let applied: bool = tx
        .query_row(
            "SELECT EXISTS(SELECT 1 FROM grdb_migrations WHERE identifier=?1)",
            [CREDENTIAL_ELEVATION],
            |r| r.get(0),
        )
        .map_err(database_error)?;
    if !applied {
        tx.execute_batch("ALTER TABLE ssh_credentials ADD COLUMN elevation_method TEXT;")
            .map_err(database_error)?;
        for event in ["INSERT", "UPDATE", "DELETE"] {
            tx.execute_batch(&format!("DROP TRIGGER IF EXISTS tp_sync_ssh_credentials_{event}"))
                .map_err(database_error)?;
        }
        tx.execute("INSERT INTO grdb_migrations(identifier) VALUES (?1)", [CREDENTIAL_ELEVATION])
            .map_err(database_error)?;
    }
    tx.commit().map_err(database_error)?;
    Ok(())
}
