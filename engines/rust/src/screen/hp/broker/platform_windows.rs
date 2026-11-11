//! Windows transport for the shared media broker. Pipes are local-only and
//! restricted to the current user; both ends verify the peer's token owner.
use super::*;
use std::{
    ffi::{CStr, CString},
    os::windows::io::{AsRawHandle, AsRawSocket},
    ptr,
};
use tokio::net::windows::named_pipe::{
    ClientOptions, NamedPipeClient, NamedPipeServer, ServerOptions,
};
use windows_sys::Win32::{
    Foundation::{
        CloseHandle, LocalFree, ERROR_ACCESS_DENIED, ERROR_BROKEN_PIPE, ERROR_NO_DATA,
        ERROR_PIPE_BUSY, ERROR_PIPE_NOT_CONNECTED, HANDLE,
    },
    Networking::WinSock::*,
    Security::{
        Authorization::*, GetTokenInformation, TokenUser, SECURITY_ATTRIBUTES, TOKEN_QUERY,
        TOKEN_USER,
    },
    System::{Diagnostics::Debug::OutputDebugStringA, Pipes::*, Threading::*},
};

pub(super) const TRANSPORT: &str = "namedPipe";

struct Handle(HANDLE);
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe {
            CloseHandle(self.0);
        }
    }
}

fn process_sid(process: HANDLE) -> Result<String> {
    unsafe {
        let mut token = ptr::null_mut();
        ensure!(
            OpenProcessToken(process, TOKEN_QUERY, &mut token) != 0,
            "mediaBrokerUnavailable"
        );
        let token = Handle(token);
        let mut length = 0;
        GetTokenInformation(token.0, TokenUser, ptr::null_mut(), 0, &mut length);
        ensure!(length > 0 && length <= 65536, "mediaBrokerUnavailable");
        // TOKEN_USER contains pointers, so use aligned storage, not Vec<u8>.
        let mut bytes = vec![0usize; (length as usize).div_ceil(std::mem::size_of::<usize>())];
        ensure!(
            GetTokenInformation(
                token.0,
                TokenUser,
                bytes.as_mut_ptr().cast(),
                length,
                &mut length
            ) != 0,
            "mediaBrokerUnavailable"
        );
        let user = &*bytes.as_ptr().cast::<TOKEN_USER>();
        let mut text = ptr::null_mut();
        ensure!(
            ConvertSidToStringSidA(user.User.Sid, &mut text) != 0,
            "mediaBrokerUnavailable"
        );
        let sid = CStr::from_ptr(text.cast()).to_string_lossy().into_owned();
        LocalFree(text.cast());
        Ok(sid)
    }
}

fn current_sid() -> Result<String> {
    process_sid(unsafe { GetCurrentProcess() })
}

fn verify_peer(pipe: HANDLE, server_peer: bool, expected: &str) -> Result<()> {
    let mut pid = 0;
    let valid = unsafe {
        if server_peer {
            GetNamedPipeServerProcessId(pipe, &mut pid)
        } else {
            GetNamedPipeClientProcessId(pipe, &mut pid)
        }
    };
    ensure!(valid != 0 && pid != 0, "mediaBrokerUnavailable");
    let process = Handle(unsafe { OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) });
    ensure!(!process.0.is_null(), "mediaBrokerUnavailable");
    ensure!(
        process_sid(process.0)? == expected,
        "mediaBrokerUnavailable"
    );
    Ok(())
}

fn pipe_name(config: &Value, sid: &str) -> Result<String> {
    let directory = super::super::file_fs::absolute(ipc::text(config, "lockDirectory"))?;
    std::fs::create_dir_all(&directory)?;
    let _guard = super::super::file_fs::open_source(&directory)?;
    let canonical = std::fs::canonicalize(directory)?;
    let digest = hex::encode(Sha256::digest(
        canonical.to_string_lossy().to_lowercase().as_bytes(),
    ));
    Ok(format!(
        r"\\.\pipe\TermPilot-Media-{sid}-{}-v1",
        &digest[..32]
    ))
}

fn create_pipe(name: &str, sid: &str, first: bool) -> io::Result<NamedPipeServer> {
    let sddl = CString::new(format!("D:P(A;;GA;;;{sid})")).unwrap();
    unsafe {
        let mut descriptor = ptr::null_mut();
        if ConvertStringSecurityDescriptorToSecurityDescriptorA(
            sddl.as_ptr().cast(),
            1,
            &mut descriptor,
            ptr::null_mut(),
        ) == 0
        {
            return Err(io::Error::last_os_error());
        }
        let mut attributes = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor,
            bInheritHandle: 0,
        };
        let result = ServerOptions::new()
            .first_pipe_instance(first)
            .reject_remote_clients(true)
            .in_buffer_size(65536)
            .out_buffer_size(65536)
            .create_with_security_attributes_raw(
                name,
                (&mut attributes as *mut SECURITY_ATTRIBUTES).cast(),
            );
        LocalFree(descriptor);
        result
    }
}

async fn accept_pipe(
    listener: &mut NamedPipeServer,
    name: &str,
    sid: &str,
) -> Result<Option<NamedPipeServer>> {
    let connected = listener.connect().await;
    // Replace before dropping the old instance to preserve startup ownership.
    let next = create_pipe(name, sid, false)?;
    let socket = std::mem::replace(listener, next);
    if let Err(error) = connected {
        if matches!(error.raw_os_error(), Some(code) if [ERROR_NO_DATA, ERROR_PIPE_NOT_CONNECTED, ERROR_BROKEN_PIPE].contains(&(code as u32)))
        {
            // A client cancelled between CreateFile and ConnectNamedPipe.
            // Its cancellation must not terminate every existing Mac session.
            return Ok(None);
        }
        return Err(error.into());
    }
    Ok(verify_peer(socket.as_raw_handle(), false, sid)
        .ok()
        .map(|_| socket))
}

pub(super) async fn serve(config: &Value) -> Result<()> {
    let sid = current_sid()?;
    let name = pipe_name(config, &sid)?;
    // Atomic first-instance creation elects the startup winner. Keep a pending
    // instance alive throughout accept, so competing launchers cannot take over.
    let mut listener = match create_pipe(&name, &sid, true) {
        Ok(pipe) => pipe,
        Err(error) if matches!(error.raw_os_error(), Some(code) if code == ERROR_ACCESS_DENIED as i32 || code == ERROR_PIPE_BUSY as i32) => {
            return Ok(())
        }
        Err(error) => return Err(error.into()),
    };
    let _legacy_lock = super::super::lock(config).await?;
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
            accepted = accept_pipe(&mut listener, &name, &sid) => {
                if let Some(socket) = accepted? {
                    let state = state.clone();
                    clients.spawn(async move { let _ = serve_client(socket, state).await; });
                }
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

pub(super) async fn open_socket(config: &Value) -> Result<NamedPipeClient> {
    let sid = current_sid()?;
    let name = pipe_name(config, &sid)?;
    if let Ok(socket) = ClientOptions::new().open(&name) {
        verify_peer(socket.as_raw_handle(), true, &sid)?;
        return Ok(socket);
    }
    launch(config).await?;
    tokio::time::timeout(Duration::from_secs(4), async {
        loop {
            if let Ok(socket) = ClientOptions::new().open(&name) {
                verify_peer(socket.as_raw_handle(), true, &sid)?;
                return Ok(socket);
            }
            tokio::time::sleep(Duration::from_millis(30)).await;
        }
    })
    .await
    .context("mediaBrokerUnavailable")?
}

pub(super) fn bind_udp(port: u16) -> io::Result<std::net::UdpSocket> {
    let socket = socket2::Socket::new(
        socket2::Domain::IPV4,
        socket2::Type::DGRAM,
        Some(socket2::Protocol::UDP),
    )?;
    let exclusive: i32 = 1;
    // Windows otherwise permits a same-user specific-address bind to shadow a
    // wildcard socket, including ephemeral ports allocated by parallel tests.
    // Exclusivity must be enabled BEFORE bind, not after std::UdpSocket::bind.
    if unsafe {
        setsockopt(
            socket.as_raw_socket() as SOCKET,
            SOL_SOCKET,
            SO_EXCLUSIVEADDRUSE,
            (&exclusive as *const i32).cast(),
            4,
        )
    } == SOCKET_ERROR
    {
        return Err(io::Error::from_raw_os_error(unsafe { WSAGetLastError() }));
    }
    socket.bind(&SocketAddr::from((Ipv4Addr::UNSPECIFIED, port)).into())?;
    Ok(socket.into())
}

pub(super) fn configure_udp(socket: &std::net::UdpSocket) -> io::Result<()> {
    let socket = socket.as_raw_socket() as SOCKET;
    let size: i32 = 4 * 1024 * 1024;
    unsafe {
        setsockopt(
            socket,
            SOL_SOCKET,
            SO_RCVBUF,
            (&size as *const i32).cast(),
            4,
        );
        // A port-unreachable from one Mac must not poison the common receiver.
        let enabled: u32 = 0;
        let mut returned = 0;
        if WSAIoctl(
            socket,
            SIO_UDP_CONNRESET,
            (&enabled as *const u32).cast(),
            4,
            ptr::null_mut(),
            0,
            &mut returned,
            ptr::null_mut(),
            None,
        ) == SOCKET_ERROR
        {
            return Err(io::Error::from_raw_os_error(WSAGetLastError()));
        }
    }
    Ok(())
}
pub(super) fn fatal_receive_error(error: &io::Error) -> bool {
    matches!(error.raw_os_error(), Some(WSAEBADF | WSAENOTSOCK))
}
pub(super) fn log_receive_error(port: u16, error: &io::Error, fatal: bool) {
    let message = CString::new(format!(
        "TermPilot media receive: port={port} errno={} fatal={fatal}\n",
        error.raw_os_error().unwrap_or(0)
    ))
    .unwrap();
    unsafe {
        OutputDebugStringA(message.as_ptr().cast());
    }
}

#[cfg(test)]
pub(super) async fn pair() -> (NamedPipeClient, NamedPipeServer) {
    let sid = current_sid().unwrap();
    let name = format!(r"\\.\pipe\TermPilot-Media-Test-{}", uuid::Uuid::new_v4());
    let server = create_pipe(&name, &sid, true).unwrap();
    let client = ClientOptions::new().open(&name).unwrap();
    server.connect().await.unwrap();
    verify_peer(server.as_raw_handle(), false, &sid).unwrap();
    verify_peer(client.as_raw_handle(), true, &sid).unwrap();
    (client, server)
}
#[cfg(test)]
pub(super) use windows_sys::Win32::Networking::WinSock::{
    WSAEACCES as EACCES, WSAEBADF as EBADF, WSAEHOSTUNREACH as EHOSTUNREACH,
    WSAENETDOWN as ENETDOWN, WSAENOBUFS as ENOBUFS,
};

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn udp_port_cannot_be_shadowed_by_specific_address_bind() {
        let port = Port::bind(0).unwrap();
        let number = port.socket.local_addr().unwrap().port();
        assert!(std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, number)).is_err());
        assert!(std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, number)).is_err());
    }
    #[tokio::test]
    async fn cancelled_pipe_client_does_not_stop_accepting_sessions() {
        let sid = current_sid().unwrap();
        let name = format!(r"\\.\pipe\TermPilot-Media-Test-{}", uuid::Uuid::new_v4());
        let mut listener = create_pipe(&name, &sid, true).unwrap();
        drop(ClientOptions::new().open(&name).unwrap());
        // Windows may report an early disconnect or a connected pipe at EOF.
        drop(accept_pipe(&mut listener, &name, &sid).await.unwrap());
        let mut client = ClientOptions::new().open(&name).unwrap();
        let mut server = accept_pipe(&mut listener, &name, &sid)
            .await
            .unwrap()
            .unwrap();
        client.write_all(b"live").await.unwrap();
        let mut bytes = [0; 4];
        server.read_exact(&mut bytes).await.unwrap();
        assert_eq!(&bytes, b"live");
        assert!(create_pipe(&name, &sid, true).is_err());
    }
    #[tokio::test]
    async fn named_pipe_startup_has_one_winner_and_checks_peer_identity() {
        let sid = current_sid().unwrap();
        let name = format!(r"\\.\pipe\TermPilot-Media-Test-{}", uuid::Uuid::new_v4());
        let server = create_pipe(&name, &sid, true).unwrap();
        assert!(create_pipe(&name, &sid, true).is_err());
        let client = ClientOptions::new().open(&name).unwrap();
        server.connect().await.unwrap();
        verify_peer(client.as_raw_handle(), true, &sid).unwrap();
        assert!(verify_peer(client.as_raw_handle(), true, "S-1-0-0").is_err());
        assert!(verify_peer(server.as_raw_handle(), false, "S-1-0-0").is_err());
    }
    #[tokio::test]
    async fn named_pipe_dacl_excludes_a_different_user() {
        let name = format!(r"\\.\pipe\TermPilot-Media-Test-{}", uuid::Uuid::new_v4());
        let _server = create_pipe(&name, "S-1-0-0", true).unwrap();
        assert_eq!(
            ClientOptions::new().open(&name).unwrap_err().raw_os_error(),
            Some(ERROR_ACCESS_DENIED as i32)
        );
    }
}
