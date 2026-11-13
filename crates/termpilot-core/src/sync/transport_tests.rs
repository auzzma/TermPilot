use super::*;
use std::{
    net::{TcpListener, TcpStream},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc, Mutex,
    },
    thread,
};
#[derive(Default)]
struct MockState {
    files: BTreeMap<String, Vec<u8>>,
    requests: Vec<(String, String, BTreeMap<String, String>)>,
    reject: bool,
    reject_write: bool,
    page_size: usize,
    race: bool,
    ignore_conditions: bool,
    weak_etags: bool,
}
struct Mock {
    url: String,
    state: Arc<Mutex<MockState>>,
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Mock {
    fn new(kind: &str) -> Self {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        listener.set_nonblocking(true).unwrap();
        let state = Arc::new(Mutex::new(MockState::default()));
        let stop = Arc::new(AtomicBool::new(false));
        let server_state = state.clone();
        let server_stop = stop.clone();
        let kind = kind.to_owned();
        let thread = thread::spawn(move || {
            while !server_stop.load(Ordering::Relaxed) {
                match listener.accept() {
                    Ok((mut stream, _)) => {
                        let _ = stream.set_nonblocking(false);
                        let _ = stream.set_read_timeout(Some(Duration::from_secs(2)));
                        let _ = serve(&mut stream, &kind, &server_state);
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(2))
                    }
                    Err(_) => break,
                }
            }
        });
        Self {
            url: format!("http://{address}"),
            state,
            stop,
            thread: Some(thread),
        }
    }
}
impl Drop for Mock {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            thread.join().unwrap();
        }
    }
}
fn serve(stream: &mut TcpStream, kind: &str, state: &Mutex<MockState>) -> std::io::Result<()> {
    let mut bytes = Vec::new();
    let mut buffer = [0; 4096];
    let header_end = loop {
        let n = stream.read(&mut buffer)?;
        if n == 0 {
            return Ok(());
        }
        bytes.extend_from_slice(&buffer[..n]);
        if let Some(end) = bytes.windows(4).position(|v| v == b"\r\n\r\n") {
            break end + 4;
        }
    };
    let header = String::from_utf8_lossy(&bytes[..header_end]).into_owned();
    let mut lines = header.lines();
    let first = lines.next().unwrap();
    let mut first = first.split_whitespace();
    let method = first.next().unwrap().to_owned();
    let path = first.next().unwrap().to_owned();
    let headers: BTreeMap<_, _> = lines
        .filter_map(|line| {
            line.split_once(':')
                .map(|(k, v)| (k.to_ascii_lowercase(), v.trim().to_owned()))
        })
        .collect();
    let length = headers
        .get("content-length")
        .and_then(|s| s.parse::<usize>().ok())
        .unwrap_or(0);
    while bytes.len() < header_end + length {
        let n = stream.read(&mut buffer)?;
        if n == 0 {
            return Ok(());
        }
        bytes.extend_from_slice(&buffer[..n]);
    }
    let body = &bytes[header_end..header_end + length];
    let url = Url::parse(&format!("http://mock{path}")).unwrap();
    let path = url.path();
    let mut state = state.lock().unwrap();
    state
        .requests
        .push((method.clone(), path.into(), headers.clone()));
    if state.reject_write && method == "PUT" {
        return respond(stream, 503, b"{}");
    }
    if state.reject {
        return respond(stream, 401, b"{}");
    }
    if kind == "webdavDigest" && !headers.contains_key("authorization") {
        return stream.write_all(b"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Digest realm=\"fixture\", nonce=\"test-nonce\", qop=\"auth\", algorithm=SHA-256\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
    }
    if kind == "webdavDigest" {
        assert!(headers["authorization"].starts_with("Digest "));
        assert!(headers["authorization"].contains("algorithm=SHA-256"));
        assert!(!headers["authorization"].contains("secret"));
    }
    if kind == "webdavToken" {
        assert_eq!(headers["authorization"], "Bearer fixture-token");
    }
    let name = if kind.starts_with("webdav") {
        path.strip_prefix("/objects/").unwrap_or_else(||path.rsplit('/').next().unwrap_or(""))
    } else { path.rsplit('/').next().unwrap_or("") };
    if method == "PUT" && !state.ignore_conditions {
        let tag = state
            .files
            .get(name)
            .map(|bytes| format!("\"{}\"", hex::encode(Sha256::digest(bytes))));
        if (headers.get("if-none-match").map(String::as_str) == Some("*") && tag.is_some())
            || headers
                .get("if-match")
                .is_some_and(|expected| Some(expected) != tag.as_ref())
        {
            return respond(stream, 412, b"");
        }
    }
    let mut status = 200;
    let output = match kind {
        "webdav" | "webdavDigest" | "webdavToken" => match method.as_str() {
            "MKCOL" => { status=201; vec![] },
            "PROPFIND" => {
                status = 207;
                format!(
                    "<d:multistatus xmlns:d=\"DAV:\">{}</d:multistatus>",
                    state
                        .files
                        .keys()
                        .map(|name| format!(
                            "<d:response><d:href>/objects/{name}</d:href></d:response>"
                        ))
                        .collect::<String>()
                )
                .into_bytes()
            }
            "DELETE" => { state.files.remove(name); status=204; vec![] },
            "PUT" => {
                state.files.insert(name.into(), body.into());
                status = 201;
                vec![]
            }
            _ => state.files.get(name).cloned().unwrap_or_else(|| {
                status = 404;
                vec![]
            }),
        },
        "s3" | "r2" => {
            assert!(headers
                .get("authorization")
                .is_some_and(|s| s.starts_with("AWS4-HMAC-SHA256 Credential=access/")));
            if kind == "r2" {
                assert!(headers["authorization"].contains("/auto/s3/aws4_request"));
                assert!(!headers.contains_key("x-amz-acl"));
                assert!(!headers.contains_key("x-amz-security-token"));
            }
            assert_eq!(
                headers.get("x-amz-content-sha256"),
                Some(&hex::encode(Sha256::digest(body)))
            );
            if url.query_pairs().any(|(k, _)| k == "list-type") {
                assert_eq!(path, "/bucket");
                let start = url
                    .query_pairs()
                    .find(|(k, _)| k == "continuation-token")
                    .map(|(_, v)| v.parse::<usize>().unwrap())
                    .unwrap_or(0);
                let size = if state.page_size == 0 {
                    usize::MAX
                } else {
                    state.page_size
                };
                let files: Vec<_> = state.files.keys().skip(start).take(size).collect();
                let next = start + files.len();
                let truncated = next < state.files.len();
                format!("<ListBucketResult><IsTruncated>{truncated}</IsTruncated>{}{}</ListBucketResult>",
                    files.iter().map(|name| format!("<Contents><Key>prefix/{name}</Key></Contents>")).collect::<String>(),
                    if truncated {format!("<NextContinuationToken>{next}</NextContinuationToken>")} else {String::new()}
                ).into_bytes()
            } else if method == "DELETE" {
                state.files.remove(name);status=204;vec![]
            } else if method == "PUT" {
                assert!(headers.contains_key("if-none-match") || headers.contains_key("if-match"));
                if state.race {
                    state
                        .files
                        .insert(name.into(), b"competing object".to_vec());
                    status = 412;
                } else {
                    state.files.insert(name.into(), body.into());
                    status = 200;
                }
                vec![]
            } else {
                state.files.get(name).cloned().unwrap_or_else(|| {
                    status = 404;
                    vec![]
                })
            }
        }
        _ => unreachable!(),
    };
    if method == "GET" && status == 200 && state.files.contains_key(name) {
        let tag = format!(
            "{}\"{}\"",
            if state.weak_etags { "W/" } else { "" },
            hex::encode(Sha256::digest(&output))
        );
        write!(
            stream,
            "HTTP/1.1 200 OK\r\nETag: {tag}\r\nDate: Fri, 09 Oct 2026 00:00:00 GMT\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            output.len()
        )?;
        stream.write_all(&output)
    } else {
        respond(stream, status, &output)
    }
}
fn respond(stream: &mut TcpStream, status: u16, body: &[u8]) -> std::io::Result<()> {
    write!(stream,"HTTP/1.1 {status} Test\r\nContent-Length: {}\r\nContent-Type: application/json\r\nDate: Fri, 09 Oct 2026 00:00:00 GMT\r\nConnection: close\r\n\r\n",body.len())?;
    stream.write_all(body)
}
#[test]
fn storage_provider_http_contracts_immutable_readback_and_auth_failures() {
    let library = uuid::Uuid::new_v4().to_string();
    let name = format!("tp1-{library}-batch-configuration-fixture.tps");
    for kind in ["webdav", "s3", "r2"] {
        let server = Mock::new(kind);
        let provider = match kind {
            "webdav" => Provider::Webdav {
                endpoint: format!("{}/objects", server.url),
                username: "fixture".into(),
                password: "secret".into(),
                auth_type: String::new(),
                token: String::new(),
            },
            "s3" => Provider::S3 {
                endpoint: server.url.clone(),
                bucket: "bucket".into(),
                region: "us-east-1".into(),
                access_key: "access".into(),
                secret_key: "secret".into(),
                session_token: String::new(),
                prefix: "prefix".into(),
            },
            _ => Provider::R2 {
                endpoint: "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com"
                    .into(),
                bucket: "bucket".into(),
                access_key: "access".into(),
                secret_key: "secret".into(),
                prefix: "prefix".into(),
            },
        };
        let mut backend = Backend::new(provider, &library).unwrap();
        // Validate a real R2 API origin before routing this isolated test to loopback.
        if let Provider::R2 { endpoint, .. } = &mut backend.provider {
            *endpoint = server.url.clone();
        }
        backend.client = Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(15))
            .build()
            .unwrap();
        assert!(backend.list().unwrap().is_empty(), "{kind}");
        backend.put(&name, b"encrypted fixture").unwrap();
        assert_eq!(backend.get(&name).unwrap().unwrap(), b"encrypted fixture");
        assert_eq!(backend.list().unwrap(), vec![name.clone()]);
        backend.put(&name, b"encrypted fixture").unwrap();
        assert_eq!(
            backend.put(&name, b"different").unwrap_err().code,
            "syncCollision"
        );
        assert!(backend.server_time().is_some());
        let retired = format!("tp1-{library}-g-{}-chunk-configuration-{}.tps", uuid::Uuid::new_v4(), hex::encode(Sha256::digest(b"retired fixture")));
        backend.put(&retired, b"retired fixture").unwrap();
        backend.remove_retired(&retired).unwrap();
        backend.remove_retired(&retired).unwrap();
        assert!(backend.get(&retired).unwrap().is_none());
        let digest = hex::encode(Sha256::digest(b"full version fixture"));
        let complete = format!("history/full-{library}-{digest}.tps");
        backend.put(&complete, b"full version fixture").unwrap();
        assert_eq!(backend.get(&complete).unwrap().unwrap(), b"full version fixture");
        let foreign = format!("history/full-{}-{digest}.tps", uuid::Uuid::new_v4());
        backend.put(&foreign, b"full version fixture").unwrap();
        assert!(backend.remove_retired(&foreign).is_err(), "must preserve another library");
        assert!(backend.remove_retired(&format!("history/../{complete}")).is_err());
        backend.remove_retired(&complete).unwrap();
        assert!(backend.get(&complete).unwrap().is_none());
        assert!(backend.get(&foreign).unwrap().is_some());
        assert!(backend.remove_retired(&format!("tp1-{library}-control.tps")).is_err());
        server.state.lock().unwrap().files.insert(retired.clone(), b"modified data".to_vec());
        assert_eq!(backend.remove_retired(&retired).unwrap_err().code, "syncIntegrity");
        assert!(backend.get(&retired).unwrap().is_some());
        server.state.lock().unwrap().reject = true;
        assert_eq!(backend.list().unwrap_err().code, "syncAuth", "{kind}");
    }
}

#[test]
fn xml_entities_and_s3_prefixes_are_not_split_or_reinterpreted() {
    assert_eq!(xml_values(b"<root><NextContinuationToken>prefix&amp;next&#43;value</NextContinuationToken></root>",b"NextContinuationToken").unwrap(),vec!["prefix&next+value"]);
    assert_eq!(xml_values(b"<d:multistatus xmlns:d='DAV:'><d:href><![CDATA[/folder/a&b]]></d:href><d:href>/folder/c</d:href></d:multistatus>",b"href").unwrap(),vec!["/folder/a&b","/folder/c"]);
    assert_eq!(
        encode_path("folder with space/中文"),
        "folder%20with%20space/%E4%B8%AD%E6%96%87"
    );
}

#[test]
fn webdav_digest_challenge_and_token_authentication() {
    let library = uuid::Uuid::new_v4().to_string();
    let name = format!("tp1-{library}-batch-configuration-auth.tps");
    for (kind, auth) in [("webdavDigest", "digest"), ("webdavToken", "token")] {
        let server = Mock::new(kind);
        let mut backend = Backend::new(
            Provider::Webdav {
                endpoint: format!("{}/objects", server.url),
                username: "fixture".into(),
                password: "secret".into(),
                auth_type: auth.into(),
                token: "fixture-token".into(),
            },
            &library,
        )
        .unwrap();
        backend.client = Client::builder()
            .no_proxy()
            .timeout(Duration::from_secs(15))
            .build()
            .unwrap();
        assert!(backend.list().unwrap().is_empty());
        backend.put(&name, b"fixture encrypted").unwrap();
        assert_eq!(backend.get(&name).unwrap().unwrap(), b"fixture encrypted");
        assert_eq!(backend.list().unwrap(), vec![name.clone()]);
    }
}

#[test]
fn r2_endpoint_and_credentials_are_validated_and_secrets_are_not_exposed() {
    let library = uuid::Uuid::new_v4().to_string();
    let account = "0123456789abcdef0123456789abcdef";
    for suffix in ["", ".eu", ".us"] {
        let provider = Provider::R2 {
            endpoint: format!("https://{account}{suffix}.r2.cloudflarestorage.com"),
            bucket: "termpilot-sync".into(),
            access_key: "access".into(),
            secret_key: "test-secret".into(),
            prefix: "termpilot".into(),
        };
        let public = provider.public().to_string();
        assert!(!public.contains("test-secret"));
        assert!(!public.contains("access_key"));
        assert!(Backend::new(provider, &library).is_ok());
    }
    for address in [
        format!("http://{account}.r2.cloudflarestorage.com"),
        format!("https://{account}.r2.cloudflarestorage.com/bucket"),
        format!("https://{account}.r2.cloudflarestorage.com.evil.invalid"),
        format!("https://{account}.r2.cloudflarestorage.com?token=secret"),
        "https://public.r2.dev".into(),
        "https://files.example.com".into(),
        "http://127.0.0.1:9000".into(),
    ] {
        assert!(validate_r2_endpoint(&address).is_err(), "{address}");
    }
    let invalid = Provider::R2 {
        endpoint: format!("https://{account}.r2.cloudflarestorage.com"),
        bucket: "termpilot-sync".into(),
        access_key: String::new(),
        secret_key: String::new(),
        prefix: String::new(),
    };
    assert!(Backend::new(invalid, &library).is_err());
}

#[test]
fn r2_paginates_and_rejects_a_conditional_write_race_without_losing_data() {
    let server = Mock::new("r2");
    let library = uuid::Uuid::new_v4().to_string();
    let mut backend = Backend::new(
        Provider::R2 {
            endpoint: "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com".into(),
            bucket: "bucket".into(),
            access_key: "access".into(),
            secret_key: "secret".into(),
            prefix: "prefix".into(),
        },
        &library,
    )
    .unwrap();
    if let Provider::R2 { endpoint, .. } = &mut backend.provider {
        *endpoint = server.url.clone();
    }
    backend.client = Client::builder().no_proxy().build().unwrap();
    let names: Vec<_> = (0..5)
        .map(|i| format!("tp1-{library}-batch-configuration-{i}.tps"))
        .collect();
    for name in &names {
        backend.put(name, b"encrypted content").unwrap();
    }
    server.state.lock().unwrap().page_size = 2;
    assert_eq!(backend.list().unwrap(), names);
    server.state.lock().unwrap().race = true;
    let raced = format!("tp1-{library}-batch-configuration-race.tps");
    assert_eq!(
        backend.put(&raced, b"new ciphertext").unwrap_err().code,
        "syncVerify"
    );
    assert_eq!(backend.get(&raced).unwrap().unwrap(), b"competing object");
}

#[test]
fn conditional_control_updates_are_atomic_and_unsafe_servers_are_rejected() {
    for kind in ["webdav", "s3", "r2"] {
        let server = Mock::new(kind);
        let library = uuid::Uuid::new_v4().to_string();
        let provider = match kind {
            "webdav" => Provider::Webdav {
                endpoint: format!("{}/objects", server.url),
                username: "fixture".into(),
                password: "secret".into(),
                auth_type: String::new(),
                token: String::new(),
            },
            "s3" => Provider::S3 {
                endpoint: server.url.clone(),
                bucket: "bucket".into(),
                region: "us-east-1".into(),
                prefix: "prefix".into(),
                access_key: "access".into(),
                secret_key: "secret".into(),
                session_token: String::new(),
            },
            _ => Provider::R2 {
                endpoint: "https://0123456789abcdef0123456789abcdef.r2.cloudflarestorage.com"
                    .into(),
                bucket: "bucket".into(),
                prefix: "prefix".into(),
                access_key: "access".into(),
                secret_key: "secret".into(),
            },
        };
        let mut backend = Backend::new(provider, &library).unwrap();
        if let Provider::R2 { endpoint, .. } = &mut backend.provider {
            *endpoint = server.url.clone();
        }
        backend.client = Client::builder().no_proxy().build().unwrap();
        backend.check_conditionals(&library).unwrap();
        let name = format!("tp1-{library}-control.tps");
        assert!(backend.compare_exchange(&name, None, b"old").unwrap());
        assert!(!backend.compare_exchange(&name, None, b"other").unwrap());
        assert!(!backend
            .compare_exchange(&name, Some(b"stale"), b"other")
            .unwrap());
        assert!(backend
            .compare_exchange(&name, Some(b"old"), b"new")
            .unwrap());
        assert!(!backend
            .compare_exchange(&name, Some(b"old"), b"competing")
            .unwrap());
        assert_eq!(backend.get(&name).unwrap().unwrap(), b"new");
        server.state.lock().unwrap().weak_etags = true;
        assert_eq!(
            backend
                .compare_exchange(&name, Some(b"new"), b"unsafe")
                .unwrap_err()
                .code,
            "syncConditionalWrite"
        );
        server.state.lock().unwrap().weak_etags = false;
        server.state.lock().unwrap().ignore_conditions = true;
        assert_eq!(
            backend.check_conditionals(&library).unwrap_err().code,
            "syncConditionalWrite"
        );
        assert_eq!(backend.get(&name).unwrap().unwrap(), b"new");
    }
}

#[test]
fn encrypted_invite_http_merge_idempotency_rotation_and_failed_preflight() {
    use crate::{sync, vault::Vault};
    let server = Mock::new("webdav");
    let root = std::env::temp_dir().join(format!("termpilot-invite-{}", uuid::Uuid::new_v4()));
    struct Cleanup(std::path::PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    let a = Vault::open(&root.join("A"), None).unwrap();
    let b = Vault::open(&root.join("B"), None).unwrap();
    let c = Vault::open(&root.join("C"), None).unwrap();
    let call = |v: &Vault, mut r: Value| {
        r["directory"] = json!(v.directory);
        sync::dispatch(&r, Some(&v.key))
    };
    let host = |label: &str| json!({"label":label,"hostname":"fixture.invalid","port":22,"username":"test","connectionKind":"ssh","authentication":"password","password":"local-secret"});
    a.save("hosts", host("from-A"), None).unwrap();
    b.save("hosts", host("from-B"), None).unwrap();
    let provider = json!({"kind":"webdav","endpoint":format!("{}/objects",server.url),"username":"test","password":"cloud-secret"});
    let status=call(&a,json!({"method":"sync.profile.add","title":"家用同步","provider":provider,"passphrase":"invite-test-key-123","scopes":["configuration"],"name":"A","confirmed":true})).unwrap();
    let id = status["profiles"][0]["id"].clone();
    call(
        &a,
        json!({"method":"sync.profile.use","id":id,"confirmed":true}),
    )
    .unwrap();
    assert!(call(
        &a,
        json!({"method":"sync.invite.export","id":id,"passphrase":"invite-test-key-123"})
    )
    .is_err());
    call(&a, json!({"method":"sync.run"})).unwrap();
    let exported = call(
        &a,
        json!({"method":"sync.invite.export","id":id,"passphrase":"invite-test-key-123"}),
    )
    .unwrap();
    let code = exported["code"].clone();
    assert!(!exported["qr"].is_null());
    let preview = call(
        &b,
        json!({"method":"sync.invite.preview","code":code,"passphrase":"invite-test-key-123"}),
    )
    .unwrap();
    assert!(preview["provider"].get("password").is_none());
    let mut import = json!({"method":"sync.invite.import","code":code,"passphrase":"invite-test-key-123","scopes":["configuration"],"name":"B","confirmed":true});
    import["passphrase"] = json!("wrong-invite-key-123");
    assert!(call(&b, import.clone()).is_err());
    assert_eq!(
        call(&b, json!({"method":"sync.status"})).unwrap()["profiles"],
        json!([])
    );
    import["passphrase"] = json!("invite-test-key-123");
    server.state.lock().unwrap().reject = true;
    assert!(call(&b, import.clone()).is_err());
    server.state.lock().unwrap().reject = false;
    assert_eq!(
        call(&b, json!({"method":"sync.status"})).unwrap()["profiles"],
        json!([])
    );
    let result = call(&b, import.clone()).unwrap();
    assert_eq!(result["synced"], true, "{result}");
    assert_eq!(b.list("hosts").unwrap().len(), 2);
    let get_device = |v: &Vault| sync::store::Store::new(v).unwrap().config().unwrap().device;
    assert_ne!(get_device(&a), get_device(&b));
    let b_device = get_device(&b);
    b.save("hosts", host("offline-B"), None).unwrap();
    let result = call(&b, import.clone()).unwrap();
    assert_eq!(result["synced"], true, "{result}");
    assert_eq!(result["reused"], true);
    assert_eq!(get_device(&b), b_device);
    assert_eq!(result["status"]["profiles"].as_array().unwrap().len(), 1);
    call(&a, json!({"method":"sync.run"})).unwrap();
    assert_eq!(a.list("hosts").unwrap().len(), 3);
    call(&a,json!({"method":"sync.password.begin","oldPassphrase":"invite-test-key-123","newPassphrase":"new-invite-key-456","confirmPassphrase":"new-invite-key-456","clientsUpdated":true,"confirmed":true})).unwrap();
    call(&a, json!({"method":"sync.password.resume"})).unwrap();
    assert!(call(&c, import.clone()).is_err()); // Old code still decrypts locally, but cannot join a rotated library.
    assert_eq!(
        call(&c, json!({"method":"sync.status"})).unwrap()["profiles"],
        json!([])
    );
    let fresh = call(
        &a,
        json!({"method":"sync.invite.export","id":id,"passphrase":"new-invite-key-456"}),
    )
    .unwrap();
    import["code"] = fresh["code"].clone();
    import["passphrase"] = json!("new-invite-key-456");
    b.save("hosts", host("offline-across-rekey"), None).unwrap();
    let r = call(&b, import.clone()).unwrap();
    assert_eq!(r["synced"], true, "{r}");
    assert_eq!(get_device(&b), b_device);
    let r = call(&c, import.clone()).unwrap();
    assert_eq!(r["synced"], true, "{r}");
    assert_eq!(c.list("hosts").unwrap().len(), 4);
    let d = Vault::open(&root.join("D"), None).unwrap();
    d.save("hosts", host("pending-after-network-failure"), None)
        .unwrap();
    server.state.lock().unwrap().reject_write = true;
    let partial = call(&d, import).unwrap();
    assert_eq!(partial["installed"], true);
    assert_eq!(partial["synced"], false);
    assert_eq!(d.list("hosts").unwrap().len(), 1);
    assert_eq!(
        call(&d, json!({"method":"sync.status"})).unwrap()["profiles"]
            .as_array()
            .unwrap()
            .len(),
        1
    );
    server.state.lock().unwrap().reject_write = false;
    call(&d, json!({"method":"sync.run"})).unwrap();
    assert_eq!(d.list("hosts").unwrap().len(), 5);
    for host in c.list("hosts").unwrap() {
        assert_ne!(host["password"], "local-secret");
    }
}
