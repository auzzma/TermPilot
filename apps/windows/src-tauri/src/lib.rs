mod ai;
mod batch;
mod autocomplete;
mod bridge;
mod commands;
mod domain;
mod files;
mod fonts;
mod platform;
mod rdp_clipboard;
mod screen;
mod screen_login;
mod screen_drag;
mod terminal;
mod vault;
mod worker;
use tauri::{Manager, RunEvent, WebviewWindowBuilder};
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .setup(|app| {
            let directory = std::env::var_os("TERMPILOT_DATA_DIR")
                .map(std::path::PathBuf::from)
                .map(Ok)
                .unwrap_or_else(vault::default_data_directory)
                .map_err(std::io::Error::other)?;
            let vault = if std::env::var_os("TERMPILOT_DATA_DIR").is_some() {
                vault::VaultStore::open(directory)
            } else {
                vault::VaultStore::open_portable(directory)
            }
            .map_err(std::io::Error::other)?;
            app.manage(commands::AppServices { vault: std::sync::Arc::new(vault) });
            app.manage(ai::AI::default());
            app.manage(screen::Screens::default());
            app.manage(bridge::Connections::default());
            app.manage(terminal::TerminalManager::default());
            app.manage(autocomplete::AutocompleteCatalog::load(app.handle()));
            let config = app
                .config()
                .app
                .windows
                .first()
                .ok_or_else(|| std::io::Error::other("Window configuration missing"))?;
            let builder = WebviewWindowBuilder::from_config(app.handle(), config)?;
            #[cfg(windows)]
            let builder = builder.data_directory(
                app.state::<commands::AppServices>()
                    .vault
                    .webview_data_directory(),
            );
            builder.build()?;
            Ok(())
        })
        .on_window_event(|window, event| {
            if matches!(event, tauri::WindowEvent::Focused(false)) && !screen::window_is_foreground(window) {
                window.app_handle().state::<screen::Screens>().cancel_login_window(window.label());
            }
            if matches!(event, tauri::WindowEvent::Destroyed) {
                let app = window.app_handle();
                let label = window.label();
                app.state::<ai::AI>().close_window(label);
                app.state::<bridge::Connections>().close_window(label);
                app.state::<terminal::TerminalManager>().close_window(label);
                app.state::<screen::Screens>().close_window(label);
            }
        })
        .invoke_handler(tauri::generate_handler![
            batch::batch_parse_targets,
            batch::batch_read_script,
            batch::batch_start,
            batch::batch_cancel,
            batch::batch_history,
            batch::batch_storage,
            batch::batch_save_csv,
            commands::sync_request,
            screen::screen_start,
            screen::screen_next,
            screen::screen_audio_next,
            screen::screen_drag_out,
            screen::screen_send,
            screen::screen_enter_login_password,
            screen::screen_cancel_login_password,
            screen::screen_close,
            rdp_clipboard::rdp_clipboard_snapshot,
            rdp_clipboard::rdp_clipboard_write,
            screen::clipboard_read,
            screen::clipboard_write,
            ai::ai_request,
            commands::platform_profile,
            commands::bootstrap,
            commands::export_backup,
            commands::import_backup,
            commands::save_host,
            commands::save_hosts,
            commands::delete_host,
            commands::save_group,
            commands::delete_group,
            commands::save_credential,
            commands::delete_credential,
            commands::save_proxy,
            commands::delete_proxy,
            commands::save_forward,
            commands::save_script,
            commands::save_snippet,
            commands::save_note,
            commands::delete_entity,
            commands::append_history,
            commands::append_command_history,
            commands::save_workspace,
            commands::erase_workspace,
            commands::save_preferences,
            commands::delete_known_host,
            commands::delete_known_hosts,
            commands::open_cloned_window,
            fonts::available_terminal_fonts,
            autocomplete::autocomplete_suggestions,
            terminal::terminal_start,
            terminal::terminal_write,
            terminal::terminal_resize,
            terminal::terminal_terminate,
            bridge::ssh_terminal_start,
            bridge::sftp_request,
            bridge::sftp_close,
            bridge::engine_prompt_reply,
            bridge::generate_credential_key,
            bridge::forward_start,
            bridge::forward_stop,
            files::local_write_text,
            files::local_home,
            files::local_downloads,
            files::local_list,
            files::local_entry,
            files::local_mkdir,
            files::local_create_file,
            files::local_rename,
            files::local_delete,
            files::local_duplicate,
            files::local_copy_to,
            files::local_move_to,
            files::local_temporary_path,
            files::local_modified_at,
            files::local_open,
            files::local_open_with,
            files::local_reveal,
            files::local_exec
        ])
        .build(tauri::generate_context!())
        .expect("Unable to start TermPilot")
        .run(|app, event| {
            if matches!(event, RunEvent::ExitRequested { .. }) {
                app.state::<screen::Screens>().close_all();
                app.state::<ai::AI>().close();
                app.state::<bridge::Connections>().close_all();
                app.state::<terminal::TerminalManager>().terminate_all();
            }
        });
}
