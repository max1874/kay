//! Keeping the installed copy current, quietly, as Sparkle does on the Mac: a check a day against `latest.json`
//! (tauri.conf.json, `plugins.updater`), a download in the background, and the install as soon as Kay is not
//! dictating. An update is refused unless it is signed with the key whose public half is in tauri.conf.json.

use std::{
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
    time::Duration,
};

use tauri_plugin_updater::UpdaterExt;

use crate::{kay::Kay, log};

static CHECKING: AtomicBool = AtomicBool::new(false);

pub fn start(kay: Arc<Kay>) {
    tauri::async_runtime::spawn(async move {
        // Not in the rush of a login.
        tokio::time::sleep(Duration::from_secs(60)).await;
        loop {
            if let Err(e) = check(&kay).await {
                log::error(format!("update check failed: {e}"));
            }
            tokio::time::sleep(Duration::from_secs(24 * 3600)).await;
        }
    });
}

/// The version being installed, or None when this one is current. Installing ends this process: the installer
/// replaces Kay and starts it again.
pub async fn check(kay: &Arc<Kay>) -> Result<Option<String>, String> {
    if CHECKING.swap(true, Ordering::SeqCst) {
        return Err("a check is already running".into());
    }
    let result = install(kay).await.map_err(|e| e.to_string());
    CHECKING.store(false, Ordering::SeqCst);
    result
}

async fn install(kay: &Arc<Kay>) -> tauri_plugin_updater::Result<Option<String>> {
    let Some(update) = kay.app.updater()?.check().await? else { return Ok(None) };
    log::notice(format!("update {} found, downloading", update.version));
    let bytes = update.download(|_, _| {}, || {}).await?;
    // Never in the middle of a dictation: the text would be lost with the process.
    kay.idle(Duration::MAX).await;
    log::notice(format!("installing {}", update.version));
    kay.media.resume_before_quit(Duration::from_millis(1500));
    update.install(bytes)?;
    Ok(Some(update.version))
}
