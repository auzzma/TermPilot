//! OpenSSH host pinning. Updates preserve unrelated aliases and comments, and
//! recheck the file under a lock after the user has confirmed a changed key.
use anyhow::{ensure, Context, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use hmac::{Hmac, Mac};
use russh::keys::{self, PublicKey};
use sha1::Sha1;
use std::{
    fs,
    io::{Read, Write},
    path::Path,
};

fn matches(host: &str, pattern: &str) -> bool {
    if let Some(parts) = pattern.strip_prefix("|1|") {
        if let Some((salt, digest)) = parts.split_once('|') {
            if let (Ok(salt), Ok(digest)) = (STANDARD.decode(salt), STANDARD.decode(digest)) {
                if let Ok(mut mac) = Hmac::<Sha1>::new_from_slice(&salt) {
                    mac.update(host.as_bytes());
                    return mac.verify_slice(&digest).is_ok();
                }
            }
        }
        false
    } else {
        host.eq_ignore_ascii_case(pattern)
    }
}
fn contents(path: &Path) -> Result<String> {
    let file = match fs::File::open(path) {
        Ok(file) => file,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(String::new()),
        Err(error) => return Err(error.into()),
    };
    ensure!(
        file.metadata()?.is_file(),
        "known_hosts must be a regular file"
    );
    let mut data = String::new();
    file.take(16 * 1024 * 1024 + 1).read_to_string(&mut data)?;
    ensure!(data.len() <= 16 * 1024 * 1024, "known_hosts size limit");
    Ok(data)
}
pub fn records(path: &Path, host: &str) -> Result<Vec<PublicKey>> {
    parse(&contents(path)?, host)
}
fn parse(data: &str, host: &str) -> Result<Vec<PublicKey>> {
    let mut keys = Vec::new();
    for line in data.lines() {
        let mut fields = line.split_whitespace();
        let Some(mut names) = fields.next() else {
            continue;
        };
        if names.starts_with('#') {
            continue;
        }
        let marker = if names.starts_with('@') {
            let m = names;
            names = fields.next().unwrap_or("");
            m
        } else {
            ""
        };
        if !names.split(',').any(|name| matches(host, name)) {
            continue;
        }
        ensure!(
            marker.is_empty(),
            "This host has a known_hosts marker requiring explicit key administration"
        );
        fields.next().context("Invalid known_hosts algorithm")?;
        let encoded = fields.next().context("Invalid known_hosts key")?;
        keys.push(keys::parse_public_key_base64(encoded)?);
    }
    Ok(keys)
}
pub fn save(path: &Path, host: &str, key: &PublicKey, approved: &[PublicKey]) -> Result<()> {
    let parent = path.parent().context("known_hosts parent")?;
    fs::create_dir_all(parent)?;
    let mut options = fs::OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let lock = options.open(path.with_extension("lock"))?;
    crate::platform::lock_file_exclusive(&lock).context("Lock SSH host key file")?;
    let previous = contents(path)?;
    let current = parse(&previous, host)?;
    if current.iter().any(|k| k == key) {
        return Ok(());
    }
    ensure!(
        current == approved,
        "Host keys changed during confirmation; reconnect to review them"
    );
    let updated = replace(&previous, host, key)?;
    let temporary = parent.join(format!(
        ".termpilot-known-hosts-{}",
        uuid::Uuid::new_v4().simple()
    ));
    let result = (|| {
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
        }
        let mut file = options.open(&temporary)?;
        file.write_all(updated.as_bytes())?;
        file.sync_all()?;
        crate::platform::replace_file(&temporary, path)?;
        Ok(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}
fn replace(previous: &str, host: &str, key: &PublicKey) -> Result<String> {
    let mut output = String::new();
    for line in previous.lines() {
        let fields = line.split_whitespace().collect::<Vec<_>>();
        if fields.len() >= 3
            && !fields[0].starts_with(['#', '@'])
            && fields[1] == key.algorithm().as_str()
        {
            let names = fields[0]
                .split(',')
                .filter(|name| !matches(host, name))
                .collect::<Vec<_>>();
            if names.len() != fields[0].split(',').count() {
                if !names.is_empty() {
                    output.push_str(&names.join(","));
                    output.push(' ');
                    output.push_str(&fields[1..].join(" "));
                    output.push('\n');
                }
                continue;
            }
        }
        output.push_str(line);
        output.push('\n');
    }
    output.push_str(host);
    output.push(' ');
    output.push_str(&key.to_openssh()?);
    output.push('\n');
    Ok(output)
}

#[cfg(test)]
mod tests {
    use super::*;
    struct TestDirectory(std::path::PathBuf);
    impl TestDirectory {
        fn new() -> Self {
            let path =
                std::env::temp_dir().join(format!("termpilot-host-keys-{}", uuid::Uuid::new_v4()));
            fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for TestDirectory {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    #[test]
    fn first_save_persists_and_stale_approval_cannot_replace_key() {
        let root = TestDirectory::new();
        let path = root.0.join("known_hosts");
        let old = keys::PrivateKey::random(&mut rand10::rng(), keys::Algorithm::Ed25519).unwrap();
        let new = keys::PrivateKey::random(&mut rand10::rng(), keys::Algorithm::Ed25519).unwrap();
        save(&path, "host", old.public_key(), &[]).unwrap();
        assert_eq!(
            records(&path, "host").unwrap(),
            vec![old.public_key().clone()]
        );
        let original = fs::read(&path).unwrap();
        assert!(save(&path, "host", new.public_key(), &[]).is_err());
        assert_eq!(fs::read(&path).unwrap(), original);
        save(&path, "host", new.public_key(), &[old.public_key().clone()]).unwrap();
        assert_eq!(
            records(&path, "host").unwrap(),
            vec![new.public_key().clone()]
        );
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
    }
    #[test]
    fn concurrent_host_approvals_preserve_every_record() {
        let root = TestDirectory::new();
        let path = root.0.join("known_hosts");
        let key = keys::PrivateKey::random(&mut rand10::rng(), keys::Algorithm::Ed25519).unwrap();
        let barrier = std::sync::Barrier::new(8);
        std::thread::scope(|scope| {
            for index in 0..8 {
                let (path, key, barrier) = (&path, key.public_key(), &barrier);
                scope.spawn(move || {
                    barrier.wait();
                    save(path, &format!("host-{index}"), key, &[]).unwrap();
                });
            }
        });
        for index in 0..8 {
            assert_eq!(
                records(&path, &format!("host-{index}")).unwrap(),
                vec![key.public_key().clone()]
            );
        }
    }
    #[test]
    fn replacement_keeps_comments_other_hosts_and_aliases() {
        let old = keys::PrivateKey::random(&mut rand10::rng(), keys::Algorithm::Ed25519).unwrap();
        let new = keys::PrivateKey::random(&mut rand10::rng(), keys::Algorithm::Ed25519).unwrap();
        let original = format!(
            "# first comment\nother {}\n# second comment\nhost,alias {}\n",
            old.public_key().to_openssh().unwrap(),
            old.public_key().to_openssh().unwrap()
        );
        let result = replace(&original, "host", new.public_key()).unwrap();
        assert_eq!(
            parse(&result, "host").unwrap(),
            vec![new.public_key().clone()]
        );
        assert_eq!(
            parse(&result, "other").unwrap(),
            vec![old.public_key().clone()]
        );
        assert_eq!(
            parse(&result, "alias").unwrap(),
            vec![old.public_key().clone()]
        );
        assert!(result.contains("# second comment"));
    }
}
