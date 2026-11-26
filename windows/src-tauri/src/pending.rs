//! The audio of a dictation in progress, kept on disk until its outcome is in history: the Mac's
//! `PendingDictation`.
//!
//! A process that ends between pressing the key and recording the result takes what was said with it (the Mac
//! crashed at exactly that point on every dictation for 27 hours, and an install that quit it mid-dictation lost
//! another). So the PCM sent to the speech service is also appended to `pending-<ms>.pcm`; recording the result,
//! text or error, or cancelling, deletes it. A file still there at launch is a dictation that never landed: Kay
//! recognizes it again and records it in history, without pasting, since the place it was meant for is gone.
//!
//! Once the outcome is in history, the audio of the last 20 dictations stays as `recent\<entry id>.wav`, so a
//! misrecognition can be played back or sent again. Deleting an entry or clearing history deletes its audio.

use std::{
    fs::{self, File},
    io::Write,
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use chrono::{DateTime, Utc};
use uuid::Uuid;

use crate::{audio::SAMPLE_RATE, files, log};

const PREFIX: &str = "pending-";
const RECENT: usize = 20;
/// Leftovers that keep failing (no key, no network) are retried at each launch, but not forever.
const KEEP_FOR: Duration = Duration::from_secs(7 * 24 * 3600);

#[derive(Clone)]
pub struct Pending {
    path: PathBuf,
    file: Arc<Mutex<Option<File>>>,
}

impl Pending {
    /// None if the file can't be made; dictation goes on without it.
    pub fn new() -> Option<Pending> {
        let ms = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_millis();
        let path = files::data().join(format!("{PREFIX}{ms}.pcm"));
        let file = fs::create_dir_all(files::data()).and_then(|_| File::create(&path));
        match file {
            Ok(file) => Some(Pending { path, file: Arc::new(Mutex::new(Some(file))) }),
            Err(e) => {
                log::error(format!("pending audio not kept: {e}"));
                None
            }
        }
    }

    /// Called from the recording thread as packets go out.
    pub fn append(&self, pcm: &[u8]) {
        if let Some(file) = self.file.lock().unwrap().as_mut() {
            let _ = file.write_all(pcm);
        }
    }

    /// There is no outcome to keep (cancelled, nothing heard): the audio is no longer needed.
    pub fn discard(self) {
        self.close();
        let _ = fs::remove_file(&self.path);
    }

    /// The outcome is in history as entry `id`: keep the audio under that id among the recent ones.
    pub fn keep(self, id: Uuid) {
        self.close();
        keep(&self.path, id);
    }

    fn close(&self) {
        self.file.lock().unwrap().take();
    }
}

fn recent() -> PathBuf {
    files::data().join("recent")
}

pub fn keep(pcm: &Path, id: Uuid) {
    if let Some(samples) = fs::read(pcm).ok().filter(|s| !s.is_empty()) {
        let dir = recent();
        let _ = fs::create_dir_all(&dir);
        let mut wav = wav_header(samples.len());
        wav.extend(samples);
        let _ = fs::write(dir.join(format!("{id}.wav")), wav);
        let mut files: Vec<_> = fs::read_dir(&dir)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
            .collect();
        files.sort_by(|a, b| b.0.cmp(&a.0));
        for (_, old) in files.into_iter().skip(RECENT) {
            let _ = fs::remove_file(old);
        }
    }
    let _ = fs::remove_file(pcm);
}

pub fn forget(id: Uuid) {
    let _ = fs::remove_file(recent().join(format!("{id}.wav")));
}

pub fn forget_all() {
    let _ = fs::remove_dir_all(recent());
}

/// 16 kHz, 16-bit, mono PCM: what the microphone produces and the speech service is sent.
fn wav_header(bytes: usize) -> Vec<u8> {
    let mut h = b"RIFF".to_vec();
    h.extend((36 + bytes as u32).to_le_bytes());
    h.extend(b"WAVEfmt ");
    h.extend(16u32.to_le_bytes());
    h.extend(1u16.to_le_bytes()); // PCM
    h.extend(1u16.to_le_bytes()); // mono
    h.extend((SAMPLE_RATE as u32).to_le_bytes());
    h.extend((SAMPLE_RATE as u32 * 2).to_le_bytes());
    h.extend(2u16.to_le_bytes());
    h.extend(16u16.to_le_bytes());
    h.extend(b"data");
    h.extend((bytes as u32).to_le_bytes());
    h
}

/// Dictations a previous run didn't finish, oldest first, with when they were started.
pub fn leftovers() -> Vec<(PathBuf, DateTime<Utc>)> {
    let mut found: Vec<_> = fs::read_dir(files::data())
        .into_iter()
        .flatten()
        .flatten()
        .filter_map(|entry| {
            let name = entry.file_name().into_string().ok()?;
            let ms: i64 = name.strip_prefix(PREFIX)?.strip_suffix(".pcm")?.parse().ok()?;
            let started = DateTime::from_timestamp_millis(ms)?;
            if (Utc::now() - started).to_std().is_ok_and(|age| age > KEEP_FOR) {
                let _ = fs::remove_file(entry.path());
                return None;
            }
            Some((entry.path(), started))
        })
        .collect();
    found.sort_by_key(|(_, started)| *started);
    found
}
