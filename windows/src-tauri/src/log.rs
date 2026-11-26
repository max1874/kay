//! `%LOCALAPPDATA%\Kay\Logs\kay.log`: each dictation's microphone, timings and outcome, never its text. Four files
//! of 2 MB (a dictation writes under 1 kB): kay.log, then kay.1.log … kay.3.log, oldest last. A line is on disk
//! once the call returns, so a crash leaves what led up to it.

use std::{
    fs::{self, File, OpenOptions},
    io::Write,
    sync::Mutex,
};

const MAX_BYTES: u64 = 2_000_000;
const KEEP: usize = 3;

static FILE: Mutex<Option<(File, u64)>> = Mutex::new(None);

pub fn notice(message: impl AsRef<str>) {
    append(message.as_ref());
}

pub fn error(message: impl AsRef<str>) {
    append(&format!("error: {}", message.as_ref()));
}

fn append(message: &str) {
    let line = format!(
        "{} [{}] {message}\n",
        chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f"),
        std::process::id()
    );
    #[cfg(debug_assertions)]
    eprint!("{line}");
    let mut file = FILE.lock().unwrap_or_else(|e| e.into_inner());
    if file.is_none() {
        *file = open();
    }
    let Some((handle, written)) = file.as_mut() else { return };
    if handle.write_all(line.as_bytes()).is_ok() {
        *written += line.len() as u64;
    }
    if *written > MAX_BYTES {
        *file = None;
        rotate();
    }
}

fn open() -> Option<(File, u64)> {
    let dir = crate::files::logs();
    fs::create_dir_all(&dir).ok()?;
    // Append mode: during an update the Kay that is quitting and the one starting both write here.
    let file = OpenOptions::new().create(true).append(true).open(dir.join("kay.log")).ok()?;
    let written = file.metadata().map(|m| m.len()).unwrap_or(0);
    Some((file, written))
}

fn rotate() {
    let dir = crate::files::logs();
    let numbered = |n: usize| dir.join(format!("kay.{n}.log"));
    let _ = fs::remove_file(numbered(KEEP));
    for n in (1..KEEP).rev() {
        let _ = fs::rename(numbered(n), numbered(n + 1));
    }
    let _ = fs::rename(dir.join("kay.log"), numbered(1));
}
