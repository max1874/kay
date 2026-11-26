//! Hold the key, speak, let go: the text lands at the cursor and in history. One task owns the dictation in
//! progress and takes events in order (key changes, the hold passing 0.3 s, a recognition landing), so a cancel and
//! a result can never both act on the same dictation.

use std::{
    sync::Arc,
    time::{Duration, Instant},
};

use chrono::Utc;
use tokio::sync::mpsc::UnboundedReceiver;

use crate::{
    audio::{self, Capture, CHUNK_BYTES},
    history::Entry,
    hotkey::KeyEvent,
    i18n::{t, tf},
    kay::{Kay, State},
    log, paste,
    pending::{self, Pending},
    speech::{KayError, Provider, Session},
    vocabulary::Vocabulary,
};

/// A shorter hold is a mistap, not a dictation.
const MIN_HOLD: Duration = Duration::from_millis(300);
/// How long a microphone gets to start before the next one is tried. A headset, Bluetooth ones especially, may
/// first have to switch profiles.
const MICROPHONE_TIMEOUT: Duration = Duration::from_secs(2);
const HEADSET_TIMEOUT: Duration = Duration::from_secs(8);

pub enum Event {
    Key(KeyEvent),
    /// The hold of dictation `id` stopped looking like a tap.
    HeldLong(u64),
    Landed(Landing),
}

pub struct Landing {
    id: u64,
    result: Result<String, KayError>,
    heard: Option<String>,
    correction_ms: Option<u64>,
    latency: Duration,
}

struct Dictation {
    id: u64,
    provider: Provider,
    session: Option<Session>,
    capture: Option<Capture>,
    pending: Option<Pending>,
    pressed: Instant,
    microphone: String,
    seconds: f64,
}

pub async fn run(kay: Arc<Kay>, mut events: UnboundedReceiver<Event>) {
    let mut current: Option<Dictation> = None;
    let mut next_id = 0;
    while let Some(event) = events.recv().await {
        match event {
            Event::Key(KeyEvent::Press) => {
                if current.is_none() {
                    next_id += 1;
                    current = begin(&kay, next_id).await;
                }
            }
            Event::Key(KeyEvent::Release) => {
                if let Some(dictation) = current.as_mut().filter(|_| kay.state() == State::Recording) {
                    if !end(&kay, dictation).await {
                        cancel(&kay, current.take());
                    }
                }
            }
            Event::Key(KeyEvent::Interrupt) => cancel(&kay, current.take()),
            Event::Key(KeyEvent::Recorded { keys, complete, typed }) => {
                let recorded = serde_json::json!({"keys": keys, "name": keys.name(), "complete": complete, "typed": typed});
                let _ = tauri::Emitter::emit_to(&kay.app, "main", "recorded", recorded);
            }
            Event::HeldLong(id) => {
                let recording = current.as_ref().is_some_and(|d| d.id == id) && kay.state() == State::Recording;
                if recording && kay.settings.lock().unwrap().pause_media {
                    kay.media.pause();
                }
            }
            // By identity, not by state: after a cancel the next dictation may be processing, and its result is its own.
            Event::Landed(landing) => {
                if current.as_ref().is_some_and(|d| d.id == landing.id) {
                    deliver(&kay, current.take().unwrap(), landing).await;
                } else {
                    log::notice("result for a cancelled dictation dropped");
                }
            }
        }
    }
}

async fn begin(kay: &Arc<Kay>, id: u64) -> Option<Dictation> {
    let provider = kay.provider();
    let Some(session) = kay.session(provider) else {
        kay.hud.flash(t("No API key yet. Add one in Kay → Settings → Speech Service."), "key", 3.0);
        return None;
    };
    if !audio::microphone_allowed() {
        kay.hud.flash(t("Kay can't use the microphone. Allow it in Windows Settings."), "mic-off", 3.0);
        return None;
    }
    // The hold counts from the key, not from the microphone being ready: a key let go while a slow start was
    // waited for is a dictation to recognize, not a mistap to drop silently.
    let pressed = Instant::now();
    let pending = Pending::new();
    let chosen = kay.settings.lock().unwrap().microphone.clone();
    let microphones = tauri::async_runtime::spawn_blocking(move || {
        // The chosen microphone when it is connected, else the system default; then the default if the chosen one
        // doesn't start.
        let default = audio::default_microphone();
        let mut list: Vec<audio::Device> = audio::microphones().into_iter().filter(|d| d.id == chosen).collect();
        list.extend(default.filter(|d| d.id != chosen));
        list
    })
    .await
    .unwrap_or_default();
    log::notice(format!(
        "key down ({}); microphones to try: {}",
        provider.id(),
        microphones.iter().map(|d| d.name.as_str()).collect::<Vec<_>>().join(", ")
    ));

    let mut failure = KayError::new(t("No microphone input is available."));
    for microphone in microphones {
        let (audio, keep, levels) = (session.audio(), pending.clone(), kay.clone());
        let device = microphone.id.clone();
        let started = Instant::now();
        let capture = tauri::async_runtime::spawn_blocking(move || {
            let timeout = if audio::is_headset(&device) { HEADSET_TIMEOUT } else { MICROPHONE_TIMEOUT };
            Capture::start(
                &device,
                timeout,
                move |chunk| {
                    if let Some(pending) = &keep {
                        pending.append(&chunk);
                    }
                    audio.send(chunk);
                },
                move |level| levels.hud.level(level),
            )
        })
        .await
        .unwrap_or_else(|e| Err(KayError::new(e.to_string())));
        let ms = started.elapsed().as_millis();
        match capture {
            Ok(capture) => {
                log::notice(format!("recording from {}, started in {ms} ms", microphone.name));
                kay.set_state(State::Recording);
                kay.hud.listen();
                // Once the hold stops looking like a tap: Alt and Ctrl are also held for shortcuts, which cancel.
                let events = kay.events.clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(MIN_HOLD).await;
                    let _ = events.send(Event::HeldLong(id));
                });
                return Some(Dictation {
                    id,
                    provider,
                    session: Some(session),
                    capture: Some(capture),
                    pending,
                    pressed,
                    microphone: microphone.name,
                    seconds: 0.0,
                });
            }
            Err(e) => {
                log::error(format!("{} didn't start after {ms} ms: {}", microphone.name, e.message));
                failure = e;
            }
        }
    }
    if let Some(pending) = pending {
        pending.discard();
    }
    kay.hud.flash(tf("The microphone didn't start: {}", &failure.message), "mic-off", 3.0);
    None
}

/// False when the hold was a tap, to be cancelled.
async fn end(kay: &Arc<Kay>, dictation: &mut Dictation) -> bool {
    let (Some(capture), Some(session)) = (dictation.capture.take(), dictation.session.take()) else { return false };
    let (rest, seconds) = tauri::async_runtime::spawn_blocking(move || capture.stop()).await.unwrap_or_default();
    if let Some(pending) = &dictation.pending {
        pending.append(&rest);
    }
    let held = dictation.pressed.elapsed();
    if held < MIN_HOLD {
        log::notice(format!("key up after {} ms: too short", held.as_millis()));
        return false;
    }
    dictation.seconds = seconds;
    log::notice(format!("key up after {:.1} s, {:.1} s of audio", held.as_secs_f64(), dictation.seconds));
    kay.set_state(State::Processing);
    kay.hud.recognize();

    let (kay, id, released) = (kay.clone(), dictation.id, Instant::now());
    tauri::async_runtime::spawn(async move {
        let result = session.finish(rest, Duration::from_secs(10)).await;
        let (result, heard, correction_ms) = match result {
            Ok(raw) if !raw.trim().is_empty() => {
                let text = raw.trim().to_string();
                let (fixed, heard, ms) = refine(&kay, &text).await;
                (Ok(fixed), heard, ms)
            }
            other => (other, None, None),
        };
        let landing = Landing { id, result, heard, correction_ms, latency: released.elapsed() };
        let _ = kay.events.send(Event::Landed(landing));
    });
    true
}

/// Your vocabulary before DeepSeek, so it reads "CF" rather than "c f"; and again on its answer, which may have
/// re-spaced a term. The text, and what was heard when that differs, and how long correction took.
async fn refine(kay: &Kay, text: &str) -> (String, Option<String>, Option<u64>) {
    let vocabulary = Vocabulary::current();
    let replacements = vocabulary.replacements(text);
    if !replacements.is_empty() {
        log::notice(format!("vocabulary: {} replaced", replacements.len()));
    }
    let replaced = vocabulary.apply(&replacements, text);
    let (corrected, ms) = kay.correct(&replaced).await;
    let fixed = vocabulary.apply_all(corrected.as_deref().unwrap_or(&replaced));
    let heard = (fixed != text).then(|| text.to_string());
    (fixed, heard, ms)
}

async fn deliver(kay: &Arc<Kay>, dictation: Dictation, landing: Landing) {
    let Dictation { provider, pending, microphone, seconds, .. } = dictation;
    let ms = landing.latency.as_millis() as u64;
    let mut entry = Entry::new(Utc::now(), provider.id(), seconds);
    entry.microphone = Some(microphone);
    let text = match landing.result {
        Ok(text) => {
            let text = text.trim().to_string();
            log::notice(format!("final in {ms} ms, {} chars", text.chars().count()));
            if text.is_empty() {
                if let Some(pending) = pending {
                    pending.discard();
                }
                kay.set_state(State::Idle);
                return kay.hud.flash(t("Didn't catch that."), "ear", 2.0);
            }
            text
        }
        Err(error) => {
            log::error(format!("recognition failed ({}): {}", provider.id(), error.logged()));
            if error.is_auth_failure() {
                kay.speech.lock().unwrap().key_mut(provider).mark_failed(error.message.clone());
            }
            entry.error = Some(error.message.clone());
            kay.record(entry.clone());
            // Only after the outcome is recorded: a crash before that leaves the audio to recover.
            if let Some(pending) = pending {
                pending.keep(entry.id);
            }
            kay.set_state(State::Idle);
            return kay.hud.flash(error.message, "warning", 4.0);
        }
    };
    entry.text = text.clone();
    entry.latency_ms = Some(ms);
    entry.heard = landing.heard;
    entry.correction_ms = landing.correction_ms;
    kay.record(entry.clone());
    if let Some(pending) = pending {
        pending.keep(entry.id);
    }
    kay.hud.hide();
    let in_history = kay.settings.lock().unwrap().show_in_clipboard_history;
    // Idle only once Ctrl+V is out: a quit waits for that.
    let pasted = tauri::async_runtime::spawn_blocking(move || paste::insert(&text, in_history)).await;
    kay.set_state(State::Idle);
    if !matches!(pasted, Ok(true)) {
        kay.hud.flash(t("Kay couldn't paste. The dictation is in History."), "clipboard", 3.0);
    }
}

fn cancel(kay: &Kay, dictation: Option<Dictation>) {
    let Some(dictation) = dictation else { return };
    log::notice("dictation cancelled");
    // Dropping the capture stops it; dropping the session ends its task and socket.
    if let Some(pending) = dictation.pending {
        pending.discard();
    }
    kay.set_state(State::Idle);
    kay.hud.hide();
}

/// Dictations a previous run didn't finish, oldest first, one at a time, into history without pasting.
pub async fn recover(kay: Arc<Kay>) {
    let provider = kay.provider();
    for (path, started) in pending::leftovers() {
        let pcm = std::fs::read(&path).unwrap_or_default();
        if pcm.is_empty() {
            let _ = std::fs::remove_file(&path);
            continue;
        }
        let Some(session) = kay.session(provider) else { return };
        // The same 200 ms packets a live dictation sends, only without waiting between them.
        let mut chunks: Vec<&[u8]> = pcm.chunks(CHUNK_BYTES).collect();
        let last = chunks.pop().unwrap_or_default().to_vec();
        let audio = session.audio();
        for chunk in chunks {
            audio.send(chunk.to_vec());
        }
        let seconds = pcm.len() as f64 / (audio::SAMPLE_RATE * 2) as f64;
        match session.finish(last, Duration::from_secs(30)).await {
            Ok(raw) => {
                let text = raw.trim().to_string();
                log::notice(format!("recovered an unfinished dictation of {seconds:.1} s: {} chars", text.chars().count()));
                if text.is_empty() {
                    let _ = std::fs::remove_file(&path);
                    continue;
                }
                let mut entry = Entry::new(started, provider.id(), seconds);
                entry.text = text;
                kay.record(entry.clone());
                pending::keep(&path, entry.id);
                kay.hud.flash(t("Recovered a dictation Kay didn't finish. It's in History."), "recover", 3.0);
            }
            // Kept for the next launch: no network yet at login is the usual reason.
            Err(e) => log::error(format!("unfinished dictation not recovered yet: {}", e.message)),
        }
    }
}
