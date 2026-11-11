use super::*;

struct FaultSocket {
    socket: Arc<UdpSocket>,
    faults: tokio::sync::Mutex<mpsc::Receiver<i32>>,
    observed: Arc<AtomicU64>,
}
impl DatagramSource for FaultSocket {
    async fn receive(&self, bytes: &mut [u8]) -> io::Result<(usize, SocketAddr)> {
        let mut faults = self.faults.lock().await;
        tokio::select! {
            Some(errno) = faults.recv() => {
                self.observed.fetch_add(1, Ordering::SeqCst);
                Err(io::Error::from_raw_os_error(errno))
            },
            received = self.socket.recv_from(bytes) => received,
        }
    }
}

fn fault_port(socket: Arc<UdpSocket>) -> (Port, mpsc::Sender<i32>, Arc<AtomicU64>) {
    let (tx, rx) = mpsc::channel(8);
    let observed = Arc::new(AtomicU64::new(0));
    let source = Arc::new(FaultSocket {
        socket: socket.clone(),
        faults: tokio::sync::Mutex::new(rx),
        observed: observed.clone(),
    });
    (Port::with_receiver(socket, source), tx, observed)
}

fn inject_faults(state: &Arc<Mutex<State>>, number: u16) -> (mpsc::Sender<i32>, Arc<AtomicU64>) {
    let mut state = state.lock().unwrap();
    let old = state.ports.remove(&number).unwrap();
    assert!(old.routes.lock().unwrap().is_empty());
    let socket = old.socket.clone();
    drop(old);
    let (replacement, tx, observed) = fault_port(socket);
    state.ports.insert(number, replacement);
    (tx, observed)
}

async fn wait_faults(observed: &AtomicU64, count: u64) {
    tokio::time::timeout(Duration::from_secs(2), async {
        while observed.load(Ordering::SeqCst) < count {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn initial_network_error_does_not_silence_two_routes_on_one_port() {
    let socket = Arc::new(UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap());
    let (port, faults, observed) = fault_port(socket.clone());
    let mut outputs = Vec::new();
    for tag in [b'A', b'B'] {
        let remote = UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let (tx, rx) = mpsc::channel(2);
        port.routes.lock().unwrap().insert(
            remote.local_addr().unwrap(),
            Route {
                generation: uuid::Uuid::new_v4().to_string(),
                role: 1,
                tx,
                counts: Arc::default(),
            },
        );
        outputs.push((tag, remote, rx));
    }
    faults.send(platform::EHOSTUNREACH).await.unwrap();
    wait_faults(&observed, 1).await;
    for (tag, remote, _) in &outputs {
        remote
            .send_to(&[*tag], socket.local_addr().unwrap())
            .await
            .unwrap();
    }
    for (tag, _, mut rx) in outputs {
        let packet = tokio::time::timeout(Duration::from_secs(2), rx.recv())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(packet.data, vec![tag]);
    }
    assert!(!port.stopped.is_cancelled());
    assert!(!port.reader.is_finished());
}

#[tokio::test]
async fn asynchronous_network_errors_keep_registered_media_channels_alive() {
    let (p, remote) = remote_pair();
    let state = state_with_ports(&[p]);
    let (faults, observed) = inject_faults(&state, p);
    let (active, task) = client(state.clone(), p).await;
    exchange(&active, &remote, b"before-error").await;
    for (index, errno) in [
        platform::ENETDOWN,
        platform::EHOSTUNREACH,
        platform::EACCES,
        platform::ENOBUFS,
    ]
    .into_iter()
    .enumerate()
    {
        faults.send(errno).await.unwrap();
        wait_faults(&observed, index as u64 + 1).await;
        exchange(&active, &remote, b"after-transient-error").await;
        assert!(!active.closed.is_cancelled());
    }
    active.close().await;
    task.await.unwrap().unwrap();
}

#[tokio::test]
async fn fatal_reader_failure_closes_its_lease_without_silencing_unaffected_ports() {
    let (p, a) = remote_pair();
    let (q, b) = remote_pair();
    let state = state_with_ports(&[p, q]);
    let (faults, _) = inject_faults(&state, p);
    let (first, task_a) = client(state.clone(), p).await;
    let (second, task_b) = client(state.clone(), q).await;
    exchange(&first, &a, b"A-before-fatal-error").await;
    faults.send(platform::EBADF).await.unwrap();
    tokio::time::timeout(Duration::from_secs(2), first.closed.cancelled())
        .await
        .unwrap();
    task_a.await.unwrap().unwrap();
    assert!(!state.lock().unwrap().ports.contains_key(&p));
    exchange(&second, &b, b"B-still-live").await;
    second.close().await;
    task_b.await.unwrap().unwrap();
}

#[tokio::test]
async fn unexpected_reader_task_exit_notifies_lease_instead_of_leaving_dead_socket() {
    let (p, remote) = remote_pair();
    let state = state_with_ports(&[p]);
    let (active, task) = client(state.clone(), p).await;
    exchange(&active, &remote, b"before-task-exit").await;
    state.lock().unwrap().ports[&p].reader.abort();
    tokio::time::timeout(Duration::from_secs(2), active.closed.cancelled())
        .await
        .unwrap();
    task.await.unwrap().unwrap();
    assert!(state.lock().unwrap().ports.is_empty());
}

fn hello(port: u16) -> Hello {
    Hello {
        version: VERSION,
        endpoint: SocketAddr::from(([127, 0, 0, 1], port)),
        generation: uuid::Uuid::new_v4().to_string(),
    }
}

fn remote_pair() -> (u16, [UdpSocket; 2]) {
    for _ in 0..100 {
        let first = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, 0)).unwrap();
        let port = first.local_addr().unwrap().port();
        if port == 65535 {
            continue;
        }
        if let Ok(second) = std::net::UdpSocket::bind((Ipv4Addr::LOCALHOST, port + 1)) {
            first.set_nonblocking(true).unwrap();
            second.set_nonblocking(true).unwrap();
            return (
                port,
                [
                    UdpSocket::from_std(first).unwrap(),
                    UdpSocket::from_std(second).unwrap(),
                ],
            );
        }
    }
    panic!("No fixture UDP pair");
}

fn state_with_ports(ports: &[u16]) -> Arc<Mutex<State>> {
    let mut state = State::default();
    // Keep real loopback servers on their expected remote ports. Test broker
    // sockets use independent local ports; production binds are covered below
    // and by the two explicitly authorized live Macs.
    for base in ports {
        for port in *base..=*base + 1 {
            state.ports.insert(port, Port::bind(0).unwrap());
        }
    }
    Arc::new(Mutex::new(state))
}

async fn client(state: Arc<Mutex<State>>, port: u16) -> (Client, JoinHandle<Result<()>>) {
    let (a, b) = platform::pair().await;
    let server = tokio::spawn(serve_client(b, state));
    (register(a, hello(port).endpoint).await.unwrap(), server)
}

async fn exchange(client: &Client, remote: &[UdpSocket; 2], tag: &[u8]) {
    for (role, socket) in [&client.control, &client.video].into_iter().enumerate() {
        socket.send(tag).await.unwrap();
        let mut bytes = [0; 256];
        let (n, source) =
            tokio::time::timeout(Duration::from_secs(2), remote[role].recv_from(&mut bytes))
                .await
                .unwrap()
                .unwrap();
        assert_eq!(&bytes[..n], tag);
        remote[role].send_to(tag, source).await.unwrap();
        let n = tokio::time::timeout(Duration::from_secs(2), socket.recv(&mut bytes))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(&bytes[..n], tag);
    }
}

#[tokio::test]
async fn routes_two_sessions_both_directions_and_releases_one_lease() {
    let (p, a) = remote_pair();
    let (q, b) = remote_pair();
    let state = state_with_ports(&[p, q]);
    let (first, task_a) = client(state.clone(), p).await;
    let (second, task_b) = client(state.clone(), q).await;
    exchange(&first, &a, b"session-A").await;
    exchange(&second, &b, b"session-B").await;
    first.close().await;
    task_a.await.unwrap().unwrap();
    assert_eq!(state.lock().unwrap().sessions.len(), 1);
    exchange(&second, &b, b"B-after-A-closed").await;
    second.close().await;
    task_b.await.unwrap().unwrap();
    assert!(state.lock().unwrap().sessions.is_empty());
    assert!(state.lock().unwrap().ports.is_empty());
}

// Windows supports binding another 127/8 address without configuring aliases.
// macOS only exposes 127.0.0.1 by default; its live two-Mac test covers this path.
#[cfg(windows)]
#[tokio::test]
async fn two_remote_ips_share_both_ports_without_cross_delivery() {
    let (p, a) = remote_pair();
    let ip = Ipv4Addr::new(127, 0, 0, 2);
    let b = [
        UdpSocket::bind((ip, p)).await.unwrap(),
        UdpSocket::bind((ip, p + 1)).await.unwrap(),
    ];
    let state = state_with_ports(&[p]);
    let (first, task_a) = client(state.clone(), p).await;
    let (pipe, server) = platform::pair().await;
    let task_b = tokio::spawn(serve_client(server, state.clone()));
    let second = register(pipe, SocketAddr::from((ip, p))).await.unwrap();
    assert_eq!(state.lock().unwrap().ports.len(), 2);
    for port in state.lock().unwrap().ports.values() {
        assert_eq!(port.routes.lock().unwrap().len(), 2);
    }
    // Simultaneous, distinct payloads travel through two real IPC connections
    // and the same pair of UDP sockets; neither client may receive the other's.
    tokio::join!(
        exchange(&first, &a, b"A-shared"),
        exchange(&second, &b, b"B-shared")
    );
    first.close().await;
    task_a.await.unwrap().unwrap();
    assert_eq!(state.lock().unwrap().ports.len(), 2);
    exchange(&second, &b, b"B-after-A-close").await;
    second.close().await;
    task_b.await.unwrap().unwrap();
    assert!(state.lock().unwrap().ports.is_empty());
}

#[tokio::test]
async fn duplicate_target_rejected_without_disturbing_active_session() {
    let (p, remote) = remote_pair();
    let state = state_with_ports(&[p]);
    let (active, task) = client(state.clone(), p).await;
    let (a, b) = platform::pair().await;
    let duplicate = tokio::spawn(serve_client(b, state.clone()));
    assert_eq!(
        register(a, hello(p).endpoint)
            .await
            .err()
            .unwrap()
            .to_string(),
        "screenSessionAlreadyActive"
    );
    duplicate.await.unwrap().unwrap();
    exchange(&active, &remote, b"still-owned-by-original").await;
    active.close().await;
    task.await.unwrap().unwrap();
}

#[tokio::test]
async fn overlapping_remote_media_endpoint_is_rejected() {
    let (p, _remote) = remote_pair();
    let state = state_with_ports(&[p]);
    let (active, task) = client(state.clone(), p).await;
    let (tx, _rx) = mpsc::channel(1);
    assert_eq!(
        Registration::new(state.clone(), &hello(p + 1), tx)
            .err()
            .unwrap()
            .to_string(),
        "screenSessionAlreadyActive"
    );
    active.close().await;
    task.await.unwrap().unwrap();
}

#[tokio::test]
async fn crashed_worker_eof_removes_only_its_routes() {
    let (p, a) = remote_pair();
    let (q, b) = remote_pair();
    let state = state_with_ports(&[p, q]);
    let (first, task_a) = client(state.clone(), p).await;
    let (second, task_b) = client(state.clone(), q).await;
    exchange(&first, &a, b"before-drop").await;
    drop(first);
    tokio::time::timeout(Duration::from_secs(2), task_a)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert_eq!(state.lock().unwrap().sessions.len(), 1);
    exchange(&second, &b, b"survives-worker-death").await;
    second.close().await;
    task_b.await.unwrap().unwrap();
}

#[tokio::test]
async fn broker_connection_loss_notifies_both_media_receivers() {
    let (p, _remote) = remote_pair();
    let state = state_with_ports(&[p]);
    let (client, server) = client(state.clone(), p).await;
    server.abort();
    let _ = server.await;
    tokio::time::timeout(Duration::from_secs(2), client.closed.cancelled())
        .await
        .unwrap();
    for socket in [&client.control, &client.video] {
        assert_eq!(
            socket.recv(&mut [0; 32]).await.unwrap_err().to_string(),
            DISCONNECTED
        );
        assert_eq!(
            socket.send(b"x").await.unwrap_err().to_string(),
            DISCONNECTED
        );
    }
    assert!(state.lock().unwrap().sessions.is_empty());
}

#[tokio::test]
async fn full_slow_client_queue_does_not_block_another_client() {
    let (p, _a) = remote_pair();
    let (q, b) = remote_pair();
    let state = state_with_ports(&[p, q]);
    let (slow, _slow_rx) = mpsc::channel(1);
    let registration = Registration::new(state.clone(), &hello(p), slow).unwrap();
    let route = state.lock().unwrap().ports[&p].routes.lock().unwrap()[&hello(p).endpoint].clone();
    route
        .tx
        .try_send(Packet {
            role: 0,
            data: vec![1; MAX_PACKET],
        })
        .unwrap();
    assert!(route
        .tx
        .try_send(Packet {
            role: 0,
            data: vec![2; MAX_PACKET]
        })
        .is_err());
    let (healthy, task) = client(state.clone(), q).await;
    exchange(&healthy, &b, b"not-blocked").await;
    healthy.close().await;
    task.await.unwrap().unwrap();
    drop(registration);
}

#[tokio::test]
async fn failed_second_bind_rolls_back_first_without_leaking_ports() {
    let (p, remote) = remote_pair();
    let [first, occupied] = remote;
    drop(first);
    let state = Arc::new(Mutex::new(State::default()));
    let (tx, _rx) = mpsc::channel(1);
    assert_eq!(
        Registration::new(state.clone(), &hello(p), tx)
            .err()
            .unwrap()
            .to_string(),
        "udpPortsInUse"
    );
    assert!(state.lock().unwrap().ports.is_empty());
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            if std::net::UdpSocket::bind((Ipv4Addr::UNSPECIFIED, p)).is_ok() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap();
    drop(occupied);
}

#[tokio::test]
async fn protocol_version_mismatch_never_registers_or_binds() {
    let (mut a, b) = platform::pair().await;
    let state = Arc::new(Mutex::new(State::default()));
    let task = tokio::spawn(serve_client(b, state.clone()));
    let mut h = hello(5900);
    h.version = 99;
    ipc::write_json(&mut a, &serde_json::to_value(h).unwrap())
        .await
        .unwrap();
    let reply = ipc::read_json_limit(&mut BufReader::new(a), 1024)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(reply["error"], "mediaBrokerVersion");
    task.await.unwrap().unwrap();
    assert!(state.lock().unwrap().sessions.is_empty());
    assert!(state.lock().unwrap().ports.is_empty());
}

#[tokio::test]
async fn malformed_media_frame_closes_lease_and_releases_routes() {
    let (p, _remote) = remote_pair();
    let state = state_with_ports(&[p]);
    let (a, b) = platform::pair().await;
    let task = tokio::spawn(serve_client(b, state.clone()));
    let (read, mut write) = tokio::io::split(a);
    ipc::write_json(&mut write, &serde_json::to_value(hello(p)).unwrap())
        .await
        .unwrap();
    let _ = ipc::read_json_limit(&mut BufReader::new(read), 1024)
        .await
        .unwrap();
    write.write_all(&[3, 0, 0]).await.unwrap();
    tokio::time::timeout(Duration::from_secs(2), task)
        .await
        .unwrap()
        .unwrap()
        .unwrap();
    assert!(state.lock().unwrap().sessions.is_empty());
}

#[cfg(unix)]
#[test]
fn unsafe_directory_permissions_and_symlink_are_rejected() {
    use platform::private_directory;
    use std::os::unix::fs::PermissionsExt;
    let root = std::env::temp_dir().join(format!("tp-media-{}", uuid::Uuid::new_v4()));
    private_directory(&root).unwrap();
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o755)).unwrap();
    assert!(private_directory(&root).is_err());
    std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o700)).unwrap();
    let link = root.with_extension("link");
    std::os::unix::fs::symlink(&root, &link).unwrap();
    assert!(private_directory(&link).is_err());
    std::fs::remove_file(link).unwrap();
    std::fs::remove_dir(root).unwrap();
}
