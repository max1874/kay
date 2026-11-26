//! Kay's choices, in `%APPDATA%\Kay\settings.json`.

use std::fs;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{hotkey::Trigger, speech::Provider};

#[derive(Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Settings {
    /// Any of them dictates, so each keyboard can use its own; never empty.
    pub triggers: Vec<Trigger>,
    /// The chosen microphone's endpoint ID; empty for the system default.
    pub microphone: String,
    /// Off: the text Kay pastes is marked so Windows' clipboard history (Win+V) and clipboard managers leave it out.
    pub show_in_clipboard_history: bool,
    pub pause_media: bool,
    /// DeepSeek correction after recognition; a no-op until a key is added.
    pub correction: bool,
    pub tray_icon: bool,
    /// Off: Kay starts in the background and waits for the key, as the Mac does with its Dock icon off.
    pub window_at_launch: bool,
    /// Written only by `speech::Speech`, after a test: the window can't patch it.
    pub speech: SpeechSettings,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "camelCase")]
pub struct SpeechSettings {
    pub provider: Provider,
    pub qwen_workspace_url: String,
    pub doubao_resource: String,
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            triggers: vec![Trigger::RIGHT_ALT],
            microphone: String::new(),
            show_in_clipboard_history: true,
            pause_media: true,
            correction: true,
            tray_icon: true,
            window_at_launch: true,
            speech: SpeechSettings::default(),
        }
    }
}

impl Default for SpeechSettings {
    fn default() -> Self {
        SpeechSettings {
            // Doubao until the user picks: it misheard 5.6% of characters to Qwen's 14.3% on Max's recordings.
            provider: Provider::Doubao,
            qwen_workspace_url: crate::speech::qwen::DEFAULT_WORKSPACE_URL.into(),
            doubao_resource: crate::speech::doubao::RESOURCES[0].0.into(),
        }
    }
}

impl Settings {
    fn path() -> std::path::PathBuf {
        crate::files::data().join("settings.json")
    }

    pub fn load() -> Settings {
        let settings: Settings =
            fs::read(Self::path()).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default();
        if settings.triggers.is_empty() {
            return Settings { triggers: Settings::default().triggers, ..settings };
        }
        settings
    }

    pub fn save(&self) {
        let _ = fs::create_dir_all(crate::files::data());
        if let Ok(data) = serde_json::to_vec_pretty(self) {
            if let Err(e) = fs::write(Self::path(), data) {
                crate::log::error(format!("settings not saved: {e}"));
            }
        }
    }

    /// These settings with the window's changes, given as the same JSON fields.
    pub fn patched(&self, patch: Value) -> Result<Settings, String> {
        let Value::Object(changes) = patch else { return Err("not an object".into()) };
        let mut merged = serde_json::to_value(self).map_err(|e| e.to_string())?;
        for (key, value) in changes {
            if key != "speech" {
                merged[key] = value;
            }
        }
        let settings: Settings = serde_json::from_value(merged).map_err(|e| e.to_string())?;
        if settings.triggers.is_empty() {
            return Err("at least one key must dictate".into());
        }
        Ok(settings)
    }
}
