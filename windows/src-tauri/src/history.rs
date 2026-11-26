//! Every dictation, and the reason when one failed, in `%APPDATA%\Kay\history.json` (the last 1000), with the
//! Mac's fields.

use std::fs;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const LIMIT: usize = 1000;

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: Uuid,
    pub date: DateTime<Utc>,
    pub text: String,
    pub audio_seconds: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub latency_ms: Option<u64>,
    /// Set when recognition failed; `text` is empty then.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    /// The speech service that recognized it.
    pub engine: String,
    /// The microphone it was recorded from, by name; none for a dictation recovered at launch.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub microphone: Option<String>,
    /// What the recognizer heard, when the vocabulary or correction changed it; `text` is what was pasted.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub heard: Option<String>,
    /// How long correction took, when it ran; part of `latency_ms`.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub correction_ms: Option<u64>,
}

impl Entry {
    pub fn new(date: DateTime<Utc>, engine: &str, audio_seconds: f64) -> Entry {
        Entry {
            id: Uuid::new_v4(),
            date,
            text: String::new(),
            audio_seconds,
            latency_ms: None,
            error: None,
            engine: engine.into(),
            microphone: None,
            heard: None,
            correction_ms: None,
        }
    }
}

pub fn path() -> std::path::PathBuf {
    crate::files::data().join("history.json")
}

pub fn load() -> Vec<Entry> {
    fs::read(path()).ok().and_then(|data| serde_json::from_slice(&data).ok()).unwrap_or_default()
}

/// Written to a temporary file first, so a crash mid-write never leaves half a history.
pub fn save(entries: &[Entry]) {
    let _ = fs::create_dir_all(crate::files::data());
    let Ok(data) = serde_json::to_vec(&entries[..entries.len().min(LIMIT)]) else { return };
    let temporary = path().with_extension("json.tmp");
    if let Err(e) = fs::write(&temporary, data).and_then(|_| fs::rename(&temporary, path())) {
        crate::log::error(format!("history not saved: {e}"));
    }
}
