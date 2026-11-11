use crate::{commands::AppServices, domain::Host, vault::VaultStore, worker};
use parking_lot::{Condvar, Mutex};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, HashMap, VecDeque},
    io::{Read, Write},
    process::{Child, ChildStdin},
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};
use tauri::{ipc::Response, AppHandle, Emitter, Manager, State};
#[derive(Default)]
pub struct Screens(Mutex<HashMap<String, Arc<Screen>>>);
struct Screen {
    original: Host,
    saved_host: bool,
    high_performance: bool,
    ready: Arc<AtomicBool>,
    login: Arc<crate::screen_login::LoginInput>,
    child: Mutex<Child>,
    input: Mutex<ChildStdin>,
    latest: Arc<Mutex<BTreeMap<u32, Vec<u8>>>>,
    audio: Arc<Mutex<VecDeque<Vec<u8>>>>,
    live: Arc<AtomicBool>,
    owner: String,
    attempt_id: String,
    remote_paths: Arc<Mutex<Vec<String>>>,
    progress: Arc<(Mutex<HashMap<String, Value>>, Condvar)>,
    cache: std::path::PathBuf,
    dragging: AtomicBool,
}
impl Drop for Screen {
    fn drop(&mut self) {
        self.live.store(false, Ordering::Release);
        let _ = self.child.get_mut().kill();
        let _ = self.child.get_mut().wait();
    }
}
impl Screen {
    fn close(self: &Arc<Self>) {
        self.live.store(false, Ordering::Release);
        let screen = self.clone();
        std::thread::spawn(move || screen.close_and_wait());
    }
    fn close_and_wait(&self) {
        self.login.cancel(None);
        self.live.store(false, Ordering::Release);
        self.progress.1.notify_all();
        let _ = self.send(&json!({"kind":"disconnect"}));
        for _ in 0..40 {
            if self.child.lock().try_wait().ok().flatten().is_some() { return; }
            std::thread::sleep(std::time::Duration::from_millis(50));
        }
        let mut child = self.child.lock();
        let _ = child.kill();
        let _ = child.wait();
    }
}
impl Screens {
    pub fn cancel_login_window(&self, owner: &str) {
        for screen in self.0.lock().values().filter(|screen| screen.owner == owner) { screen.login.cancel(None); }
    }
    pub fn close_window(&self,owner:&str){
        let removed={let mut screens=self.0.lock();let ids=screens.iter().filter(|(_,s)|s.owner==owner).map(|(id,_)|id.clone()).collect::<Vec<_>>();ids.into_iter().filter_map(|id|screens.remove(&id)).collect::<Vec<_>>()};
        for screen in removed{screen.close();}
    }
    pub fn close_all(&self){for(_,screen)in std::mem::take(&mut *self.0.lock()){screen.close();}}
}
const CONNECTION_CHANGED: &str = "已保存的远程桌面地址或账号已更改或删除，请从主机列表重新打开。";
const CREDENTIAL_MISSING: &str = "没有可用的远程桌面凭证，请修改已保存的主机或重新打开快速连接。";

pub fn window_is_foreground(window: &tauri::Window) -> bool {
    foreground_check(window)()
}
fn foreground_check(window: &tauri::Window) -> impl Fn() -> bool + Send + 'static {
    // On Windows a focused WebView2 child can leave Tao's outer-window focus
    // cache false. Use the OS foreground window, including while typing.
    #[cfg(windows)]
    {
        let handle = window.hwnd().ok().map(|handle| handle.0 as usize);
        move || handle.is_some_and(|handle| unsafe {
            windows::Win32::UI::WindowsAndMessaging::GetForegroundWindow().0 as usize == handle
        })
    }
    #[cfg(not(windows))]
    { let window = window.clone(); move || window.is_focused().unwrap_or(false) }
}

fn screen_profile(host: &Host) -> Value {
    host.screen_sharing_profile.clone().unwrap_or_else(|| if host.connection_kind == "rdp" {
        json!({"port":3389,"mode":"rdp"})
    } else { json!({"port":5900,"mode":"standardVNC"}) })
}
fn screen_target(host: &Host) -> Value {
    let profile = screen_profile(host);
    json!({"host":host.hostname,"kind":host.connection_kind,
        "port":profile["port"],"mode":profile["mode"],
        "username":if host.credential_id.is_some() { json!(host.username) }
            else { profile.get("username").cloned().unwrap_or(json!(host.username)) }})
}
// Fetch current saved secrets for each attempt. A tab keeps its original endpoint
// and account; quick-connect secrets exist only in the in-memory host snapshot.
fn screen_connection(vault: &VaultStore, original: &Host, saved_host: bool) -> Result<Value, String> {
    let host = if saved_host { vault.screen_host(&original.id)?.ok_or(CONNECTION_CHANGED)? }
        else { original.clone() };
    let profile = screen_profile(&host);
    let h = vault.resolve(&host)?;
    let mut effective = host.clone();
    if host.credential_id.is_some() {
        if h["authentication"] != "password" { return Err(CREDENTIAL_MISSING.into()); }
        effective.username = h["username"].as_str().unwrap_or_default().into();
    }
    if screen_target(&effective) != screen_target(original) { return Err(CONNECTION_CHANGED.into()); }
    let mode = if host.connection_kind == "rdp" { "rdp" }
        else if profile["mode"] == "highPerformance" { "highPerformance" } else { "standardVNC" };
    let password = if host.credential_id.is_some() { h["password"].clone() }
        else { profile.get("password").cloned().unwrap_or(h["password"].clone()) };
    if password.as_str().unwrap_or_default().is_empty() && (mode != "standardVNC" || host.credential_id.is_some()) {
        return Err(CREDENTIAL_MISSING.into());
    }
    let connection = json!({"protocol":mode,"host":host.hostname,
        "port":profile["port"].as_u64().unwrap_or(if mode == "rdp" {3389} else {5900}),
        "username":screen_target(&effective)["username"],"password":password.as_str().unwrap_or_default(),
        "proxy":h["proxy"],"audio":profile["audio"].as_bool().unwrap_or(true)});
    termpilot_core::dispatch(&json!({"apiVersion":1,"method":"validateConnection","connection":connection})).map_err(|e| e.message)?;
    Ok(connection)
}

#[tauri::command]
pub async fn screen_start(
    app: AppHandle,
    window: tauri::WebviewWindow,
    services: State<'_, AppServices>,
    session_id: String,
    attempt_id: String,
    host: Host,
    saved_host: Option<bool>,
    frame_rate: Option<u32>,
    video_codec: Option<String>,
    display_size: Option<(u16, u16)>,
) -> Result<(), String> {
    let vault = services.vault.clone();
    let owner = window.label().to_string();
    tauri::async_runtime::spawn_blocking(move || {
        start_screen(app, owner, vault, session_id, attempt_id, host, saved_host.unwrap_or(false), frame_rate, video_codec, display_size)
    }).await.map_err(err)?
}
fn start_screen(app: AppHandle, owner: String, vault: Arc<VaultStore>, session_id: String,
    attempt_id: String, host: Host, saved_host: bool, frame_rate: Option<u32>, video_codec: Option<String>, display_size: Option<(u16, u16)>) -> Result<(), String> {
    let (width, height) = display_size.unwrap_or((1920, 1080));
    if !matches!((width, height), (1280, 720) | (1920, 1080) | (2560, 1440) | (3840, 2160)) {
        return Err("Unsupported remote resolution".into());
    }
    let screens = app.state::<Screens>();
    let previous = {
        let mut items = screens.0.lock();
        if items.get(&session_id).is_some_and(|s| s.owner != owner) { return Err("Wrong session owner".into()); }
        items.remove(&session_id)
    };
    if let Some(previous) = previous { previous.close_and_wait(); }
    let connection = screen_connection(&vault, &host, saved_host)?;
    if app.get_webview_window(&owner).is_none() { return Err("Screen window closed".into()); }
    let is_rdp = connection["protocol"] == "rdp";
    let mut path = worker::engine_path(&app)?;
    if is_rdp {
        path.set_file_name(if cfg!(windows) {
            "termpilot-rdp.exe"
        } else {
            "termpilot-rdp"
        });
    }
    let mut child = worker::command(&path, "screen-sharing")
        .spawn()
        .map_err(err)?;
    let mut input = child.stdin.take().ok_or("Missing screen input")?;
    let mut output = child.stdout.take().ok_or("Missing screen output")?;
    if let Some(mut error) = child.stderr.take() {
        std::thread::spawn(move || {
            let _ = std::io::copy(&mut error, &mut std::io::sink());
        });
    }
    let frame_rate = termpilot_core::frame::normalized_frame_rate(frame_rate.map(u64::from));
    writeln!(input,"{}",json!({"kind":"connect","mode":connection["protocol"],"frameRate":frame_rate,
        "width":width,"height":height,
        "videoCodec":if video_codec.as_deref()==Some("h265"){ "h265" }else{ "h264" },
        "audio":connection["audio"],"host":connection["host"],"port":connection["port"],
        "username":connection["username"],"password":connection["password"],"proxy":connection["proxy"],
        "lockDirectory":vault.directory.join("ScreenSharing")})).map_err(err)?;
    input.flush().map_err(err)?;
    let live = Arc::new(AtomicBool::new(true));
    let ready = Arc::new(AtomicBool::new(false));
    let login = Arc::new(crate::screen_login::LoginInput::default());
    let latest = Arc::new(Mutex::new(BTreeMap::new()));
    let audio = Arc::new(Mutex::new(VecDeque::new()));
    let audio_frames = audio.clone();
    let frames = latest.clone();
    let remote_paths = Arc::new(Mutex::new(Vec::new()));
    let remote_offer = remote_paths.clone();
    let progress = Arc::new((Mutex::new(HashMap::<String, Value>::new()), Condvar::new()));
    let transfer_progress = progress.clone();
    let previous=screens.0.lock().insert(
        session_id.clone(),
        Arc::new(Screen {
            original: host,
            saved_host,
            high_performance: connection["protocol"] == "highPerformance",
            ready: ready.clone(),
            login: login.clone(),
            child: Mutex::new(child),
            input: Mutex::new(input),
            latest,
            audio,
            live: live.clone(),
            owner: owner.clone(),
            attempt_id: attempt_id.clone(),
            remote_paths,
            progress,
            cache: vault.directory.join("ScreenSharingFiles"),
            dragging: AtomicBool::new(false),
        }),
    );
    if let Some(previous)=previous{previous.close();}
    std::thread::spawn(move || {
        let result = (|| -> Result<(), String> {
            loop {
                let mut prefix = [0u8; 4];
                output.read_exact(&mut prefix).map_err(err)?;
                let n = u32::from_be_bytes(prefix) as usize;
                if !(2..=65536).contains(&n) {
                    return Err("Invalid screen header".into());
                }
                let mut header = vec![0; n];
                output.read_exact(&mut header).map_err(err)?;
                let length =
                    termpilot_core::frame::validate_header(&header).map_err(|e| e.message)?;
                let mut payload = vec![0; length];
                output.read_exact(&mut payload).map_err(err)?;
                let mut h: Value = serde_json::from_slice(&header).map_err(err)?;
                if h["kind"] == "frame" {
                    let mut frame = prefix.to_vec();
                    frame.extend(header);
                    frame.extend(payload);
                    let tile = h["tile"].as_u64().unwrap_or(0);
                    if tile >= 16 {
                        return Err("Invalid screen tile".into());
                    }
                    frames.lock().insert(tile as u32, frame);
                    if !ready.swap(true, Ordering::AcqRel) && live.load(Ordering::Acquire) {
                        let _ = app.emit_to(&owner, "screen-event",
                            json!({"sessionId":session_id,"attemptId":attempt_id,"kind":"firstFrame"}));
                    }
                } else if h["kind"] == "audio" {
                    if !payload.len().is_multiple_of(8) || payload.len() > 32768 {
                        return Err("Invalid audio frame".into());
                    }
                    let mut queue = audio_frames.lock();
                    if queue.len() >= 12 {
                        queue.pop_front();
                    }
                    queue.push_back(payload);
                } else {
                    if h["kind"] == "credentialKeySent" {
                        if let Some(request) = h["requestID"].as_str() { login.acknowledge(request); }
                        continue;
                    }
                    if h["kind"] == "error" || h["kind"] == "disconnected" {
                        ready.store(false, Ordering::Release);
                        login.cancel(None);
                    }
                    if h["kind"] == "remoteDrag" {
                        let paths = h["paths"]
                            .as_array()
                            .map(|a| {
                                a.iter()
                                    .filter_map(|p| p.as_str().map(str::to_string))
                                    .take(256)
                                    .collect()
                            })
                            .unwrap_or_default();
                        *remote_offer.lock() = paths;
                    }
                    if h["kind"] == "fileTransfer" {
                        if let Some(id) = h["requestID"].as_str() {
                            let mut entries = transfer_progress.0.lock();
                            if entries.len() > 512 {
                                entries.retain(|_, v| {
                                    !["completed", "failed", "cancelled"]
                                        .contains(&v["stage"].as_str().unwrap_or(""))
                                });
                            }
                            entries.insert(id.into(), h.clone());
                            transfer_progress.1.notify_all();
                        }
                    }
                    h["sessionId"] = json!(session_id);
                    h["attemptId"] = json!(attempt_id);
                    if h["kind"] == "clipboard" {
                        h["text"] = json!(String::from_utf8_lossy(&payload));
                    }
                    if h["kind"] == "clipboardFiles" && !payload.is_empty() {
                        h["paths"] = serde_json::from_slice::<Value>(&payload).map_err(err)?;
                    }
                    if live.load(Ordering::Acquire) {
                        let _ = app.emit_to(&owner, "screen-event", h);
                    }
                }
            }
        })();
        if let Err(error) = result {
            ready.store(false, Ordering::Release);
            login.cancel(None);
            if !live.load(Ordering::Acquire) {
                return;
            }
            let _ = app.emit_to(
                &owner, "screen-event",
                json!({"sessionId":session_id,"attemptId":attempt_id,"kind":"disconnected","message":error}),
            );
            live.store(false, Ordering::Release);
            transfer_progress.1.notify_all();
        }
    });
    Ok(())
}
#[tauri::command]
pub fn screen_next(screens: State<'_, Screens>, session_id: String) -> Response {
    let screen = screens.0.lock().get(&session_id).cloned();
    let bytes = screen
        .map(|s| {
            std::mem::take(&mut *s.latest.lock())
                .into_values()
                .flatten()
                .collect::<Vec<u8>>()
        })
        .unwrap_or_default();
    Response::new(bytes)
}
#[tauri::command]
pub fn screen_audio_next(screens: State<'_, Screens>, session_id: String) -> Response {
    let screen = screens.0.lock().get(&session_id).cloned();
    Response::new(
        screen
            .map(|s| s.audio.lock().drain(..).flatten().collect::<Vec<u8>>())
            .unwrap_or_default(),
    )
}
#[tauri::command]
pub fn screen_send(
    screens: State<'_, Screens>,
    window: tauri::WebviewWindow,
    session_id: String,
    command: Value,
) -> Result<(), String> {
    let s = screens
        .0
        .lock()
        .get(&session_id)
        .cloned()
        .ok_or("Screen session ended")?;
    if s.owner != window.label() { return Err("Wrong session owner".into()); }
    if command["kind"] == "release" { s.login.cancel(None); }
    if s.login.busy() && matches!(command["kind"].as_str(), Some("key" | "text" | "pointer" | "scroll" | "dragEnter" | "dragDrop")) { return Ok(()); }
    if command["kind"] == "credentialKey" { return Err("Use credential input action".into()); }
    s.send(&command)
}

fn login_screen(screens: &Screens, owner: &str, session: &str, attempt: &str) -> Result<Arc<Screen>, String> {
    let screen = screens.0.lock().get(session).cloned().ok_or("连接已断开。")?;
    if screen.owner != owner || screen.attempt_id != attempt { return Err("连接已变化，请重试。".into()); }
    Ok(screen)
}
#[tauri::command]
pub async fn screen_enter_login_password(
    screens: State<'_, Screens>, services: State<'_, AppServices>, window: tauri::WebviewWindow,
    session_id: String, attempt_id: String, request_id: String,
) -> Result<String, String> {
    let screen = login_screen(&screens, window.label(), &session_id, &attempt_id)?;
    if !screen.high_performance || !screen.ready.load(Ordering::Acquire) || !screen.live.load(Ordering::Acquire) {
        return Err("高性能屏幕共享尚未就绪。".into());
    }
    let foreground = foreground_check(&window.as_ref().window());
    if !foreground() { return Err(crate::screen_login::CANCELLED.into()); }
    screen.login.begin(&request_id)?;
    let vault = services.vault.clone();
    tauri::async_runtime::spawn_blocking(move || {
        let password = screen_connection(&vault, &screen.original, screen.saved_host)
            .and_then(|connection| connection["password"].as_str().map(str::to_owned).ok_or(CREDENTIAL_MISSING.into()));
        screen.login.run(&request_id, password,
            || screen.live.load(Ordering::Acquire) && screen.ready.load(Ordering::Acquire) && foreground(),
            |command| screen.send(command), std::time::Duration::from_secs(5))
    }).await.map_err(err)?
}
#[tauri::command]
pub fn screen_cancel_login_password(
    screens: State<'_, Screens>, window: tauri::WebviewWindow,
    session_id: String, attempt_id: String, request_id: String,
) -> Result<(), String> {
    let screen = login_screen(&screens, window.label(), &session_id, &attempt_id)?;
    screen.login.cancel(Some(&request_id));
    Ok(())
}
impl Screen {
    fn send(&self, command: &Value) -> Result<(), String> {
        let bytes = serde_json::to_vec(command).map_err(err)?;
        if bytes.len() > 1024 * 1024 {
            return Err("Screen command exceeds limit".into());
        }
        let mut input = self.input.lock();
        input
            .write_all(&bytes)
            .and_then(|_| input.write_all(b"\n"))
            .and_then(|_| input.flush())
            .map_err(err)
    }
}
#[tauri::command]
pub async fn screen_drag_out(
    screens: State<'_, Screens>,
    window: tauri::WebviewWindow,
    session_id: String,
) -> Result<(), String> {
    let s = screens
        .0
        .lock()
        .get(&session_id)
        .cloned()
        .ok_or("Screen session ended")?;
    if s.owner != window.label() {
        return Err("Wrong session owner".into());
    }
    let paths = s.remote_paths.lock().clone();
    if paths.is_empty() {
        return Err("远端没有可拖出的文件".into());
    }
    if s.dragging.swap(true, Ordering::AcqRel) {
        return Err("文件拖拽正在进行".into());
    }
    for command in [json!({"kind":"key","key":0xff1b,"down":true}),json!({"kind":"key","key":0xff1b,"down":false}),json!({"kind":"release"})] {
        if let Err(error)=s.send(&command){s.dragging.store(false,Ordering::Release);return Err(error);}
    }
    let worker = s.clone();
    let result=tauri::async_runtime::spawn_blocking(move||crate::screen_drag::run(move||receive_drag(&worker,&paths))).await.map_err(err);
    s.dragging.store(false, Ordering::Release);
    result?
}
fn receive_drag(screen:&Screen,paths:&[String])->Result<Vec<std::path::PathBuf>,String>{
    let directory=screen.cache.join(uuid::Uuid::new_v4().to_string());
    let mut jobs=Vec::new();
    for path in paths {
        let name=path.trim_end_matches('/').rsplit('/').next().ok_or("Invalid remote name")?;
        if name.is_empty()||name=="."||name==".."||name.contains(['\\',':']){return Err("Invalid remote name".into());}
        let destination=directory.join(name);
        if jobs.iter().any(|(_,_,p)|p==&destination){return Err("重复文件名，请分别拖拽".into());}
        jobs.push((uuid::Uuid::new_v4().to_string(),path.clone(),destination));
    }
    std::fs::create_dir_all(&directory).map_err(err)?;
    let result=(||{
        for(id,source,destination)in &jobs{screen.send(&json!({"kind":"fileDownload","source":source,"destination":destination,"requestID":id}))?;}
        let deadline=std::time::Instant::now()+std::time::Duration::from_secs(3600);
        let mut states=screen.progress.0.lock();
        loop{
            if !screen.live.load(Ordering::Acquire){return Err("连接已断开".to_string());}
            let mut complete=true;
            for(id,_,_)in &jobs{match states.get(id).and_then(|v|v["stage"].as_str()){
                Some("completed")=>{},Some("failed"|"cancelled")=>return Err("文件接收失败或已取消".into()),_=>complete=false
            }}
            if complete{return Ok(jobs.iter().map(|(_,_,p)|p.clone()).collect());}
            if std::time::Instant::now()>=deadline{return Err("文件接收超时".into());}
            screen.progress.1.wait_for(&mut states,std::time::Duration::from_millis(500));
        }
    })();
    if result.is_err(){for(id,_,_)in &jobs{let _=screen.send(&json!({"kind":"fileCancel","requestID":id}));}}
    result
}
#[tauri::command]
pub async fn screen_close(screens: State<'_, Screens>, window: tauri::WebviewWindow, session_id: String, attempt_id: Option<String>) -> Result<(), String> {
    let screen = {
        let mut items = screens.0.lock();
        match items.get(&session_id) {
            Some(s) if s.owner != window.label() => return Err("Wrong session owner".into()),
            Some(s) if attempt_id.as_ref().is_none_or(|id| *id == s.attempt_id) => items.remove(&session_id),
            _ => None,
        }
    };
    if let Some(screen) = screen {
        tauri::async_runtime::spawn_blocking(move || screen.close_and_wait()).await.map_err(err)?;
    }
    Ok(())
}
#[tauri::command]
pub fn clipboard_read() -> Result<String, String> {
    arboard::Clipboard::new()
        .and_then(|mut c| c.get_text())
        .map_err(err)
}
#[tauri::command]
pub fn clipboard_write(text: String) -> Result<(), String> {
    arboard::Clipboard::new()
        .and_then(|mut c| c.set_text(text))
        .map_err(err)
}
fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

#[cfg(test)]
mod reconnect_tests {
    use super::*;
    use crate::domain::Credential;
    struct Fixture(std::path::PathBuf);
    impl Drop for Fixture { fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); } }
    fn fixture() -> (Fixture, VaultStore, Host) {
        let dir = Fixture(std::env::temp_dir().join(format!("TermPilot-screen-retry-{}", uuid::Uuid::new_v4())));
        let vault = VaultStore::open(dir.0.clone()).unwrap();
        let host: Host = serde_json::from_value(json!({"label":"fixture","hostname":"127.0.0.1","username":"user",
            "connectionKind":"screenSharing","authentication":"password",
            "screenSharingProfile":{"port":5900,"mode":"standardVNC","username":"user","password":"first"}})).unwrap();
        (dir, vault, host)
    }
    #[test]
    fn saved_reconnect_reads_new_password_and_rejects_changed_or_deleted_target() {
        let (_dir, vault, host) = fixture();
        let original = vault.save_host(host).unwrap();
        let mut updated = original.clone();
        updated.screen_sharing_profile.as_mut().unwrap()["password"] = json!("corrected");
        vault.save_host(updated.clone()).unwrap();
        assert_eq!(screen_connection(&vault,&original,true).unwrap()["password"], "corrected");
        updated.hostname = "different.invalid".into();
        vault.save_host(updated).unwrap();
        assert_eq!(screen_connection(&vault,&original,true).unwrap_err(), CONNECTION_CHANGED);
        vault.delete_host(&original.id).unwrap();
        assert_eq!(screen_connection(&vault,&original,true).unwrap_err(), CONNECTION_CHANGED);
    }
    #[test]
    fn quick_reconnect_keeps_session_secret_and_refreshes_credential_reference() {
        let (_dir, vault, mut host) = fixture();
        assert_eq!(screen_connection(&vault,&host,false).unwrap()["password"], "first");
        let credential: Credential = serde_json::from_value(json!({"label":"fixture","kind":"password","username":"user","password":"linked"})).unwrap();
        let mut credential = vault.save_credential(credential).unwrap();
        host.credential_id = Some(credential.id.clone());
        assert_eq!(screen_connection(&vault,&host,false).unwrap()["password"], "linked");
        credential.password = Some("new-linked".into());
        vault.save_credential(credential.clone()).unwrap();
        assert_eq!(screen_connection(&vault,&host,false).unwrap()["password"], "new-linked");
        vault.delete_credential(&credential.id).unwrap();
        assert!(screen_connection(&vault,&host,false).is_err());
        // A deleted reference must never fall back to an old inline password.
    }
    #[test]
    fn saved_credential_changes_preserve_original_account_and_protocol() {
        let (_dir, vault, host) = fixture();
        let original = vault.save_host(host).unwrap();
        for (key, value) in [("username",json!("other")),("port",json!(5901)),("mode",json!("highPerformance"))] {
            let mut changed = original.clone();
            changed.screen_sharing_profile.as_mut().unwrap()[key] = value;
            vault.save_host(changed).unwrap();
            assert_eq!(screen_connection(&vault,&original,true).unwrap_err(), CONNECTION_CHANGED);
        }
    }
    #[test]
    fn passwordless_vnc_is_valid_but_missing_rdp_or_high_performance_secret_is_explicit() {
        let (_dir, vault, mut host) = fixture();
        host.screen_sharing_profile.as_mut().unwrap()["password"] = json!("");
        assert_eq!(screen_connection(&vault,&host,false).unwrap()["password"], "");
        host.screen_sharing_profile.as_mut().unwrap()["mode"] = json!("highPerformance");
        assert_eq!(screen_connection(&vault,&host,false).unwrap_err(), CREDENTIAL_MISSING);
        host.connection_kind = "rdp".into();
        assert_eq!(screen_connection(&vault,&host,false).unwrap_err(), CREDENTIAL_MISSING);
    }
}
