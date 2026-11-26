//! Where Kay keeps things: `%APPDATA%\Kay` for what is yours (history, recent audio, vocabulary, settings), the
//! counterpart of `~/Library/Application Support/Kay` on the Mac, and `%LOCALAPPDATA%\Kay` for logs.

use std::{env, path::PathBuf};

fn under(variable: &str) -> PathBuf {
    PathBuf::from(env::var_os(variable).unwrap_or_default()).join("Kay")
}

pub fn data() -> PathBuf {
    under("APPDATA")
}

pub fn logs() -> PathBuf {
    under("LOCALAPPDATA").join("Logs")
}
