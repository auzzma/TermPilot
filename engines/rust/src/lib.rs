//! TermPilot's shared, UI-independent connection engine.
pub mod batch;
pub mod files;
pub mod ipc;
pub mod keygen;
pub mod scp;
pub mod sftp;
pub mod ssh;
pub mod transport;
pub mod worker;

pub mod platform;

pub mod known_hosts;

#[cfg(all(unix, not(any(target_os = "ios", target_os = "android"))))]
pub mod local;

pub mod screen;

mod elevation;

pub mod monitor;

mod terminal_directory;
