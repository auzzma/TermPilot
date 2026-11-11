//! Portable entry point: the Tauri UI and Rust engine live in app/, user data in AppData/.
#![cfg_attr(target_os = "windows", windows_subsystem = "windows")]

use std::{
    env, io,
    process::{Command, Stdio},
};

fn launch() -> io::Result<i32> {
    let executable = env::current_exe()?;
    let directory = executable
        .parent()
        .ok_or_else(|| io::Error::other("Missing application directory"))?
        .join("app");
    let status = Command::new(directory.join("TermPilot.exe"))
        .args(env::args_os().skip(1))
        .current_dir(directory)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    Ok(status.code().unwrap_or(1))
}

#[cfg(target_os = "windows")]
fn show_error(error: &io::Error) {
    #[link(name = "user32")]
    extern "system" {
        fn MessageBoxW(
            window: *mut std::ffi::c_void,
            text: *const u16,
            caption: *const u16,
            kind: u32,
        ) -> i32;
    }
    let message: Vec<u16> = format!(
        "无法启动 TermPilot。请完整解压软件包，确保 TermPilot.exe 与 app 文件夹位于同一目录。\n\nUnable to start TermPilot. Extract the complete package and keep the app folder next to TermPilot.exe.\n\n{error}"
    ).encode_utf16().chain(Some(0)).collect();
    let title: Vec<u16> = "TermPilot".encode_utf16().chain(Some(0)).collect();
    // Both buffers are NUL-terminated and remain alive for this synchronous call.
    unsafe {
        MessageBoxW(std::ptr::null_mut(), message.as_ptr(), title.as_ptr(), 0x10);
    }
}

#[cfg(not(target_os = "windows"))]
fn show_error(error: &io::Error) {
    eprintln!("Unable to start TermPilot: {error}");
}

fn main() {
    match launch() {
        Ok(code) => std::process::exit(code),
        Err(error) => {
            show_error(&error);
            std::process::exit(1);
        }
    }
}
