//! Per-user Apple media broker. Only this process binds network UDP ports.
//! Each authenticated local IPC lease owns one remote endpoint and its own
//! bounded packet queue. No passwords, SRTP keys or decoded media enter here.
use crate::ipc;
use anyhow::{bail, ensure, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    io,
    net::{Ipv4Addr, SocketAddr},
    process::Stdio,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader},
    net::UdpSocket,
    process::Command,
    sync::mpsc,
    task::{JoinHandle, JoinSet},
};
use tokio_util::sync::CancellationToken;

#[cfg(unix)]
#[path = "broker/platform_unix.rs"]
mod platform;
#[cfg(windows)]
#[path = "broker/platform_windows.rs"]
mod platform;
pub const TRANSPORT: &str = platform::TRANSPORT;

const VERSION: u32 = 1;
const MAX_PACKET: usize = 16384;
const QUEUE: usize = 512;
const CLOSE: u8 = 255;
const DISCONNECTED: &str = "mediaBrokerDisconnected";

fn unavailable() -> io::Error {
    io::Error::new(io::ErrorKind::BrokenPipe, DISCONNECTED)
}

#[derive(Serialize, Deserialize)]
struct Hello {
    version: u32,
    endpoint: SocketAddr,
    generation: String,
}

#[derive(Clone)]
struct Packet {
    role: u8,
    data: Vec<u8>,
}

async fn read_packet<R: AsyncRead + Unpin>(read: &mut R) -> io::Result<Packet> {
    let role = read.read_u8().await?;
    let size = read.read_u16().await? as usize;
    if !((role < 2 && size <= MAX_PACKET) || (role == CLOSE && size == 0)) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Invalid media IPC packet",
        ));
    }
    let mut data = vec![0; size];
    read.read_exact(&mut data).await?;
    Ok(Packet { role, data })
}

async fn write_packet<W: AsyncWrite + Unpin>(write: &mut W, packet: &Packet) -> io::Result<()> {
    write.write_u8(packet.role).await?;
    write.write_u16(packet.data.len() as u16).await?;
    write.write_all(&packet.data).await
}

#[derive(Default)]
struct Counts {
    received: AtomicU64,
    sent: AtomicU64,
    dropped: AtomicU64,
}

#[derive(Clone)]
struct Route {
    generation: String,
    role: u8,
    tx: mpsc::Sender<Packet>,
    counts: Arc<Counts>,
}

struct Port {
    socket: Arc<UdpSocket>,
    routes: Arc<Mutex<HashMap<SocketAddr, Route>>>,
    stopped: CancellationToken,
    reader: JoinHandle<()>,
}

trait DatagramSource: Send + Sync + 'static {
    fn receive(
        &self,
        bytes: &mut [u8],
    ) -> impl std::future::Future<Output = io::Result<(usize, SocketAddr)>> + Send;
}

impl DatagramSource for UdpSocket {
    async fn receive(&self, bytes: &mut [u8]) -> io::Result<(usize, SocketAddr)> {
        self.recv_from(bytes).await
    }
}

async fn read_datagrams(
    socket: Arc<impl DatagramSource>,
    destinations: Arc<Mutex<HashMap<SocketAddr, Route>>>,
    port: u16,
) {
    let mut bytes = vec![0; 65536];
    let mut consecutive_errors = 0u32;
    loop {
        let (n, remote) = match socket.receive(&mut bytes).await {
            Ok(value) => {
                consecutive_errors = 0;
                value
            }
            Err(error) => {
                consecutive_errors = consecutive_errors.saturating_add(1);
                // A shared unconnected UDP socket can surface an asynchronous
                // network error caused by ANY remote. It must not terminate
                // reception for every other Mac using this local port.
                let fatal = platform::fatal_receive_error(&error);
                if consecutive_errors == 1 || fatal {
                    platform::log_receive_error(port, &error, fatal);
                }
                if fatal {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(
                    (consecutive_errors as u64 * 10).min(100),
                ))
                .await;
                continue;
            }
        };
        let route = destinations.lock().unwrap().get(&remote).cloned();
        if let Some(route) = route {
            if n > MAX_PACKET {
                route.counts.dropped.fetch_add(1, Ordering::Relaxed);
                continue;
            }
            route.counts.received.fetch_add(1, Ordering::Relaxed);
            if route
                .tx
                .try_send(Packet {
                    role: route.role,
                    data: bytes[..n].to_vec(),
                })
                .is_err()
            {
                route.counts.dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
    }
}

impl Drop for Port {
    fn drop(&mut self) {
        self.reader.abort();
    }
}
impl Port {
    fn bind(port: u16) -> Result<Self> {
        let socket = platform::bind_udp(port).map_err(|e| {
            if e.kind() == io::ErrorKind::AddrInUse {
                anyhow::anyhow!("udpPortsInUse")
            } else {
                e.into()
            }
        })?;
        platform::configure_udp(&socket)?;
        socket.set_nonblocking(true)?;
        let socket = Arc::new(UdpSocket::from_std(socket)?);
        Ok(Self::with_receiver(socket.clone(), socket))
    }

    fn with_receiver(socket: Arc<UdpSocket>, receiver: Arc<impl DatagramSource>) -> Self {
        let routes: Arc<Mutex<HashMap<SocketAddr, Route>>> = Arc::default();
        let stopped = CancellationToken::new();
        // Create the guard before spawning so even cancellation before the
        // first poll invalidates leases instead of leaving a silent dead port.
        let stop_on_exit = stopped.clone().drop_guard();
        let destinations = routes.clone();
        let port = socket.local_addr().map(|a| a.port()).unwrap_or(0);
        let reader = tokio::spawn(async move {
            let _stop_on_exit = stop_on_exit;
            read_datagrams(receiver, destinations, port).await;
        });
        Self {
            socket,
            routes,
            stopped,
            reader,
        }
    }
}

#[derive(Default)]
struct State {
    ports: HashMap<u16, Port>,
    sessions: HashMap<SocketAddr, String>,
}

struct Registration {
    state: Arc<Mutex<State>>,
    endpoint: SocketAddr,
    generation: String,
    sockets: [Arc<UdpSocket>; 2],
    reader_stops: [CancellationToken; 2],
    counts: Arc<Counts>,
}
impl Registration {
    fn new(state: Arc<Mutex<State>>, hello: &Hello, tx: mpsc::Sender<Packet>) -> Result<Self> {
        ensure!(
            uuid::Uuid::parse_str(&hello.generation).is_ok(),
            "mediaBrokerVersion"
        );
        ensure!(
            hello.endpoint.is_ipv4() && hello.endpoint.port() > 0 && hello.endpoint.port() < 65535,
            "vncInvalidEndpoint"
        );
        let mut shared = state.lock().unwrap();
        ensure!(
            !shared.sessions.contains_key(&hello.endpoint),
            "screenSessionAlreadyActive"
        );
        for number in hello.endpoint.port()..=hello.endpoint.port() + 1 {
            if let Some(port) = shared.ports.get(&number) {
                ensure!(!port.stopped.is_cancelled(), "mediaBrokerUnavailable");
                ensure!(
                    !port
                        .routes
                        .lock()
                        .unwrap()
                        .contains_key(&SocketAddr::new(hello.endpoint.ip(), number)),
                    "screenSessionAlreadyActive"
                );
            }
        }
        let mut pending = Vec::new();
        for port in hello.endpoint.port()..=hello.endpoint.port() + 1 {
            if !shared.ports.contains_key(&port) {
                pending.push((port, Port::bind(port)?));
            }
        }
        // Insert only after both binds succeed; a failed second bind releases
        // the first port and never affects pre-existing sessions.
        for (number, port) in pending {
            shared.ports.insert(number, port);
        }
        let counts = Arc::new(Counts::default());
        let reader_stops = std::array::from_fn(|role| {
            shared.ports[&(hello.endpoint.port() + role as u16)]
                .stopped
                .clone()
        });
        let sockets = std::array::from_fn(|role| {
            let number = hello.endpoint.port() + role as u16;
            let port = shared.ports.get(&number).unwrap();
            port.routes.lock().unwrap().insert(
                SocketAddr::new(hello.endpoint.ip(), number),
                Route {
                    generation: hello.generation.clone(),
                    role: role as u8,
                    tx: tx.clone(),
                    counts: counts.clone(),
                },
            );
            port.socket.clone()
        });
        shared
            .sessions
            .insert(hello.endpoint, hello.generation.clone());
        drop(shared);
        Ok(Self {
            state,
            endpoint: hello.endpoint,
            generation: hello.generation.clone(),
            sockets,
            reader_stops,
            counts,
        })
    }
}
impl Drop for Registration {
    fn drop(&mut self) {
        let mut state = self.state.lock().unwrap();
        if state.sessions.get(&self.endpoint) != Some(&self.generation) {
            return;
        }
        state.sessions.remove(&self.endpoint);
        for number in self.endpoint.port()..=self.endpoint.port() + 1 {
            if let Some(port) = state.ports.get(&number) {
                let remote = SocketAddr::new(self.endpoint.ip(), number);
                let mut routes = port.routes.lock().unwrap();
                if routes
                    .get(&remote)
                    .is_some_and(|r| r.generation == self.generation)
                {
                    routes.remove(&remote);
                }
            }
        }
        state
            .ports
            .retain(|_, port| !port.routes.lock().unwrap().is_empty());
    }
}

async fn serve_client<S: AsyncRead + AsyncWrite + Unpin + Send + 'static>(
    socket: S,
    state: Arc<Mutex<State>>,
) -> Result<()> {
    let (read, mut write) = tokio::io::split(socket);
    let mut read = BufReader::new(read);
    let hello: Hello = serde_json::from_value(
        tokio::time::timeout(
            Duration::from_secs(5),
            ipc::read_json_limit(&mut read, 1024),
        )
        .await??
        .context("Missing media registration")?,
    )?;
    if hello.version != VERSION {
        ipc::write_json(&mut write, &json!({"error":"mediaBrokerVersion"})).await?;
        return Ok(());
    }
    let (tx, mut rx) = mpsc::channel::<Packet>(QUEUE);
    let registration = match Registration::new(state, &hello, tx) {
        Ok(registration) => registration,
        Err(error) => {
            ipc::write_json(&mut write, &json!({"error":error.to_string()})).await?;
            return Ok(());
        }
    };
    ipc::write_json(
        &mut write,
        &json!({"version":VERSION,"generation":hello.generation,"pid":std::process::id()}),
    )
    .await?;
    // One blocked client writer cannot stall the common UDP reader or another
    // session. These futures are polled together, and drop together on EOF.
    let send = async {
        while let Some(packet) = rx.recv().await {
            write_packet(&mut write, &packet).await?;
        }
        Ok::<(), io::Error>(())
    };
    let receive = async {
        loop {
            let packet = read_packet(&mut read).await?;
            if packet.role == CLOSE {
                return Ok::<(), io::Error>(());
            }
            let remote = SocketAddr::new(
                hello.endpoint.ip(),
                hello.endpoint.port() + packet.role as u16,
            );
            if registration.sockets[packet.role as usize]
                .send_to(&packet.data, remote)
                .await
                .is_ok()
            {
                registration.counts.sent.fetch_add(1, Ordering::Relaxed);
            } else {
                registration.counts.dropped.fetch_add(1, Ordering::Relaxed);
            }
        }
    };
    tokio::select! {
        _ = send => {}, _ = receive => {},
        _ = registration.reader_stops[0].cancelled() => {},
        _ = registration.reader_stops[1].cancelled() => {},
    }
    drop(registration);
    Ok(())
}

pub async fn run() -> Result<()> {
    let config = ipc::read_json_limit(&mut BufReader::new(tokio::io::stdin()), 4096)
        .await?
        .context("Missing media broker configuration")?;
    let result = platform::serve(&config).await;
    if let Err(error) = &result {
        let _ = ipc::write_json(
            &mut tokio::io::stdout(),
            &json!({"error":error.to_string()}),
        )
        .await;
    }
    result
}

async fn launch(config: &Value) -> Result<()> {
    let mut command = Command::new(std::env::current_exe()?);
    command
        .arg("screen-media-broker")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .env_clear()
        .env("PATH", "/usr/bin:/bin:/usr/sbin:/sbin")
        .env("LANG", "en_US.UTF-8");
    #[cfg(unix)]
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() < 0 {
                Err(io::Error::last_os_error())
            } else {
                Ok(())
            }
        });
    }
    #[cfg(windows)]
    {
        command.creation_flags(0x08000000); // CREATE_NO_WINDOW
        if let Some(root) = std::env::var_os("SystemRoot") {
            command.env("SystemRoot", root);
        }
    }
    let mut child = command.spawn().context("mediaBrokerUnavailable")?;
    let mut input = child.stdin.take().context("mediaBrokerUnavailable")?;
    let mut output = BufReader::new(child.stdout.take().context("mediaBrokerUnavailable")?);
    // Reap even if the caller is cancelled while writing startup configuration.
    tokio::spawn(async move {
        let _ = child.wait().await;
    });
    ipc::write_json(
        &mut input,
        &json!({"lockDirectory":config["lockDirectory"]}),
    )
    .await?;
    input.shutdown().await?;
    drop(input);
    let ready = tokio::time::timeout(
        Duration::from_secs(4),
        ipc::read_json_limit(&mut output, 1024),
    )
    .await
    .context("mediaBrokerUnavailable")??;
    if let Some(value) = ready {
        if let Some(error) = value["error"].as_str() {
            bail!(
                "{}",
                if error == "busy" {
                    "legacyScreenSessionActive"
                } else {
                    error
                }
            );
        }
    }
    Ok(())
}

pub struct MediaSocket {
    role: u8,
    tx: mpsc::Sender<Packet>,
    rx: tokio::sync::Mutex<mpsc::Receiver<Vec<u8>>>,
    closed: CancellationToken,
    drops: Arc<AtomicU64>,
}
impl MediaSocket {
    pub async fn send(&self, data: &[u8]) -> io::Result<usize> {
        if data.len() > MAX_PACKET {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Media packet too large",
            ));
        }
        tokio::select! {
            _ = self.closed.cancelled() => Err(unavailable()),
            result = self.tx.send(Packet { role: self.role, data: data.to_vec() }) => {
                result.map_err(|_| unavailable())?; Ok(data.len())
            }
        }
    }
    pub async fn recv(&self, bytes: &mut [u8]) -> io::Result<usize> {
        let mut rx = self.rx.lock().await;
        let data = tokio::select! {
            _ = self.closed.cancelled() => return Err(unavailable()),
            data = rx.recv() => data.ok_or_else(unavailable)?,
        };
        if data.len() > bytes.len() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Media receive buffer too small",
            ));
        }
        bytes[..data.len()].copy_from_slice(&data);
        Ok(data.len())
    }
    pub fn dropped(&self) -> u64 {
        self.drops.load(Ordering::Relaxed)
    }
}

pub struct Client {
    pub control: Arc<MediaSocket>,
    pub video: Arc<MediaSocket>,
    pub closed: CancellationToken,
    pub pid: u32,
    tasks: Vec<JoinHandle<()>>,
}
impl Drop for Client {
    fn drop(&mut self) {
        self.closed.cancel();
        for task in &self.tasks {
            task.abort();
        }
    }
}
impl Client {
    pub async fn close(&self) {
        let _ = tokio::time::timeout(Duration::from_millis(500), async {
            let _ = self
                .control
                .tx
                .send(Packet {
                    role: CLOSE,
                    data: Vec::new(),
                })
                .await;
            self.closed.cancelled().await;
        })
        .await;
    }
}

pub async fn connect(config: &Value, endpoint: SocketAddr) -> Result<Client> {
    let deadline = Instant::now() + Duration::from_secs(1);
    loop {
        let result = match platform::open_socket(config).await {
            Ok(socket) => register(socket, endpoint).await,
            Err(error) => Err(error),
        }
        .map_err(|error| {
            if error.downcast_ref::<io::Error>().is_some_and(|e| {
                matches!(
                    e.kind(),
                    io::ErrorKind::BrokenPipe
                        | io::ErrorKind::UnexpectedEof
                        | io::ErrorKind::ConnectionReset
                )
            }) {
                anyhow::anyhow!("mediaBrokerUnavailable")
            } else {
                error
            }
        });
        match result {
            Err(error)
                if [
                    "screenSessionAlreadyActive",
                    "udpPortsInUse",
                    "mediaBrokerUnavailable",
                ]
                .contains(&error.to_string().as_str())
                    && Instant::now() < deadline =>
            {
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
            result => return result,
        }
    }
}

async fn register<S: AsyncRead + AsyncWrite + Unpin + Send + 'static>(
    socket: S,
    endpoint: SocketAddr,
) -> Result<Client> {
    let hello = Hello {
        version: VERSION,
        endpoint,
        generation: uuid::Uuid::new_v4().to_string(),
    };
    let (read, mut write) = tokio::io::split(socket);
    let mut read = BufReader::new(read);
    ipc::write_json(&mut write, &serde_json::to_value(&hello)?).await?;
    let response = tokio::time::timeout(
        Duration::from_secs(5),
        ipc::read_json_limit(&mut read, 1024),
    )
    .await
    .context("mediaBrokerUnavailable")??
    .context("mediaBrokerUnavailable")?;
    if let Some(error) = response["error"].as_str() {
        bail!("{error}");
    }
    ensure!(
        response["version"].as_u64() == Some(VERSION as u64)
            && response["generation"].as_str() == Some(hello.generation.as_str()),
        "mediaBrokerVersion"
    );
    let pid = response["pid"].as_u64().context("mediaBrokerVersion")? as u32;
    let closed = CancellationToken::new();
    let (tx, mut outgoing) = mpsc::channel::<Packet>(QUEUE);
    let (audio_tx, audio_rx) = mpsc::channel(QUEUE);
    let (video_tx, video_rx) = mpsc::channel(QUEUE);
    let drops = Arc::new(AtomicU64::new(0));
    let make = |role, rx| {
        Arc::new(MediaSocket {
            role,
            tx: tx.clone(),
            rx: tokio::sync::Mutex::new(rx),
            closed: closed.clone(),
            drops: drops.clone(),
        })
    };
    let (control, video) = (make(0, audio_rx), make(1, video_rx));
    let stop = closed.clone();
    let reader = tokio::spawn(async move {
        let work = async {
            loop {
                let packet = read_packet(&mut read).await?;
                if packet.role == CLOSE {
                    break;
                }
                let tx = if packet.role == 0 {
                    &audio_tx
                } else {
                    &video_tx
                };
                if tx.try_send(packet.data).is_err() {
                    drops.fetch_add(1, Ordering::Relaxed);
                }
            }
            Ok::<(), io::Error>(())
        };
        tokio::select! { _ = stop.cancelled() => {}, _ = work => {} }
        stop.cancel();
    });
    let stop = closed.clone();
    let writer = tokio::spawn(async move {
        let work = async {
            while let Some(packet) = outgoing.recv().await {
                write_packet(&mut write, &packet).await?;
            }
            Ok::<(), io::Error>(())
        };
        tokio::select! { _ = stop.cancelled() => {}, _ = work => {} }
        stop.cancel();
    });
    Ok(Client {
        control,
        video,
        closed,
        pid,
        tasks: vec![reader, writer],
    })
}

#[cfg(test)]
mod tests;
