//! What the window asks of Kay. Each change is answered by a `changed` or `history` event, after which the window
//! reads `snapshot` or `history` again: one place reacts, whatever made the change.

use std::sync::Arc;

use serde::Serialize;
use serde_json::Value;
use tauri::{AppHandle, State};
use tauri_plugin_autostart::ManagerExt as _;
use tauri_plugin_opener::OpenerExt;
use uuid::Uuid;

use crate::{
    audio,
    history::{self, Entry},
    hotkey::{self, Trigger},
    hud::Mode,
    i18n,
    keys::KeyState,
    kay::{Kay, State as Dictating},
    paste,
    settings::Settings,
    speech::{Provider, ProviderState},
    tray, updater,
    vocabulary::Vocabulary,
};

type Kayp<'a> = State<'a, Arc<Kay>>;

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    chinese: bool,
    version: String,
    state: Dictating,
    ready: bool,
    microphone_allowed: bool,
    /// Each trigger with its name, in the window's language.
    triggers: Vec<(Trigger, String)>,
    provider: Provider,
    providers: Vec<ProviderState>,
    correction: KeyState,
    settings: Settings,
    launch_at_login: bool,
}

#[tauri::command]
pub fn snapshot(kay: Kayp, app: AppHandle) -> Snapshot {
    let settings = kay.settings.lock().unwrap().clone();
    let microphone_allowed = audio::microphone_allowed();
    Snapshot {
        chinese: i18n::is_chinese(),
        version: app.package_info().version.to_string(),
        state: kay.state(),
        ready: microphone_allowed && kay.speech_usable(),
        microphone_allowed,
        triggers: settings.triggers.iter().map(|t| (*t, t.name())).collect(),
        provider: settings.speech.provider,
        providers: kay.speech_states(),
        correction: kay.correction.lock().unwrap().state(),
        launch_at_login: app.autolaunch().is_enabled().unwrap_or(false),
        settings,
    }
}

#[tauri::command]
pub fn history(kay: Kayp) -> Vec<Entry> {
    kay.history.lock().unwrap().clone()
}

#[tauri::command]
pub fn copy_text(text: String) -> bool {
    paste::copy(&text)
}

#[tauri::command]
pub fn delete_entry(kay: Kayp, id: Uuid) {
    kay.delete(id);
}

#[tauri::command]
pub fn clear_history(kay: Kayp) {
    kay.clear_history();
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Microphones {
    devices: Vec<audio::Device>,
    default_name: Option<String>,
}

/// Async, so COM runs on a worker thread rather than the window's.
#[tauri::command]
pub async fn microphones() -> Microphones {
    Microphones { devices: audio::microphones(), default_name: audio::default_microphone().map(|d| d.name) }
}

#[tauri::command]
pub fn update_settings(kay: Kayp, app: AppHandle, patch: Value) -> Result<(), String> {
    let mut settings = kay.settings.lock().unwrap();
    let next = settings.patched(patch)?;
    if next.triggers != settings.triggers {
        hotkey::set_triggers(next.triggers.clone());
    }
    if next.tray_icon != settings.tray_icon {
        tray::show(&app, next.tray_icon);
    }
    *settings = next;
    settings.save();
    drop(settings);
    kay.changed();
    Ok(())
}

#[tauri::command]
pub fn set_launch_at_login(kay: Kayp, app: AppHandle, on: bool) {
    let manager = app.autolaunch();
    if let Err(e) = if on { manager.enable() } else { manager.disable() } {
        crate::log::error(format!("open at login: {e}"));
    }
    kay.changed();
}

#[tauri::command]
pub fn select_provider(kay: Kayp, provider: Provider) {
    kay.select(provider);
}

/// Tests `key` (or the stored one) with `setting`; a key set up here, and still the one picked, is the one the
/// user wants to dictate with.
#[tauri::command]
pub async fn test_provider(kay: Kayp<'_>, provider: Provider, key: Option<String>, setting: Option<String>) -> Result<(), ()> {
    let kay = kay.inner().clone();
    kay.test(provider, key.filter(|k| !k.trim().is_empty()), setting).await;
    let passed = {
        let speech = kay.speech.lock().unwrap();
        let key = speech.key(provider);
        matches!(key.status, crate::keys::Status::Connected { .. }) && key.candidate_error.is_none()
    };
    if passed {
        kay.select(provider);
    }
    Ok(())
}

#[tauri::command]
pub fn remove_provider_key(kay: Kayp, provider: Provider) {
    kay.remove_key(provider);
}

#[tauri::command]
pub fn clear_candidate_error(kay: Kayp, provider: Option<Provider>) {
    match provider {
        Some(provider) => kay.clear_candidate_error(provider),
        None => {
            kay.correction.lock().unwrap().candidate_error = None;
            kay.changed();
        }
    }
}

#[tauri::command]
pub async fn test_correction(kay: Kayp<'_>, key: Option<String>) -> Result<(), ()> {
    kay.inner().clone().test_correction(key.filter(|k| !k.trim().is_empty())).await;
    Ok(())
}

#[tauri::command]
pub fn remove_correction_key(kay: Kayp) {
    kay.correction.lock().unwrap().remove();
    kay.changed();
}

#[tauri::command]
pub fn vocabulary() -> String {
    Vocabulary::text()
}

#[tauri::command]
pub fn save_vocabulary(text: String) -> bool {
    Vocabulary::save(&text)
}

#[tauri::command]
pub fn count_terms(text: String) -> usize {
    Vocabulary::parse(&text).len()
}

#[tauri::command]
pub fn record_trigger(on: bool) {
    hotkey::set_recording(on);
}

/// Only the consoles and pages Kay links to: web pages and Windows Settings.
#[tauri::command]
pub fn open_url(app: AppHandle, url: String) {
    if url.starts_with("https://") || url.starts_with("ms-settings:") {
        let _ = app.opener().open_url(url, None::<&str>);
    }
}

#[tauri::command]
pub fn reveal(app: AppHandle, file: String) {
    let path = match file.as_str() {
        "vocabulary" => Vocabulary::path(),
        _ => history::path(),
    };
    if !path.exists() && file == "vocabulary" {
        Vocabulary::save("");
    }
    let _ = app.opener().reveal_item_in_dir(path);
}

#[tauri::command]
pub async fn check_for_updates(kay: Kayp<'_>) -> Result<Option<String>, String> {
    updater::check(kay.inner()).await
}

#[tauri::command]
pub fn hud_mode(kay: Kayp) -> Mode {
    kay.hud.mode()
}

#[tauri::command]
pub fn quit(kay: Kayp) {
    kay.quit();
}
