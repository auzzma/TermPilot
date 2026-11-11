//! Opt-in SFTP checkpoints used by mobile clients. Desktop transfers keep their
//! existing path. A checkpoint is never permission to overwrite a final file.
use super::*;
use sha2::{Digest, Sha256};
use std::{io::Read, path::PathBuf};

struct Checkpoint {
    path: PathBuf,
    value: Value,
}
impl Checkpoint {
    fn open(root: &str, local: &Path, remote: &str, upload: bool, identity: Value) -> Result<Self> {
        let normalized = normalize_selected_path(Path::new(root))?;
        let root = normalized.as_path();
        ensure!(root.is_absolute(), "Checkpoint directory must be absolute");
        safe_local_parent(&root.join("checkpoint"))?;
        std::fs::create_dir_all(root)?;
        ensure!(
            !crate::platform::is_link(&std::fs::symlink_metadata(root)?),
            "Checkpoint directory is a link"
        );
        let key = hex::encode(Sha256::digest(format!(
            "{upload}:{}:{remote}",
            local.display()
        )));
        let path = root.join(format!("{key}.json"));
        let value = if path.exists() {
            ensure!(
                std::fs::symlink_metadata(&path)?.is_file()
                    && !crate::platform::is_link(&std::fs::symlink_metadata(&path)?),
                "Invalid checkpoint"
            );
            ensure!(
                std::fs::metadata(&path)?.len() < 65536,
                "Invalid checkpoint size"
            );
            let v: Value = serde_json::from_slice(&std::fs::read(&path)?)?;
            ensure!(v["identity"] == identity && v["remote"] == remote && v["local"] == local.to_string_lossy().as_ref() && v["upload"] == upload,
                "Source changed since interruption; discard this task before starting a new transfer");
            let token = v["token"].as_str().context("Checkpoint token missing")?;
            ensure!(
                token.len() == 32 && token.chars().all(|c| c.is_ascii_hexdigit()),
                "Invalid checkpoint token"
            );
            v
        } else {
            json!({"version":1,"token":uuid::Uuid::new_v4().simple().to_string(),"identity":identity,"remote":remote,"local":local,"upload":upload,"offset":0})
        };
        let c = Self { path, value };
        c.save()?;
        Ok(c)
    }
    fn save(&self) -> Result<()> {
        use std::io::Write;
        let next = self.path.with_extension("new");
        // A task has only one owner. Stale .new files are ignored after a crash.
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let mut f = options.open(&next)?;
        f.write_all(&serde_json::to_vec(&self.value)?)?;
        f.sync_all()?;
        crate::platform::replace_file(&next, &self.path)?;
        Ok(())
    }
    fn offset(&self) -> u64 {
        self.value["offset"].as_u64().unwrap_or(0)
    }
    fn token(&self) -> &str {
        self.value["token"].as_str().unwrap()
    }
    fn advance(&mut self, offset: u64) -> Result<()> {
        self.value["offset"] = json!(offset);
        self.save()
    }
    fn finish(&self) {
        let _ = std::fs::remove_file(&self.path);
    }
}
fn local_identity(file: &std::fs::File) -> Result<Value> {
    let meta = file.metadata()?;
    let mut reader = file.try_clone()?;
    let mut hash = Sha256::new();
    let mut data = vec![0; 256 * 1024];
    loop {
        let n = reader.read(&mut data)?;
        if n == 0 {
            break;
        }
        hash.update(&data[..n]);
    }
    Ok(json!({"size":meta.len(),"sha256":hex::encode(hash.finalize())}))
}
fn remote_identity(attrs: &Attributes) -> Result<Value> {
    ensure!(attrs.kind() == "file", "Resume requires a regular file");
    Ok(
        json!({"size":attrs.size.context("Remote size unavailable")?,"mtime":attrs.mtime.context("Remote modification time unavailable for verified resume")?}),
    )
}
async fn read_exact(s: &Sftp, handle: &[u8], offset: u64, size: usize) -> Result<Vec<u8>> {
    let mut bytes = Vec::with_capacity(size);
    while bytes.len() < size {
        let part = s
            .read(
                handle,
                offset + bytes.len() as u64,
                (size - bytes.len()).min(s.max_read.load(Ordering::Relaxed)),
            )
            .await?;
        ensure!(!part.is_empty(), "Remote file shortened");
        bytes.extend(part);
    }
    Ok(bytes)
}
impl Files {
    #[allow(clippy::too_many_arguments)]
    pub(super) async fn resume_file(
        &self,
        local: &Path,
        remote: &str,
        upload: bool,
        overwrite: bool,
        r: &Value,
        state: &Arc<Transfer>,
        events: &Events,
        channel: &str,
    ) -> Result<()> {
        let s = self
            .sftp
            .as_ref()
            .context("Verified resume requires SFTP")?;
        ensure!(
            !overwrite,
            "Resumed transfers never replace an existing final file"
        );
        let local_owned = local.to_path_buf();
        let identity = if upload {
            tokio::task::spawn_blocking(move || local_identity(&open_local_source(&local_owned)?))
                .await??
        } else {
            remote_identity(&s.stat(remote, true).await?)?
        };
        let mut checkpoint = Checkpoint::open(
            text(r, "resumeDirectory"),
            local,
            remote,
            upload,
            identity.clone(),
        )?;
        let size = identity["size"].as_u64().context("Source size missing")?;
        let start = checkpoint.offset();
        ensure!(start <= size, "Invalid checkpoint offset");
        let remote_temp = format!("{remote}.termpilot-{}.part", checkpoint.token());
        let local_temp = local
            .parent()
            .context("Local parent missing")?
            .join(format!(".termpilot-{}.part", checkpoint.token()));
        let remote_source = if upload { &remote_temp } else { remote };
        let mut remote_handle = None;
        let result = async {
            state.ready().await?;
            let local_file = if upload {
                self.ensure_directory(&parent(remote), 0).await?;
                ensure!(!self.exists(remote).await?, "Remote path already exists");
                let exists = self.exists(&remote_temp).await?;
                if exists {
                    ensure!(
                        self.stat(&remote_temp).await?.kind() == "file",
                        "Remote checkpoint is not a regular file"
                    );
                }
                let handle = s
                    .open(
                        &remote_temp,
                        if exists { 1 | 2 } else { 1 | 2 | 8 | 32 },
                        Attributes {
                            permissions: Some(0o600),
                            ..Default::default()
                        },
                    )
                    .await?;
                remote_handle = Some(handle);
                Arc::new(open_local_source(local)?)
            } else {
                safe_local_parent(local)?;
                ensure!(
                    !local.exists() && std::fs::symlink_metadata(local).is_err(),
                    "Local destination already exists"
                );
                std::fs::create_dir_all(local.parent().unwrap())?;
                let mut opts = std::fs::OpenOptions::new();
                opts.read(true).write(true);
                if local_temp.exists() {
                    ensure!(
                        std::fs::symlink_metadata(&local_temp)?.is_file(),
                        "Invalid local partial file"
                    );
                } else {
                    ensure!(start == 0, "Partial file is missing; restart this transfer");
                    opts.create_new(true);
                }
                #[cfg(unix)]
                {
                    use std::os::unix::fs::OpenOptionsExt;
                    opts.mode(0o600).custom_flags(libc::O_NOFOLLOW);
                }
                let f = Arc::new(opts.open(&local_temp)?);
                remote_handle = Some(s.open(remote_source, 1, Attributes::default()).await?);
                f
            };
            let handle = remote_handle.as_ref().unwrap();
            // Verify every retained byte. Out-of-order writes beyond the committed
            // contiguous offset are overwritten, never counted as complete.
            let mut checked = 0;
            while checked < start {
                state.ready().await?;
                let n = (start - checked).min(256 * 1024) as usize;
                let remote_bytes = state
                    .interruptible(read_exact(s, handle, checked, n))
                    .await?;
                let local_bytes = read_at(&local_file, checked, n)?;
                ensure!(
                    remote_bytes == local_bytes,
                    "Partial file or source changed; verified resume refused"
                );
                checked += n as u64;
            }
            state
                .progress(&r["id"], events, channel, start, true)
                .await?;
            let mut offset = start;
            let length = s
                .max_read
                .load(Ordering::Relaxed)
                .min(s.max_write.load(Ordering::Relaxed))
                .min(65536)
                .max(4096);
            while offset < size {
                state.ready().await?;
                let mut jobs = JoinSet::new();
                let mut end = offset;
                for _ in 0..16 {
                    if end >= size {
                        break;
                    }
                    let pos = end;
                    let count = (size - end).min(length as u64) as usize;
                    end += count as u64;
                    let (s, h, f, st, memory) = (
                        s.clone(),
                        handle.clone(),
                        local_file.clone(),
                        state.clone(),
                        self.transfer_memory.clone(),
                    );
                    jobs.spawn(async move {
                        st.ready().await?;
                        let _memory = memory
                            .acquire_many_owned(count.div_ceil(4096) as u32)
                            .await?;
                        if upload {
                            let bytes =
                                tokio::task::spawn_blocking(move || read_at(&f, pos, count))
                                    .await??;
                            st.interruptible(s.write(&h, pos, &bytes)).await?;
                        } else {
                            let bytes = st.interruptible(read_exact(&s, &h, pos, count)).await?;
                            tokio::task::spawn_blocking(move || write_at(&f, pos, &bytes))
                                .await??;
                        }
                        Ok::<_, anyhow::Error>(count as u64)
                    });
                }
                let mut error = None;
                while let Some(job) = jobs.join_next().await {
                    match job {
                        Ok(Ok(n)) => {
                            state.progress(&r["id"], events, channel, n, false).await?;
                        }
                        Ok(Err(e)) => {
                            error = Some(e);
                            jobs.abort_all();
                        }
                        Err(e) => {
                            if error.is_none() {
                                error = Some(e.into());
                            }
                            jobs.abort_all();
                        }
                    }
                }
                if let Some(e) = error {
                    return Err(e);
                }
                if !upload {
                    local_file.sync_data()?;
                }
                checkpoint.advance(end)?;
                offset = end;
            }
            if upload {
                let f = local_file.clone();
                ensure!(
                    tokio::task::spawn_blocking(move || local_identity(&f)).await?? == identity,
                    "Local source changed during transfer"
                );
            } else {
                ensure!(
                    remote_identity(&s.stat(remote, true).await?)? == identity,
                    "Remote source changed during transfer"
                );
                local_file.set_len(size)?;
                local_file.sync_all()?;
            }
            s.close(handle).await?;
            remote_handle = None;
            state.ready().await?;
            if upload {
                self.publish(&remote_temp, remote, false, state).await?;
            } else {
                safe_local_parent(local)?;
                crate::platform::publish_new_file(&local_temp, local)?;
            }
            checkpoint.finish();
            Ok(())
        }
        .await;
        if let Some(handle) = remote_handle {
            let _ = tokio::time::timeout(Duration::from_secs(2), s.close(&handle)).await;
        }
        if state.user_cancel.load(Ordering::Acquire) {
            if upload {
                let _ =
                    tokio::time::timeout(Duration::from_secs(2), self.remove(&remote_temp, false))
                        .await;
            } else {
                let _ = std::fs::remove_file(&local_temp);
            }
            checkpoint.finish();
        }
        result
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn changed_source_cannot_reuse_checkpoint() {
        let root = std::env::temp_dir().join(format!("termpilot-resume-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let local = root.join("local");
        let mut c = Checkpoint::open(
            root.to_str().unwrap(),
            &local,
            "/remote",
            true,
            json!({"sha256":"one"}),
        )
        .unwrap();
        c.advance(42).unwrap();
        assert_eq!(
            Checkpoint::open(
                root.to_str().unwrap(),
                &local,
                "/remote",
                true,
                json!({"sha256":"one"})
            )
            .unwrap()
            .offset(),
            42
        );
        assert!(Checkpoint::open(
            root.to_str().unwrap(),
            &local,
            "/remote",
            true,
            json!({"sha256":"two"})
        )
        .is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}
