//! The speech services Kay dictates with, using the user's own keys, and one recognition task per press.

pub mod doubao;
pub mod qwen;

use std::{fmt, sync::Arc, time::Duration};

use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite;

use crate::{
    credentials::Account,
    i18n::t,
    keys::{Key, KeyState},
    kay::Kay,
};

#[derive(Clone, Debug)]
pub struct KayError {
    pub message: String,
    pub status: Option<u16>,
    /// What the service itself said, for the log only: the HUD shows `message`.
    pub detail: Option<String>,
}

impl KayError {
    pub fn new(message: impl Into<String>) -> KayError {
        KayError { message: message.into(), status: None, detail: None }
    }

    pub fn is_auth_failure(&self) -> bool {
        matches!(self.status, Some(401 | 403))
    }

    /// The message, and for the log what the service said.
    pub fn logged(&self) -> String {
        match &self.detail {
            Some(detail) => format!("{} [{detail}]", self.message),
            None => self.message.clone(),
        }
    }
}

impl fmt::Display for KayError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

/// The HTTP status a WebSocket upgrade was refused with, if that is what failed.
fn refused(error: &tungstenite::Error) -> Option<u16> {
    match error {
        tungstenite::Error::Http(response) => Some(response.status().as_u16()),
        _ => None,
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Provider {
    Qwen,
    Doubao,
}

impl Provider {
    pub const ALL: [Provider; 2] = [Provider::Qwen, Provider::Doubao];

    pub fn account(self) -> Account {
        match self {
            Provider::Qwen => Account::Dashscope,
            Provider::Doubao => Account::Volcengine,
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            Provider::Qwen => "qwen",
            Provider::Doubao => "doubao",
        }
    }
}

/// Each provider's key, and the latest pick still being checked.
pub struct Speech {
    keys: [Key; 2],
    pending: Option<Provider>,
}

impl Speech {
    pub fn load() -> Speech {
        Speech { keys: Provider::ALL.map(|p| Key::load(p.account())), pending: None }
    }

    pub fn key(&self, provider: Provider) -> &Key {
        &self.keys[provider as usize]
    }

    pub fn key_mut(&mut self, provider: Provider) -> &mut Key {
        &mut self.keys[provider as usize]
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderState {
    pub provider: Provider,
    #[serde(flatten)]
    pub key: KeyState,
    pub has_key: bool,
    /// Qwen's workspace URL or Doubao's resource.
    pub setting: String,
}

pub enum Input {
    Audio(Vec<u8>),
    Finish(Vec<u8>),
}

/// One press, one recognition task. Audio sent before the service is ready waits in order; a failure while the
/// key is still held is kept for the release.
pub struct Session {
    input: mpsc::UnboundedSender<Input>,
    result: oneshot::Receiver<Result<String, KayError>>,
    _task: AbortOnDrop,
}

/// Where the microphone sends its packets.
#[derive(Clone)]
pub struct AudioSink(mpsc::UnboundedSender<Input>);

impl AudioSink {
    pub fn send(&self, pcm: Vec<u8>) {
        let _ = self.0.send(Input::Audio(pcm));
    }
}

/// Dropping a session (a cancel) ends its task and closes its socket.
struct AbortOnDrop(tauri::async_runtime::JoinHandle<()>);

impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

impl Session {
    pub fn audio(&self) -> AudioSink {
        AudioSink(self.input.clone())
    }

    /// Sends the last audio, ends the task and waits at most `timeout` for the text.
    pub async fn finish(self, last: Vec<u8>, timeout: Duration) -> Result<String, KayError> {
        let Session { input, result, _task } = self;
        let _ = input.send(Input::Finish(last));
        match tokio::time::timeout(timeout, result).await {
            Ok(Ok(outcome)) => outcome,
            Ok(Err(_)) => Err(KayError::new(t("Recognition timed out."))),
            Err(_) => Err(KayError::new(t("Recognition timed out."))),
        }
    }
}

impl Kay {
    pub fn provider(&self) -> Provider {
        self.settings.lock().unwrap().speech.provider
    }

    pub fn setting(&self, provider: Provider) -> String {
        let settings = self.settings.lock().unwrap();
        match provider {
            Provider::Qwen => settings.speech.qwen_workspace_url.clone(),
            Provider::Doubao => settings.speech.doubao_resource.clone(),
        }
    }

    pub fn speech_states(&self) -> Vec<ProviderState> {
        let speech = self.speech.lock().unwrap();
        Provider::ALL
            .map(|provider| ProviderState {
                provider,
                key: speech.key(provider).state(),
                has_key: speech.key(provider).value.is_some(),
                setting: self.setting(provider),
            })
            .into()
    }

    pub fn speech_usable(&self) -> bool {
        self.speech.lock().unwrap().key(self.provider()).status.is_usable()
    }

    /// A recognition task for the chosen provider, already connecting, or None when it has no key.
    pub fn session(&self, provider: Provider) -> Option<Session> {
        let key = self.speech.lock().unwrap().key(provider).value.clone()?;
        let setting = self.setting(provider);
        let (input, audio) = mpsc::unbounded_channel();
        let (done, result) = oneshot::channel();
        let task = tauri::async_runtime::spawn(async move {
            let outcome = match provider {
                Provider::Qwen => qwen::run(&key, &setting, audio).await,
                Provider::Doubao => doubao::run(&key, &setting, audio).await,
            };
            let _ = done.send(outcome);
        });
        Some(Session { input, result, _task: AbortOnDrop(task) })
    }

    /// Dictate with `provider` from the next press on, once its key is known to work: a key that hasn't passed a
    /// test since launch is tested first, and dictation stays where it was if it fails. A provider without a key
    /// can't be chosen. Only the latest pick counts.
    pub fn select(self: &Arc<Self>, provider: Provider) {
        let connected = {
            let mut speech = self.speech.lock().unwrap();
            speech.pending = Some(provider);
            if provider == self.provider() || speech.key(provider).value.is_none() {
                speech.pending = None;
                return;
            }
            matches!(speech.key(provider).status, crate::keys::Status::Connected { .. })
        };
        if connected {
            return self.adopt(provider);
        }
        let kay = self.clone();
        tauri::async_runtime::spawn(async move {
            kay.test(provider, None, None).await;
            let speech = kay.speech.lock().unwrap();
            let ok = speech.pending == Some(provider)
                && matches!(speech.key(provider).status, crate::keys::Status::Connected { .. });
            drop(speech);
            if ok {
                kay.adopt(provider);
            }
        });
    }

    fn adopt(&self, provider: Provider) {
        self.speech.lock().unwrap().pending = None;
        let mut settings = self.settings.lock().unwrap();
        settings.speech.provider = provider;
        settings.save();
        drop(settings);
        crate::log::notice(format!("dictating with {}", provider.id()));
        self.changed();
    }

    /// Verifies the service with `new_key` (or the stored one) and `new_setting` (or the current one) before
    /// adopting either: a failed replacement leaves the current configuration working.
    pub async fn test(self: &Arc<Self>, provider: Provider, new_key: Option<String>, new_setting: Option<String>) {
        let current = self.setting(provider);
        let setting = new_setting.map(|s| s.trim().to_string()).unwrap_or_else(|| current.clone());
        let Some(trial) = self.speech.lock().unwrap().key_mut(provider).begin(new_key.as_deref(), setting != current)
        else {
            return;
        };
        self.changed();
        let outcome = match provider {
            Provider::Qwen => qwen::verify(&trial.key, &setting).await,
            Provider::Doubao => doubao::verify(&trial.key, &setting).await,
        };
        let adopted = self.speech.lock().unwrap().key_mut(provider).finish(trial, outcome);
        if adopted {
            let mut settings = self.settings.lock().unwrap();
            match provider {
                Provider::Qwen => settings.speech.qwen_workspace_url = setting,
                Provider::Doubao => settings.speech.doubao_resource = setting,
            }
            settings.save();
        }
        self.changed();
    }

    /// Deletes the key. Dictation stays on this provider, now without a key, until another is chosen.
    pub fn remove_key(&self, provider: Provider) {
        self.speech.lock().unwrap().key_mut(provider).remove();
        self.changed();
    }

    pub fn clear_candidate_error(&self, provider: Provider) {
        self.speech.lock().unwrap().key_mut(provider).candidate_error = None;
        self.changed();
    }
}
