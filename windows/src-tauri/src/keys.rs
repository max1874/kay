//! A stored API key and whether it works: what Home's checklist, the Speech Service and Correction panes and
//! dictation failures all read and write. A replacement key that fails its test is kept apart from the status,
//! which describes the stored key: a typo in a new key must not make Kay look broken while the saved one works.

use serde::Serialize;

use crate::{
    credentials::{self, Account},
    i18n::t,
};

#[derive(Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Status {
    NotSet,
    /// Stored, and not checked since launch or since its setting changed.
    Saved,
    Testing,
    Connected { ms: u64 },
    Failed { message: String },
}

impl Status {
    pub fn is_usable(&self) -> bool {
        matches!(self, Status::Saved | Status::Connected { .. })
    }
}

pub struct Key {
    account: Account,
    /// Cached so a key press never waits on Credential Manager.
    pub value: Option<String>,
    pub status: Status,
    pub candidate_error: Option<String>,
}

/// A test under way: the key tried, and what to go back to if it fails.
pub struct Trial {
    pub key: String,
    stored: Option<String>,
    replacement: bool,
    previous: Status,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KeyState {
    pub status: Status,
    pub masked_key: Option<String>,
    pub candidate_error: Option<String>,
}

impl Key {
    pub fn load(account: Account) -> Key {
        let value = credentials::get(account);
        let status = if value.is_some() { Status::Saved } else { Status::NotSet };
        Key { account, value, status, candidate_error: None }
    }

    pub fn state(&self) -> KeyState {
        KeyState {
            status: self.status.clone(),
            masked_key: self.value.as_deref().map(credentials::mask),
            candidate_error: self.candidate_error.clone(),
        }
    }

    /// Starts testing `new_key`, or the stored key when there is none; `setting_changed` when the test is also for
    /// a new setting of the stored key. None while a test runs or with no key at all.
    pub fn begin(&mut self, new_key: Option<&str>, setting_changed: bool) -> Option<Trial> {
        if self.status == Status::Testing {
            return None;
        }
        let key = new_key.or(self.value.as_deref()).unwrap_or("").trim().to_string();
        if key.is_empty() {
            return None;
        }
        let trial = Trial {
            replacement: self.value.is_some() && (Some(key.as_str()) != self.value.as_deref() || setting_changed),
            key,
            stored: self.value.clone(),
            previous: std::mem::replace(&mut self.status, Status::Testing),
        };
        self.candidate_error = None;
        Some(trial)
    }

    /// Ends `trial` with how the service answered; true when the key (and its setting) now count.
    pub fn finish(&mut self, trial: Trial, outcome: Result<u64, String>) -> bool {
        // Removed while the test ran: the removal wins, whatever the test found.
        if self.value != trial.stored {
            if self.value.is_none() {
                self.status = Status::NotSet;
            }
            return false;
        }
        let outcome = outcome.and_then(|ms| {
            if Some(&trial.key) == self.value.as_ref() || credentials::set(self.account, &trial.key) {
                Ok(ms)
            } else {
                Err(t("The key works, but Kay couldn't save it to Credential Manager."))
            }
        });
        match outcome {
            Ok(ms) => {
                self.value = Some(trial.key);
                self.status = Status::Connected { ms };
                true
            }
            Err(message) if trial.replacement => {
                self.candidate_error = Some(message);
                self.status = trial.previous;
                false
            }
            Err(message) => {
                self.status = Status::Failed { message };
                false
            }
        }
    }

    pub fn remove(&mut self) {
        credentials::set(self.account, "");
        self.value = None;
        self.status = Status::NotSet;
        self.candidate_error = None;
    }

    /// Dictation or correction hit an authentication error with the stored key.
    pub fn mark_failed(&mut self, message: String) {
        if self.value.is_some() {
            self.status = Status::Failed { message };
        }
    }
}
