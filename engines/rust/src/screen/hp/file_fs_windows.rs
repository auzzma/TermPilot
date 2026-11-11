//! Windows adapter for the shared Apple file protocol. Reparse points and
//! Win32 aliases are rejected; destination ancestors stay open without DELETE
//! sharing until the staged transfer is published. Existing files are never replaced.
use anyhow::{ensure, Context, Result};
use std::{
    ffi::OsString,
    fs::{File, Metadata, OpenOptions},
    io::{Read, Seek, SeekFrom, Write},
    os::windows::{
        ffi::OsStringExt,
        fs::{MetadataExt, OpenOptionsExt},
        io::AsRawHandle,
    },
    path::{Component, Path, PathBuf},
    time::{Duration, UNIX_EPOCH},
};
pub const RESOURCE: &[u8] = b"com.apple.ResourceFork\0";
pub const FINDER: &[u8] = b"com.apple.FinderInfo\0";
const REPARSE: u32 = 0x400;
const OPEN_REPARSE: u32 = 0x00200000;
const BACKUP: u32 = 0x02000000;
pub fn basename(name: &str) -> Result<&str> {
    let stem = name.split('.').next().unwrap_or("").to_ascii_uppercase();
    let reserved = ["CON", "PRN", "AUX", "NUL", "CLOCK$"].contains(&stem.as_str())
        || (["COM", "LPT"].iter().any(|s| stem.starts_with(s))
            && stem.len() == 4
            && matches!(stem.as_bytes()[3], b'1'..=b'9'));
    ensure!(
        !name.is_empty()
            && name != "."
            && name != ".."
            && name.encode_utf16().count() <= 255
            && !name.ends_with(['.', ' '])
            && !reserved
            && !name
                .chars()
                .any(|c| c < ' '
                    || matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|')),
        "invalidName"
    );
    Ok(name)
}
pub fn absolute(path: &str) -> Result<PathBuf> {
    let p = PathBuf::from(path);
    ensure!(
        p.is_absolute() && path.len() <= 32700 && !path.contains('\0'),
        "invalidPath"
    );
    for c in p.components() {
        match c {
            Component::ParentDir | Component::CurDir => anyhow::bail!("invalidPath"),
            Component::Normal(s) => {
                basename(s.to_str().context("invalidName")?)?;
            }
            Component::Prefix(p) => {
                use std::path::Prefix;
                ensure!(
                    matches!(
                        p.kind(),
                        Prefix::Disk(_)
                            | Prefix::VerbatimDisk(_)
                            | Prefix::UNC(_, _)
                            | Prefix::VerbatimUNC(_, _)
                    ),
                    "invalidPath"
                );
            }
            _ => {}
        }
    }
    Ok(p)
}
fn open(path: &Path, write: bool, new: bool) -> Result<File> {
    let file = OpenOptions::new()
        .read(true)
        .write(write)
        .create_new(new)
        .share_mode(3)
        .custom_flags(OPEN_REPARSE | BACKUP)
        .open(path)?;
    ensure!(
        file.metadata()?.file_attributes() & REPARSE == 0,
        "unsupportedFileType"
    );
    Ok(file)
}
fn guard(path: &Path) -> Result<Vec<File>> {
    absolute(path.to_str().context("invalidPath")?)?;
    let mut p = PathBuf::new();
    let mut files = Vec::new();
    for part in path.components() {
        p.push(part);
        if matches!(part, Component::Prefix(_)) {
            continue;
        }
        files.push(open(&p, false, false)?);
    }
    ensure!(!files.is_empty(), "invalidPath");
    Ok(files)
}
pub fn open_source(path: &Path) -> Result<File> {
    let mut files = guard(path)?;
    Ok(files.pop().context("invalidPath")?)
}
fn handle_path(file: &File) -> Result<PathBuf> {
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GetFinalPathNameByHandleW(h: *mut std::ffi::c_void, b: *mut u16, n: u32, f: u32) -> u32;
    }
    let mut b = vec![0u16; 32768];
    let n = unsafe {
        GetFinalPathNameByHandleW(file.as_raw_handle(), b.as_mut_ptr(), b.len() as u32, 0)
    };
    ensure!(n > 0 && (n as usize) < b.len(), "invalidPath");
    b.truncate(n as usize);
    Ok(OsString::from_wide(&b).into())
}
fn stream(file: &File, name: &[u8], write: bool) -> Result<Option<File>> {
    let suffix = if name == RESOURCE {
        ":TermPilot.ResourceFork"
    } else if name == FINDER {
        ":TermPilot.FinderInfo"
    } else {
        anyhow::bail!("invalidMetadata")
    };
    let mut path = handle_path(file)?.into_os_string();
    path.push(suffix);
    match OpenOptions::new()
        .read(true)
        .write(write)
        .create(write)
        .share_mode(3)
        .open(path)
    {
        Ok(f) => Ok(Some(f)),
        Err(e) if !write && e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}
pub fn attribute_size(file: &File, name: &[u8]) -> Result<u64> {
    Ok(match stream(file, name, false)? {
        Some(f) => f.metadata()?.len(),
        None => 0,
    })
}
pub fn attribute(file: &File, name: &[u8], size: usize, position: u32) -> Result<Vec<u8>> {
    ensure!(size <= 4 * 1024 * 1024, "invalidMetadata");
    let Some(mut f) = stream(file, name, false)? else {
        return Ok(Vec::new());
    };
    f.seek(SeekFrom::Start(position.into()))?;
    let mut b = Vec::new();
    f.take(size as u64).read_to_end(&mut b)?;
    Ok(b)
}
pub fn set_attribute(file: &File, name: &[u8], data: &[u8], position: u32) -> Result<()> {
    let mut f = stream(file, name, true)?.context("invalidMetadata")?;
    f.seek(SeekFrom::Start(position.into()))?;
    f.write_all(data)?;
    Ok(())
}
pub struct Item {
    pub path: PathBuf,
    pub info: Metadata,
    pub depth: u16,
    pub resource: u64,
}
pub fn scan(root: &Path, check: &impl Fn() -> Result<()>) -> Result<Vec<Item>> {
    fn visit(
        path: PathBuf,
        depth: u16,
        items: &mut Vec<Item>,
        check: &impl Fn() -> Result<()>,
    ) -> Result<()> {
        check()?;
        ensure!(depth <= 128 && items.len() < 100_000, "tooManyFiles");
        basename(
            path.file_name()
                .and_then(|n| n.to_str())
                .context("invalidName")?,
        )?;
        let guards = guard(&path)?;
        let f = guards.last().unwrap();
        let info = f.metadata()?;
        ensure!(info.is_dir() || info.is_file(), "unsupportedFileType");
        let folder = info.is_dir();
        let resource = if folder {
            0
        } else {
            attribute_size(f, RESOURCE)?
        };
        ensure!(resource <= u32::MAX as u64, "unsupportedFileType");
        items.push(Item {
            path: path.clone(),
            info,
            depth,
            resource,
        });
        if folder {
            let mut entries = std::fs::read_dir(&path)?
                .map(|e| e.map(|e| e.path()))
                .collect::<std::io::Result<Vec<_>>>()?;
            entries.sort();
            for entry in entries {
                visit(entry, depth + 1, items, check)?;
            }
        }
        Ok(())
    }
    let mut items = Vec::new();
    visit(root.into(), 0, &mut items, check)?;
    Ok(items)
}
pub fn unchanged(a: &Metadata, b: &Metadata) -> bool {
    a.len() == b.len()
        && a.creation_time() == b.creation_time()
        && a.last_write_time() == b.last_write_time()
        && a.file_attributes() == b.file_attributes()
}
pub fn allocated(info: &Metadata) -> u64 {
    info.len()
}
pub fn metadata(item: &Item) -> Result<Vec<u8>> {
    let name = basename(
        item.path
            .file_name()
            .and_then(|n| n.to_str())
            .context("invalidName")?,
    )?
    .as_bytes();
    let folder = item.info.is_dir();
    let mut d = vec![0; 104];
    d[0] = if folder { 2 } else { 1 };
    d[34..42].copy_from_slice(&item.resource.to_be_bytes());
    d[42..50].copy_from_slice(&(if folder { 0 } else { item.info.len() }).to_be_bytes());
    for (offset, time) in [
        (50, item.info.created()),
        (58, item.info.modified()),
        (66, item.info.created()),
        (74, item.info.accessed()),
    ] {
        let seconds = time
            .unwrap_or(UNIX_EPOCH)
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs()
            .saturating_add(2082844800);
        let t = seconds.checked_mul(65536).context("invalidMetadata")?;
        d[offset..offset + 8].copy_from_slice(&t.to_be_bytes());
    }
    d[88..92].copy_from_slice(&(if folder { 16u32 } else { 0 }).to_be_bytes());
    d[92..94].copy_from_slice(&item.depth.to_be_bytes());
    d[94..96].copy_from_slice(&(if folder { 0o40755u16 } else { 0o100644u16 }).to_be_bytes());
    d[96..100].copy_from_slice(&0x7eu32.to_be_bytes());
    d[100..102].copy_from_slice(&(name.len() as u16).to_be_bytes());
    d.extend(name);
    d.push(0);
    Ok(d)
}
pub struct Stage {
    directory: PathBuf,
    destination: PathBuf,
    _parents: Vec<File>,
    guards: std::sync::Mutex<Vec<File>>,
}
impl Stage {
    pub fn new(destination: &Path) -> Result<Self> {
        absolute(destination.to_str().context("invalidPath")?)?;
        basename(
            destination
                .file_name()
                .and_then(|n| n.to_str())
                .context("invalidName")?,
        )?;
        let parent = destination.parent().context("invalidPath")?;
        let parents = guard(parent)?;
        ensure!(parents.last().unwrap().metadata()?.is_dir(), "invalidPath");
        ensure!(!destination.try_exists()?, "alreadyExists");
        let directory = parent.join(format!(".termpilot-{}.partial", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory)?;
        let guards = vec![open(&directory, false, false)?];
        Ok(Self {
            directory,
            destination: destination.into(),
            _parents: parents,
            guards: std::sync::Mutex::new(guards),
        })
    }
    fn path(&self, path: &Path) -> Result<PathBuf> {
        ensure!(!path.as_os_str().is_empty(), "invalidPath");
        for c in path.components() {
            let Component::Normal(n) = c else {
                anyhow::bail!("invalidPath")
            };
            basename(n.to_str().context("invalidName")?)?;
        }
        Ok(self.directory.join(path))
    }
    pub fn file(&self, path: &Path, directory: bool) -> Result<File> {
        let path = self.path(path)?;
        let _ancestors = guard(path.parent().context("invalidPath")?)?;
        if directory {
            std::fs::create_dir(&path)?;
        }
        let f = open(&path, !directory, !directory)?;
        let mut guards = self.guards.lock().unwrap();
        if directory {
            guards.push(f.try_clone()?);
        }
        Ok(f)
    }
    pub fn apply(&self, path: &Path, _mode: u32, modified: i64) -> Result<()> {
        let file = OpenOptions::new()
            .access_mode(0x100)
            .share_mode(3)
            .custom_flags(OPEN_REPARSE | BACKUP)
            .open(self.path(path)?)?;
        let time = if modified >= 0 {
            UNIX_EPOCH.checked_add(Duration::from_secs(modified as u64))
        } else {
            UNIX_EPOCH.checked_sub(Duration::from_secs(modified.unsigned_abs()))
        }
        .context("invalidMetadata")?;
        file.set_times(std::fs::FileTimes::new().set_modified(time))?;
        Ok(())
    }
    pub fn publish(&mut self) -> Result<()> {
        // Release handles inside staging before rename; keep destination ancestors
        // locked. The unpredictable staging directory is not exposed to the peer.
        let mut guards = self.guards.lock().unwrap();
        guards.clear();
        use std::os::windows::ffi::OsStrExt;
        #[link(name = "kernel32")]
        unsafe extern "system" {
            fn MoveFileExW(source: *const u16, destination: *const u16, flags: u32) -> i32;
        }
        let source: Vec<u16> = self
            .directory
            .join("item")
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect();
        let destination: Vec<u16> = self
            .destination
            .as_os_str()
            .encode_wide()
            .chain(Some(0))
            .collect();
        // No MOVEFILE_REPLACE_EXISTING: check and rename must be one operation.
        if unsafe { MoveFileExW(source.as_ptr(), destination.as_ptr(), 0) } == 0 {
            let e = std::io::Error::last_os_error();
            if matches!(e.raw_os_error(), Some(80 | 183)) {
                anyhow::bail!("alreadyExists");
            }
            return Err(e.into());
        }
        Ok(())
    }
}
impl Drop for Stage {
    fn drop(&mut self) {
        self.guards.get_mut().unwrap().clear();
        let _ = std::fs::remove_dir_all(&self.directory);
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn windows_aliases_rejected() {
        for s in [
            "..", "CON.txt", "NUL", "x:y", "file.", "file ", "a/b", "COM1.log",
        ] {
            assert!(basename(s).is_err(), "{s}");
        }
        assert!(basename("中文.txt").is_ok());
    }
    #[test]
    fn staging_preserves_existing() {
        let root = std::env::temp_dir().join(uuid::Uuid::new_v4().to_string());
        std::fs::create_dir(&root).unwrap();
        let path = root.join("中文.txt");
        let mut stage = Stage::new(&path).unwrap();
        {
            let mut f = stage.file(Path::new("item"), false).unwrap();
            f.write_all(b"new").unwrap();
        }
        std::fs::write(&path, b"old").unwrap();
        assert!(stage.publish().is_err());
        drop(stage);
        assert_eq!(std::fs::read(&path).unwrap(), b"old");
        std::fs::remove_dir_all(root).unwrap();
    }
}
