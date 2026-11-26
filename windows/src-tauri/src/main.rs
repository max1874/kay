//! Kay for Windows: hold a key, speak, let go, and the text lands at the cursor. The same product as the Mac app
//! at the repository root, written again for Windows, since its Swift depends on AppKit and Core Audio throughout.

#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

#[cfg(not(windows))]
compile_error!("Kay for Windows builds on Windows; the Mac app is the Swift package at the repository root.");

mod audio;
mod commands;
mod correction;
mod credentials;
mod dictation;
mod files;
mod history;
mod hotkey;
mod hud;
mod i18n;
mod kay;
mod keys;
mod log;
mod media;
mod paste;
mod pending;
mod settings;
mod speech;
mod tray;
mod updater;
mod vocabulary;

use std::sync::Arc;

use tauri::{AppHandle, Manager, WindowEvent};

/// Passed when Windows starts Kay at login: it starts in the background, whatever the window setting says.
const BACKGROUND: &str = "--background";

fn main() {
    tauri::Builder::default()
        // Opening Kay again brings its window up.
        .plugin(tauri_plugin_single_instance::init(|app, _, _| tray::show_window(app, None)))
        .plugin(tauri_plugin_autostart::init(tauri_plugin_autostart::MacosLauncher::LaunchAgent, Some(vec![BACKGROUND])))
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_opener::init())
        .invoke_handler(tauri::generate_handler![
            commands::snapshot,
            commands::history,
            commands::copy_text,
            commands::delete_entry,
            commands::clear_history,
            commands::microphones,
            commands::update_settings,
            commands::set_launch_at_login,
            commands::select_provider,
            commands::test_provider,
            commands::remove_provider_key,
            commands::clear_candidate_error,
            commands::test_correction,
            commands::remove_correction_key,
            commands::vocabulary,
            commands::save_vocabulary,
            commands::count_terms,
            commands::record_trigger,
            commands::open_url,
            commands::reveal,
            commands::check_for_updates,
            commands::hud_mode,
            commands::quit,
        ])
        .setup(|app| {
            start(app.handle());
            Ok(())
        })
        .on_window_event(|window, event| {
            // Dictation lives on the key, not the window: closing it keeps Kay running.
            if let (WindowEvent::CloseRequested { api, .. }, "main") = (event, window.label()) {
                api.prevent_close();
                let _ = window.hide();
            }
        })
        .run(tauri::generate_context!())
        .expect("Kay runs");
}

fn start(app: &AppHandle) {
    log::notice(format!("Kay {} started", app.package_info().version));
    let (events, receiver) = tokio::sync::mpsc::unbounded_channel();
    let kay = Arc::new(kay::Kay::new(app.clone(), events.clone()));
    app.manage(kay.clone());
    let settings = kay.settings.lock().unwrap().clone();

    if let Err(e) = tray::create(app, settings.tray_icon) {
        log::error(format!("tray icon not created: {e}"));
    }
    hotkey::start(settings.triggers.clone(), move |event| {
        let _ = events.send(dictation::Event::Key(event));
    });
    tauri::async_runtime::spawn(dictation::run(kay.clone(), receiver));

    // Checked now, not during the first dictation.
    let provider = settings.speech.provider;
    if kay.speech.lock().unwrap().key(provider).value.is_some() {
        let kay = kay.clone();
        tauri::async_runtime::spawn(async move { kay.test(provider, None, None).await });
    }
    tauri::async_runtime::spawn(dictation::recover(kay.clone()));
    updater::start(kay);

    if settings.window_at_launch && !std::env::args().any(|a| a == BACKGROUND) {
        tray::show_window(app, None);
    }
}
