//! What the window, the tray, the hook and the dictation share: settings, keys, history and the dictation state.
//! The dictation itself is driven by one task (`dictation::run`); everything else reads this and is told of changes
//! through the `changed` and `history` events.

use std::{
    sync::{Arc, Mutex},
    time::Duration,
};

use serde::Serialize;
use tauri::{AppHandle, Emitter};
use tokio::sync::{mpsc, watch};

use crate::{
    credentials::Account,
    dictation::Event,
    history::{self, Entry},
    hud::Hud,
    keys::Key,
    log,
    media::MediaPause,
    pending,
    settings::Settings,
    speech::Speech,
};

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Idle,
    Recording,
    Processing,
}

pub struct Kay {
    pub app: AppHandle,
    pub settings: Mutex<Settings>,
    pub speech: Mutex<Speech>,
    pub correction: Mutex<Key>,
    pub history: Mutex<Vec<Entry>>,
    pub state: watch::Sender<State>,
    pub hud: Hud,
    pub media: MediaPause,
    pub events: mpsc::UnboundedSender<Event>,
}

impl Kay {
    pub fn new(app: AppHandle, events: mpsc::UnboundedSender<Event>) -> Kay {
        Kay {
            hud: Hud::new(app.clone()),
            app,
            settings: Mutex::new(Settings::load()),
            speech: Mutex::new(Speech::load()),
            correction: Mutex::new(Key::load(Account::Deepseek)),
            history: Mutex::new(history::load()),
            state: watch::Sender::new(State::Idle),
            media: MediaPause::start(),
            events,
        }
    }

    /// Tells the window to read the status again.
    pub fn changed(&self) {
        let _ = self.app.emit_to("main", "changed", ());
    }

    pub fn state(&self) -> State {
        *self.state.borrow()
    }

    pub fn set_state(&self, state: State) {
        self.state.send_replace(state);
        if state == State::Idle {
            self.media.resume();
        }
        self.changed();
    }

    /// Resolves once nothing is being dictated, or after `limit`: an update or a quit never takes the words with it.
    pub async fn idle(&self, limit: Duration) {
        let mut state = self.state.subscribe();
        let _ = tokio::time::timeout(limit, state.wait_for(|s| *s == State::Idle)).await;
    }

    /// By date: a recovered dictation is older than the ones after it.
    pub fn record(&self, entry: Entry) {
        let mut history = self.history.lock().unwrap();
        let at = history.iter().position(|e| e.date < entry.date).unwrap_or(history.len());
        history.insert(at, entry);
        history.truncate(history::LIMIT);
        history::save(&history);
        drop(history);
        let _ = self.app.emit_to("main", "history", ());
    }

    pub fn delete(&self, id: uuid::Uuid) {
        let mut history = self.history.lock().unwrap();
        history.retain(|e| e.id != id);
        history::save(&history);
        drop(history);
        pending::forget(id);
        let _ = self.app.emit_to("main", "history", ());
    }

    pub fn clear_history(&self) {
        let mut history = self.history.lock().unwrap();
        history.clear();
        history::save(&history);
        drop(history);
        pending::forget_all();
        let _ = self.app.emit_to("main", "history", ());
    }

    /// A quit while dictating (an update, the tray menu) waits for the text to land, at most 60 s.
    pub fn quit(self: &Arc<Self>) {
        let kay = self.clone();
        tauri::async_runtime::spawn(async move {
            if kay.state() != State::Idle {
                log::notice("quit requested while dictating; quitting once it lands");
            }
            kay.idle(Duration::from_secs(60)).await;
            let media = kay.clone();
            let _ = tauri::async_runtime::spawn_blocking(move || media.media.resume_before_quit(Duration::from_millis(1500))).await;
            kay.app.exit(0);
        });
    }
}
