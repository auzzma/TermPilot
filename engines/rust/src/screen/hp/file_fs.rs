//! File-descriptor-relative operations for native drag transfers. An ancestor
//! replaced with a symlink cannot redirect a transfer outside the chosen tree.
use anyhow::{ensure, Context, Result};
use std::{
    ffi::{CStr, CString},
    fs::File,
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::{ffi::OsStrExt, fs::MetadataExt},
    },
    path::{Component, Path, PathBuf},
};
pub const RESOURCE: &[u8] = b"com.apple.ResourceFork\0";
pub const FINDER: &[u8] = b"com.apple.FinderInfo\0";
fn cstr(value: &std::ffi::OsStr) -> Result<CString> {
    Ok(CString::new(value.as_bytes())?)
}
fn result(status: libc::c_int) -> Result<()> {
    if status < 0 {
        Err(std::io::Error::last_os_error().into())
    } else {
        Ok(())
    }
}
pub fn basename(name: &str) -> Result<&str> {
    ensure!(
        !name.is_empty()
            && name != "."
            && name != ".."
            && name.len() <= 255
            && !name.chars().any(|c| matches!(c, '/' | '\\' | '\0')),
        "invalidName"
    );
    Ok(name)
}
pub fn absolute(path: &str) -> Result<PathBuf> {
    ensure!(
        path.starts_with('/')
            && path.len() <= 4095
            && !path.contains('\0')
            && !Path::new(path)
                .components()
                .any(|c| matches!(c, Component::ParentDir)),
        "invalidPath"
    );
    Ok(PathBuf::from(path))
}
pub fn open_at(parent: &File, name: &std::ffi::OsStr, flags: i32, mode: u32) -> Result<File> {
    let name = cstr(name)?;
    let fd = unsafe {
        libc::openat(
            parent.as_raw_fd(),
            name.as_ptr(),
            flags | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            mode,
        )
    };
    if fd < 0 {
        return Err(std::io::Error::last_os_error().into());
    }
    Ok(unsafe { File::from_raw_fd(fd) })
}
pub fn open_source(path: &Path) -> Result<File> {
    ensure!(path.is_absolute(), "invalidPath");
    let mut fd = File::open("/")?;
    let parts = path
        .components()
        .filter(|c| !matches!(c, Component::RootDir))
        .collect::<Vec<_>>();
    for (index, part) in parts.iter().enumerate() {
        let Component::Normal(name) = part else {
            anyhow::bail!("invalidPath")
        };
        fd = open_at(
            &fd,
            name,
            libc::O_RDONLY
                | if index + 1 < parts.len() {
                    libc::O_DIRECTORY
                } else {
                    0
                },
            0,
        )?;
    }
    Ok(fd)
}
pub fn relative(parent: &File, path: &Path, flags: i32) -> Result<File> {
    let mut fd = parent.try_clone()?;
    let parts = path.components().collect::<Vec<_>>();
    ensure!(!parts.is_empty(), "invalidPath");
    for (index, part) in parts.iter().enumerate() {
        let Component::Normal(name) = part else {
            anyhow::bail!("invalidPath")
        };
        fd = open_at(
            &fd,
            name,
            if index + 1 == parts.len() {
                flags
            } else {
                libc::O_RDONLY | libc::O_DIRECTORY
            },
            0o600,
        )?;
    }
    Ok(fd)
}
#[cfg(not(target_os = "android"))]
pub fn attribute_size(file: &File, name: &[u8]) -> Result<u64> {
    let n = unsafe {
        libc::fgetxattr(
            file.as_raw_fd(),
            name.as_ptr().cast(),
            std::ptr::null_mut(),
            0,
            0,
            0,
        )
    };
    if n < 0 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ENOATTR) {
            return Ok(0);
        }
        return Err(error.into());
    }
    Ok(n as u64)
}
#[cfg(not(target_os = "android"))]
pub fn attribute(file: &File, name: &[u8], size: usize, position: u32) -> Result<Vec<u8>> {
    ensure!(size <= 4 * 1024 * 1024, "invalidMetadata");
    let mut data = vec![0; size];
    let n = unsafe {
        libc::fgetxattr(
            file.as_raw_fd(),
            name.as_ptr().cast(),
            data.as_mut_ptr().cast(),
            size,
            position,
            0,
        )
    };
    if n < 0 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ENOATTR) {
            return Ok(Vec::new());
        }
        return Err(error.into());
    }
    data.truncate(n as usize);
    Ok(data)
}
#[cfg(not(target_os = "android"))]
pub fn set_attribute(file: &File, name: &[u8], data: &[u8], position: u32) -> Result<()> {
    result(unsafe {
        libc::fsetxattr(
            file.as_raw_fd(),
            name.as_ptr().cast(),
            data.as_ptr().cast(),
            data.len(),
            position,
            0,
        )
    })
}
pub fn names(file: &File) -> Result<Vec<std::ffi::OsString>> {
    let fd = unsafe { libc::dup(file.as_raw_fd()) };
    ensure!(fd >= 0, "ioError");
    let dir = unsafe { libc::fdopendir(fd) };
    if dir.is_null() {
        unsafe { libc::close(fd) };
        return Err(std::io::Error::last_os_error().into());
    }
    struct Dir(*mut libc::DIR);
    impl Drop for Dir {
        fn drop(&mut self) {
            unsafe { libc::closedir(self.0) };
        }
    }
    let dir = Dir(dir);
    let mut names = Vec::new();
    loop {
        unsafe {
            #[cfg(not(target_os = "android"))]
            {
                *libc::__error() = 0;
            }
            #[cfg(target_os = "android")]
            {
                *libc::__errno() = 0;
            }
        }
        let entry = unsafe { libc::readdir(dir.0) };
        if entry.is_null() {
            let error = std::io::Error::last_os_error();
            ensure!(
                error.raw_os_error() == Some(0),
                "Directory read failed: {error}"
            );
            break;
        }
        let name = unsafe { CStr::from_ptr((*entry).d_name.as_ptr()) }.to_bytes();
        if name == b"." || name == b".." {
            continue;
        }
        ensure!(names.len() < 100_000, "tooManyFiles");
        names.push(std::ffi::OsStr::from_bytes(name).to_os_string());
    }
    names.sort();
    Ok(names)
}
pub struct Item {
    pub path: PathBuf,
    pub info: std::fs::Metadata,
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
        let fd = open_source(&path)?;
        let info = fd.metadata()?;
        ensure!(info.is_dir() || info.is_file(), "unsupportedFileType");
        let resource = if info.is_file() {
            attribute_size(&fd, RESOURCE)?
        } else {
            0
        };
        ensure!(resource <= u32::MAX as u64, "unsupportedFileType");
        let children = if info.is_dir() {
            names(&fd)?
        } else {
            Vec::new()
        };
        items.push(Item {
            path: path.clone(),
            info,
            depth,
            resource,
        });
        for name in children {
            visit(path.join(name), depth + 1, items, check)?;
        }
        Ok(())
    }
    let mut items = Vec::new();
    visit(root.to_path_buf(), 0, &mut items, check)?;
    Ok(items)
}
pub fn unchanged(a: &std::fs::Metadata, b: &std::fs::Metadata) -> bool {
    a.dev() == b.dev()
        && a.ino() == b.ino()
        && a.size() == b.size()
        && a.mtime() == b.mtime()
        && a.mtime_nsec() == b.mtime_nsec()
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
    let mut data = vec![0; 104];
    data[0] = if folder { 2 } else { 1 };
    data[34..42].copy_from_slice(&item.resource.to_be_bytes());
    data[42..50].copy_from_slice(&(if folder { 0 } else { item.info.size() }).to_be_bytes());
    for (offset, time) in [
        (50, item.info.ctime()),
        (58, item.info.mtime()),
        (66, item.info.ctime()),
        (74, item.info.atime()),
    ] {
        let value = (time.saturating_add(2082844800).max(0) as u64)
            .checked_mul(1 << 16)
            .context("invalidMetadata")?;
        data[offset..offset + 8].copy_from_slice(&value.to_be_bytes());
    }
    data[88..92].copy_from_slice(&(if folder { 16u32 } else { 0 }).to_be_bytes());
    data[92..94].copy_from_slice(&item.depth.to_be_bytes());
    data[94..96].copy_from_slice(
        &((if folder { libc::S_IFDIR } else { libc::S_IFREG }) as u16
            | (item.info.mode() as u16 & 0o777))
            .to_be_bytes(),
    );
    data[96..100].copy_from_slice(&0x7eu32.to_be_bytes());
    data[100..102].copy_from_slice(&(name.len() as u16).to_be_bytes());
    data.extend(name);
    data.push(0);
    Ok(data)
}
pub struct Stage {
    parent: File,
    directory: File,
    name: CString,
    destination: CString,
    published: bool,
}
impl Stage {
    pub fn new(destination: &Path) -> Result<Self> {
        let name = basename(
            destination
                .file_name()
                .and_then(|n| n.to_str())
                .context("invalidName")?,
        )?;
        let parent = destination
            .parent()
            .context("invalidPath")?
            .canonicalize()?;
        let parent = open_source(&parent)?;
        ensure!(parent.metadata()?.is_dir(), "invalidPath");
        let destination = CString::new(name)?;
        let mut info = std::mem::MaybeUninit::<libc::stat>::uninit();
        let exists = unsafe {
            libc::fstatat(
                parent.as_raw_fd(),
                destination.as_ptr(),
                info.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        };
        ensure!(exists != 0, "alreadyExists");
        ensure!(
            std::io::Error::last_os_error().raw_os_error() == Some(libc::ENOENT),
            "ioError"
        );
        let name = CString::new(format!(".termpilot-{}.partial", uuid::Uuid::new_v4()))?;
        result(unsafe { libc::mkdirat(parent.as_raw_fd(), name.as_ptr(), 0o700) })?;
        let directory = open_at(
            &parent,
            std::ffi::OsStr::from_bytes(name.as_bytes()),
            libc::O_RDONLY | libc::O_DIRECTORY,
            0,
        )?;
        Ok(Self {
            parent,
            directory,
            name,
            destination,
            published: false,
        })
    }
    pub fn file(&self, path: &Path, directory: bool) -> Result<File> {
        let parent = path.parent().context("invalidPath")?;
        let fd = if parent.as_os_str().is_empty() {
            self.directory.try_clone()?
        } else {
            relative(&self.directory, parent, libc::O_RDONLY | libc::O_DIRECTORY)?
        };
        let name = path.file_name().context("invalidName")?;
        if directory {
            let name = cstr(name)?;
            result(unsafe { libc::mkdirat(fd.as_raw_fd(), name.as_ptr(), 0o700) })?;
        }
        open_at(
            &fd,
            name,
            if directory {
                libc::O_RDONLY | libc::O_DIRECTORY
            } else {
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL
            },
            0o600,
        )
    }
    pub fn apply(&self, path: &Path, mode: u32, modified: i64) -> Result<()> {
        let file = relative(&self.directory, path, libc::O_RDONLY)?;
        let times = [libc::timespec {
            tv_sec: modified,
            tv_nsec: 0,
        }; 2];
        result(unsafe { libc::futimens(file.as_raw_fd(), times.as_ptr()) })?;
        result(unsafe { libc::fchmod(file.as_raw_fd(), mode as libc::mode_t) })
    }
    pub fn publish(&mut self) -> Result<()> {
        let item = c"item";
        #[cfg(not(target_os = "android"))]
        let status = unsafe {
            libc::renameatx_np(
                self.directory.as_raw_fd(),
                item.as_ptr(),
                self.parent.as_raw_fd(),
                self.destination.as_ptr(),
                libc::RENAME_EXCL,
            )
        };
        #[cfg(target_os = "android")]
        let status = unsafe {
            libc::syscall(
                libc::SYS_renameat2,
                self.directory.as_raw_fd(),
                item.as_ptr(),
                self.parent.as_raw_fd(),
                self.destination.as_ptr(),
                1u32,
            ) as i32
        };
        if status != 0 {
            let error = std::io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::EEXIST) {
                anyhow::bail!("alreadyExists");
            }
            return Err(error.into());
        }
        self.published = true;
        self.parent.sync_all()?;
        Ok(())
    }
}
fn remove_children(directory: &File) -> Result<()> {
    for name in names(directory)? {
        let c = cstr(&name)?;
        let mut info = std::mem::MaybeUninit::<libc::stat>::uninit();
        result(unsafe {
            libc::fstatat(
                directory.as_raw_fd(),
                c.as_ptr(),
                info.as_mut_ptr(),
                libc::AT_SYMLINK_NOFOLLOW,
            )
        })?;
        let info = unsafe { info.assume_init() };
        if info.st_mode & libc::S_IFMT == libc::S_IFDIR {
            result(unsafe {
                libc::fchmodat(
                    directory.as_raw_fd(),
                    c.as_ptr(),
                    0o700,
                    libc::AT_SYMLINK_NOFOLLOW,
                )
            })?;
            let child = open_at(directory, &name, libc::O_RDONLY | libc::O_DIRECTORY, 0)?;
            remove_children(&child)?;
            result(unsafe {
                libc::unlinkat(directory.as_raw_fd(), c.as_ptr(), libc::AT_REMOVEDIR)
            })?;
        } else {
            result(unsafe { libc::unlinkat(directory.as_raw_fd(), c.as_ptr(), 0) })?;
        }
    }
    Ok(())
}
impl Drop for Stage {
    fn drop(&mut self) {
        let _ = remove_children(&self.directory);
        unsafe {
            libc::unlinkat(
                self.parent.as_raw_fd(),
                self.name.as_ptr(),
                libc::AT_REMOVEDIR,
            )
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn staging_never_replaces_existing() {
        let root = std::env::temp_dir().join(format!("TermPilot-files-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let path = root.join("中文.txt");
        let mut stage = Stage::new(&path).unwrap();
        let mut f = stage.file(Path::new("item"), false).unwrap();
        use std::io::Write;
        f.write_all(b"new").unwrap();
        std::fs::write(&path, b"old").unwrap();
        assert!(stage.publish().is_err());
        drop(stage);
        assert_eq!(std::fs::read(&path).unwrap(), b"old");
        assert_eq!(std::fs::read_dir(&root).unwrap().count(), 1);
        std::fs::remove_dir_all(root).unwrap();
    }
    #[test]
    fn ancestor_links_rejected() {
        let root = std::env::temp_dir().join(format!("TermPilot-files-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&root).unwrap();
        let root = root.canonicalize().unwrap();
        std::os::unix::fs::symlink("/", root.join("link")).unwrap();
        assert!(open_source(&root.join("link/etc/passwd")).is_err());
        std::fs::remove_dir_all(root).unwrap();
    }
}

pub fn allocated(info: &std::fs::Metadata) -> u64 {
    info.blocks().saturating_mul(512)
}

// Android stores supported Apple metadata in the app-private filesystem's user namespace.
// Never silently discard metadata: a provider/filesystem limit aborts the staged transfer.
#[cfg(target_os = "android")]
fn android_attribute(file: &File, name: &[u8]) -> Result<Vec<u8>> {
    let mut key = b"user.".to_vec();
    key.extend(name);
    let size = unsafe {
        libc::fgetxattr(
            file.as_raw_fd(),
            key.as_ptr().cast(),
            std::ptr::null_mut(),
            0,
        )
    };
    if size < 0 {
        let error = std::io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::ENODATA) {
            return Ok(Vec::new());
        }
        return Err(error.into());
    }
    ensure!(
        size <= 65536,
        "Android filesystem metadata exceeds 64 KiB; transfer was not published"
    );
    let mut data = vec![0; size as usize];
    let count = unsafe {
        libc::fgetxattr(
            file.as_raw_fd(),
            key.as_ptr().cast(),
            data.as_mut_ptr().cast(),
            data.len(),
        )
    };
    ensure!(count >= 0, "Cannot read Android file metadata");
    data.truncate(count as usize);
    Ok(data)
}
#[cfg(target_os = "android")]
pub fn attribute_size(file: &File, name: &[u8]) -> Result<u64> {
    Ok(android_attribute(file, name)?.len() as u64)
}
#[cfg(target_os = "android")]
pub fn attribute(file: &File, name: &[u8], size: usize, position: u32) -> Result<Vec<u8>> {
    let data = android_attribute(file, name)?;
    let start = (position as usize).min(data.len());
    let end = start.saturating_add(size).min(data.len());
    Ok(data[start..end].to_vec())
}
#[cfg(target_os = "android")]
pub fn set_attribute(file: &File, name: &[u8], data: &[u8], position: u32) -> Result<()> {
    let end = (position as usize)
        .checked_add(data.len())
        .context("Metadata offset overflow")?;
    ensure!(
        end <= 65536,
        "Android filesystem metadata exceeds 64 KiB; transfer was not published"
    );
    let mut value = android_attribute(file, name)?;
    value.resize(value.len().max(end), 0);
    value[position as usize..end].copy_from_slice(data);
    let mut key = b"user.".to_vec();
    key.extend(name);
    result(unsafe {
        libc::fsetxattr(
            file.as_raw_fd(),
            key.as_ptr().cast(),
            value.as_ptr().cast(),
            value.len(),
            0,
        )
    })
}
