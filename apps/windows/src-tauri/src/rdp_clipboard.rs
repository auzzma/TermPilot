//! OS clipboard adapter. File data is received by the shared engine; only complete
//! local paths are published as CF_HDROP for Explorer's ordinary Paste operation.
use serde_json::{Value, json};
#[cfg(windows)]
mod native {
    use super::*;
    use std::{ffi::c_void, ptr};
    type Handle = *mut c_void;
    #[link(name = "user32")]
    unsafe extern "system" {
        fn OpenClipboard(owner: Handle) -> i32;
        fn CloseClipboard() -> i32;
        fn GetClipboardSequenceNumber() -> u32;
        fn GetClipboardData(format: u32) -> Handle;
        fn SetClipboardData(format: u32, data: Handle) -> Handle;
        fn EmptyClipboard() -> i32;
    }
    #[link(name = "kernel32")]
    unsafe extern "system" {
        fn GlobalAlloc(flags: u32, size: usize) -> Handle;
        fn GlobalLock(memory: Handle) -> Handle;
        fn GlobalUnlock(memory: Handle) -> i32;
        fn GlobalFree(memory: Handle) -> Handle;
    }
    #[link(name = "shell32")]
    unsafe extern "system" {
        fn DragQueryFileW(drop: Handle, index: u32, path: *mut u16, size: u32) -> u32;
    }
    struct Board;
    impl Drop for Board {
        fn drop(&mut self) {
            unsafe {
                CloseClipboard();
            }
        }
    }
    fn open(owner: Handle) -> Result<Board, String> {
        for _ in 0..5 {
            if unsafe { OpenClipboard(owner) } != 0 {
                return Ok(Board);
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        Err("系统剪贴板正忙，请重试".into())
    }
    #[cfg(test)]
    #[link(name = "user32")]
    unsafe extern "system" {
        fn CreateWindowExW(
            ex: u32,
            class: *const u16,
            title: *const u16,
            style: u32,
            x: i32,
            y: i32,
            w: i32,
            h: i32,
            parent: Handle,
            menu: Handle,
            instance: Handle,
            param: Handle,
        ) -> Handle;
        fn DestroyWindow(window: Handle) -> i32;
    }
    #[cfg(test)]
    #[test]
    fn native_files_and_stale_sequence_protection() {
        let class: Vec<u16> = "STATIC\0".encode_utf16().collect();
        let owner = unsafe {
            CreateWindowExW(
                0,
                class.as_ptr(),
                class.as_ptr(),
                0,
                0,
                0,
                1,
                1,
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null_mut(),
                ptr::null_mut(),
            )
        };
        assert!(!owner.is_null());
        let root =
            std::env::temp_dir().join(format!("TermPilot-RDP-clipboard-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        let path = root.join("中文.txt");
        std::fs::write(&path, b"fixture").unwrap();
        let sequence = unsafe { GetClipboardSequenceNumber() };
        let next = write(
            owner,
            vec![path.to_string_lossy().into_owned()],
            None,
            sequence,
        )
        .unwrap();
        let value = snapshot().unwrap();
        assert_eq!(value["sequence"], next);
        assert_eq!(value["paths"][0], path.to_string_lossy().as_ref());
        assert!(write(owner, vec![], Some("stale".into()), next.wrapping_add(1)).is_err());
        let updated = write(owner, vec![], Some("中文 text".into()), next).unwrap();
        let value = snapshot().unwrap();
        assert_eq!(value["text"], "中文 text");
        assert_eq!(value["sequence"], updated);
        unsafe {
            DestroyWindow(owner);
        }
        std::fs::remove_dir_all(root).unwrap();
    }
    pub fn snapshot() -> Result<Value, String> {
        let board = open(ptr::null_mut())?;
        let sequence = unsafe { GetClipboardSequenceNumber() };
        let handle = unsafe { GetClipboardData(15) };
        let mut paths = Vec::new();
        if !handle.is_null() {
            let n = unsafe { DragQueryFileW(handle, u32::MAX, ptr::null_mut(), 0) };
            if n > 10000 {
                return Err("剪贴板文件数超过限制".into());
            }
            for i in 0..n {
                let n = unsafe { DragQueryFileW(handle, i, ptr::null_mut(), 0) };
                if n > 32767 {
                    return Err("剪贴板路径过长".into());
                }
                let mut path = vec![0u16; n as usize + 1];
                unsafe { DragQueryFileW(handle, i, path.as_mut_ptr(), n + 1) };
                paths.push(String::from_utf16(&path[..n as usize]).map_err(|e| e.to_string())?);
            }
        }
        drop(board);
        // arboard owns and releases its clipboard lock; retry if another app changed it.
        let text = if paths.is_empty() {
            arboard::Clipboard::new()
                .and_then(|mut c| c.get_text())
                .ok()
        } else {
            None
        };
        if unsafe { GetClipboardSequenceNumber() } != sequence {
            return Err("剪贴板内容已变化，请重试".into());
        }
        Ok(json!({"sequence":sequence,"paths":paths,"text":text}))
    }
    pub fn write(
        owner: Handle,
        paths: Vec<String>,
        text: Option<String>,
        expected: u32,
    ) -> Result<u32, String> {
        let mut data = Vec::new();
        let format = if !paths.is_empty() {
            // DROPFILES: offset=20, POINT=0/0, fNC=0, fWide=1.
            for v in [20u32, 0, 0, 0, 1] {
                data.extend_from_slice(&v.to_le_bytes());
            }
            if paths.len() > 10000 {
                return Err("剪贴板文件数超过限制".into());
            }
            for path in paths {
                let p = std::path::Path::new(&path);
                if !p.is_absolute() || !p.exists() || path.contains('\0') {
                    return Err("接收文件不存在或路径无效".into());
                }
                for c in path.encode_utf16().chain([0]) {
                    data.extend_from_slice(&c.to_le_bytes());
                }
            }
            data.extend_from_slice(&[0, 0]);
            15
        } else {
            let value = text.unwrap_or_default();
            if value.len() > 8 * 1024 * 1024 {
                return Err("剪贴板文本超过 8 MiB".into());
            }
            for c in value.encode_utf16().chain([0]) {
                data.extend_from_slice(&c.to_le_bytes());
            }
            13
        };
        let board = open(owner)?;
        if unsafe { GetClipboardSequenceNumber() } != expected {
            return Err("本地剪贴板已变化，未覆盖新内容".into());
        }
        let memory = unsafe { GlobalAlloc(0x42, data.len()) };
        if memory.is_null() {
            return Err("剪贴板内存不足".into());
        }
        let target = unsafe { GlobalLock(memory) };
        if target.is_null() {
            unsafe {
                GlobalFree(memory);
            };
            return Err("剪贴板内存不可写".into());
        }
        unsafe {
            ptr::copy_nonoverlapping(data.as_ptr(), target as *mut u8, data.len());
            GlobalUnlock(memory);
        }
        if unsafe { EmptyClipboard() } == 0 || unsafe { SetClipboardData(format, memory) }.is_null()
        {
            unsafe {
                GlobalFree(memory);
            };
            return Err("无法写入系统剪贴板".into());
        }
        drop(board);
        Ok(unsafe { GetClipboardSequenceNumber() })
    }
}
#[tauri::command]
pub async fn rdp_clipboard_snapshot() -> Result<Value, String> {
    #[cfg(windows)]
    {
        tauri::async_runtime::spawn_blocking(native::snapshot).await.map_err(|e|e.to_string())?
    }
    #[cfg(not(windows))]
    {
        Ok(json!({"sequence":0,"paths":[],"text":super::screen::clipboard_read().ok()}))
    }
}
#[tauri::command]
pub async fn rdp_clipboard_write(
    window: tauri::WebviewWindow,
    paths: Vec<String>,
    text: Option<String>,
    expected: u32,
) -> Result<u32, String> {
    #[cfg(windows)]
    {
        let owner = window.hwnd().map_err(|e| e.to_string())?.0 as usize;
        tauri::async_runtime::spawn_blocking(move || native::write(owner as *mut std::ffi::c_void, paths, text, expected))
            .await.map_err(|e|e.to_string())?
    }
    #[cfg(not(windows))]
    {
        let _ = (window, paths, expected);
        super::screen::clipboard_write(text.unwrap_or_default())?;
        Ok(0)
    }
}
