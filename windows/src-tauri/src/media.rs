//! Pauses what is playing while you dictate with the sound coming out of speakers, and plays it again once the
//! dictation is over; with headphones nothing changes, since the microphone doesn't hear them. Windows' media
//! sessions (the ones its volume flyout shows: browsers, Spotify, the Media Player) say what plays and take the
//! commands.
//!
//! Never a blind play/pause key: on the Mac a play sent to a paused player started it (2026-10-18). So Kay pauses
//! only sessions it has just read as playing, and plays only what it paused, when that is still the same item and
//! still paused. Everything runs on a thread of its own, each call given 2 s: a player can be slow to answer.

use std::{sync::mpsc, thread, time::Duration};

use windows::Media::Control::{
    GlobalSystemMediaTransportControlsSession as Session,
    GlobalSystemMediaTransportControlsSessionManager as Manager,
    GlobalSystemMediaTransportControlsSessionPlaybackStatus as Playback,
};

use crate::{audio, log};

enum Command {
    Pause,
    Resume,
    /// Answered once everything before it is done.
    Flush(mpsc::Sender<()>),
}

pub struct MediaPause(mpsc::Sender<Command>);

/// A paused session and what it was playing.
struct Paused {
    session: Session,
    item: (String, String, String),
}

impl MediaPause {
    pub fn start() -> MediaPause {
        let (tx, rx) = mpsc::channel();
        thread::Builder::new()
            .name("kay-media".into())
            .spawn(move || {
                audio::com();
                let runtime = tokio::runtime::Builder::new_current_thread().enable_time().build().expect("runtime");
                let mut paused: Vec<Paused> = Vec::new();
                for command in rx {
                    match command {
                        Command::Pause if paused.is_empty() => paused = runtime.block_on(pause()),
                        Command::Resume => runtime.block_on(resume(std::mem::take(&mut paused))),
                        Command::Flush(done) => drop(done.send(())),
                        Command::Pause => {}
                    }
                }
            })
            .expect("media thread starts");
        MediaPause(tx)
    }

    pub fn pause(&self) {
        let _ = self.0.send(Command::Pause);
    }

    pub fn resume(&self) {
        let _ = self.0.send(Command::Resume);
    }

    /// Before Kay quits: plays what it paused and waits for that, at most `timeout`, so a quit during a dictation (an
    /// update, logging off) doesn't leave it paused.
    pub fn resume_before_quit(&self, timeout: Duration) {
        self.resume();
        let (tx, rx) = mpsc::channel();
        let _ = self.0.send(Command::Flush(tx));
        let _ = rx.recv_timeout(timeout);
    }
}

async fn within<T>(operation: impl std::future::IntoFuture<Output = windows::core::Result<T>>) -> Option<T> {
    tokio::time::timeout(Duration::from_secs(2), operation.into_future()).await.ok()?.ok()
}

async fn sessions() -> Vec<Session> {
    let Some(manager) = (match Manager::RequestAsync() {
        Ok(request) => within(request).await,
        Err(_) => None,
    }) else {
        return vec![];
    };
    let Ok(list) = manager.GetSessions() else { return vec![] };
    (0..list.Size().unwrap_or(0)).filter_map(|i| list.GetAt(i).ok()).collect()
}

fn status(session: &Session) -> Option<Playback> {
    session.GetPlaybackInfo().and_then(|info| info.PlaybackStatus()).ok()
}

async fn item(session: &Session) -> Option<(String, String, String)> {
    let properties = within(session.TryGetMediaPropertiesAsync().ok()?).await?;
    Some((
        session.SourceAppUserModelId().ok()?.to_string(),
        properties.Title().map(|s| s.to_string()).unwrap_or_default(),
        properties.Artist().map(|s| s.to_string()).unwrap_or_default(),
    ))
}

async fn pause() -> Vec<Paused> {
    if let Some(output) = audio::headphones() {
        log::notice(format!("media: left playing, output is {output}"));
        return vec![];
    }
    let mut paused = Vec::new();
    for session in sessions().await {
        if status(&session) != Some(Playback::Playing) {
            continue;
        }
        let Some(item) = item(&session).await else { continue };
        // Remembered before sending: a pause that times out may still have paused it, and `resume` plays it only if
        // it is still this item and paused, so remembering too much is safe.
        let sent = match session.TryPauseAsync() {
            Ok(request) => within(request).await.unwrap_or(false),
            Err(_) => false,
        };
        log::notice(format!("media: {} {}", if sent { "paused" } else { "pause may not have reached" }, item.0));
        paused.push(Paused { session, item });
    }
    paused
}

async fn resume(paused: Vec<Paused>) {
    for Paused { session, item: was } in paused {
        if status(&session) != Some(Playback::Paused) || item(&session).await.as_ref() != Some(&was) {
            log::notice(format!("media: not resumed, {} changed meanwhile", was.0));
            continue;
        }
        let played = match session.TryPlayAsync() {
            Ok(request) => within(request).await.unwrap_or(false),
            Err(_) => false,
        };
        log::notice(format!("media: {} {}", if played { "resumed" } else { "play not sent to" }, was.0));
    }
}
