use super::*;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use tokio::net::{UnixListener, UnixStream};

pub(super) const TRANSPORT: &str = "unixStream";
pub(super) fn private_directory(path: &Path) -> Result<()> {
    ensure!(path.is_absolute(), "mediaBrokerUnavailable");
    match std::fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => {}
        Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e.into()),
    }
    let meta = std::fs::symlink_metadata(path)?;
    ensure!(
        meta.is_dir() && meta.uid() == unsafe { libc::geteuid() } && meta.mode() & 0o077 == 0,
        "mediaBrokerUnavailable"
    );
    Ok(())
}

fn socket_path(config: &Value) -> Result<PathBuf> {
    let lock = Path::new(ipc::text(config, "lockDirectory"));
    private_directory(lock)?;
    let canonical = std::fs::canonicalize(lock)?;
    // macOS sockaddr_un has a short path limit; the app's temporary directory
    // can already approach it. Hash the canonical lock namespace into /tmp.
    let digest = hex::encode(Sha256::digest(canonical.as_os_str().as_encoded_bytes()));
    let directory = PathBuf::from(format!(
        "/tmp/TermPilot-Media-{}-{}",
        unsafe { libc::geteuid() },
        &digest[..16]
    ));
    private_directory(&directory)?;
    Ok(directory.join("media-v1.sock"))
}

fn check_socket(path: &Path) -> Result<()> {
    let meta = std::fs::symlink_metadata(path)?;
    ensure!(
        meta.file_type().is_socket()
            && meta.uid() == unsafe { libc::geteuid() }
            && meta.mode() & 0o077 == 0,
        "mediaBrokerUnavailable"
    );
    Ok(())
}

struct SocketCleanup(PathBuf);
impl Drop for SocketCleanup {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

pub(super) async fn serve(config: &Value) -> Result<()> {
    let path = socket_path(config)?;
    let lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW)
        .open(path.with_extension("lock"))?;
    if lock.try_lock().is_err() {
        return Ok(());
    }
    let _legacy_lock = super::super::lock(config).await?;
    if path.exists() {
        check_socket(&path)?;
        std::fs::remove_file(&path)?;
    }
    let listener = UnixListener::bind(&path)?;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
    let _cleanup = SocketCleanup(path);
    ipc::write_json(
        &mut tokio::io::stdout(),
        &json!({"ready":true,"version":VERSION}),
    )
    .await?;
    let state = Arc::new(Mutex::new(State::default()));
    let mut clients = JoinSet::new();
    let mut idle = Instant::now();
    let mut timer = tokio::time::interval(Duration::from_secs(1));
    loop {
        tokio::select! {
            accepted = listener.accept() => {
                let (socket, _) = accepted?;
                if socket.peer_cred()?.uid() != unsafe { libc::geteuid() } { continue; }
                let state = state.clone();
                clients.spawn(async move { let _ = serve_client(socket, state).await; });
                idle = Instant::now();
            }
            _ = clients.join_next(), if !clients.is_empty() => { idle = Instant::now(); }
            _ = timer.tick() => {
                if clients.is_empty() && idle.elapsed() >= Duration::from_secs(5) { break; }
            }
        }
    }
    Ok(())
}

pub(super) async fn open_socket(config: &Value) -> Result<UnixStream> {
    let path = socket_path(config)?;
    if let Ok(socket) = UnixStream::connect(&path).await {
        check_socket(&path)?;
        ensure!(
            socket.peer_cred()?.uid() == unsafe { libc::geteuid() },
            "mediaBrokerUnavailable"
        );
        return Ok(socket);
    }
    launch(config).await?;
    // A competing launcher can exit successfully after losing the broker lock.
    // Its winner may still be creating the socket; retry only local attachment.
    tokio::time::timeout(Duration::from_secs(4), async {
        loop {
            if let Ok(socket) = UnixStream::connect(&path).await {
                check_socket(&path)?;
                ensure!(
                    socket.peer_cred()?.uid() == unsafe { libc::geteuid() },
                    "mediaBrokerUnavailable"
                );
                return Ok(socket);
            }
            tokio::time::sleep(Duration::from_millis(30)).await;
        }
    })
    .await
    .context("mediaBrokerUnavailable")?
}

pub(super) fn bind_udp(port: u16) -> io::Result<std::net::UdpSocket> {
    std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, port))
}

pub(super) fn configure_udp(socket: &std::net::UdpSocket) -> io::Result<()> {
    use std::os::fd::AsRawFd;
    let size: libc::c_int = 4 * 1024 * 1024;
    unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_RCVBUF,
            (&size as *const libc::c_int).cast(),
            std::mem::size_of_val(&size) as libc::socklen_t,
        );
    }
    Ok(())
}
pub(super) fn fatal_receive_error(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(libc::EBADF | libc::ENOTSOCK))
}
pub(super) fn log_receive_error(port: u16, error: &io::Error, fatal: bool) {
    unsafe {
        libc::syslog(
            libc::LOG_WARNING,
            c"TermPilot media receive: port=%u errno=%d fatal=%d".as_ptr(),
            port as libc::c_uint,
            error.raw_os_error().unwrap_or(0),
            fatal as libc::c_int,
        );
    }
}
#[cfg(test)]
pub(super) async fn pair() -> (UnixStream, UnixStream) {
    UnixStream::pair().unwrap()
}
#[cfg(test)]
pub(super) use libc::{EACCES, EBADF, EHOSTUNREACH, ENETDOWN, ENOBUFS};
