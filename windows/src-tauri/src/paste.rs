//! Puts text at the cursor through the clipboard and a simulated Ctrl+V, then puts back what the clipboard held.
//!
//! Failure class carried over from the Mac (1.5.13), read before changing anything here: the clipboard Kay saves
//! belongs to another app, and reading it can wait on that app. A format can be rendered only when someone asks
//! for it, and Windows asks the owning app then, synchronously; an app that doesn't answer holds the reader. So
//! the dictated text never waits for the old clipboard longer than `SNAPSHOT_BUDGET`; past that it is given up.

use std::{
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};

use windows::{
    core::{w, PCWSTR},
    Win32::{
        Foundation::{GlobalFree, HANDLE, HGLOBAL},
        System::{
            DataExchange::{
                CloseClipboard, EmptyClipboard, EnumClipboardFormats, GetClipboardData, GetClipboardSequenceNumber,
                OpenClipboard, RegisterClipboardFormatW, SetClipboardData,
            },
            Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE},
            Ole::CF_UNICODETEXT,
        },
        UI::Input::KeyboardAndMouse::{KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP, VK_CONTROL, VK_V},
    },
};

use crate::{hotkey, log};

/// How long the old clipboard may hold up the paste. A plain copy reads in a few milliseconds.
const SNAPSHOT_BUDGET: Duration = Duration::from_millis(250);
/// How long the app in front gets to read the pasted text before the old clipboard goes back.
const RESTORE_AFTER: Duration = Duration::from_millis(500);

type Items = Vec<(u32, Vec<u8>)>;

/// Blocks until Ctrl+V is sent (the old clipboard goes back on a thread of its own). `in_history` false
/// marks the text so clipboard history leaves it out; the old clipboard put back afterwards is always marked,
/// since it is already there and not a new copy. False when the text didn't reach the clipboard.
pub fn insert(text: &str, in_history: bool) -> bool {
    let before = sequence();
    let started = Instant::now();
    let saved = snapshot();
    let waited = started.elapsed().as_millis();
    if saved.is_none() {
        log::notice(format!("the clipboard didn't read within {waited} ms; pasting without restoring it"));
    }
    // Someone wrote to it while it was being read: what was read is no longer what they have there.
    let restore = saved.filter(|_| sequence() == before);

    let mut items: Items = vec![(CF_UNICODETEXT.0 as u32, text.encode_utf16().chain([0]).flat_map(u16::to_le_bytes).collect())];
    if !in_history {
        items.extend(skip_history());
    }
    if !write(&items) {
        log::error("the clipboard couldn't be written");
        return false;
    }
    let ours = sequence();
    let none = KEYBD_EVENT_FLAGS(0);
    let sent = hotkey::send(&[
        hotkey::input(VK_CONTROL, 0, none),
        hotkey::input(VK_V, 0, none),
        hotkey::input(VK_V, 0, KEYEVENTF_KEYUP),
        hotkey::input(VK_CONTROL, 0, KEYEVENTF_KEYUP),
    ]);
    log::notice(format!("pasted after {waited} ms on the clipboard{}", if sent { "" } else { "; Ctrl+V not sent" }));

    if let Some(mut restore) = restore {
        thread::spawn(move || {
            thread::sleep(RESTORE_AFTER);
            // Copied something else meanwhile: that stays.
            if sequence() == ours {
                restore.extend(skip_history());
                write(&restore);
            }
        });
    }
    true
}

/// Puts `text` on the clipboard and nothing else: History's Copy.
pub fn copy(text: &str) -> bool {
    write(&vec![(CF_UNICODETEXT.0 as u32, text.encode_utf16().chain([0]).flat_map(u16::to_le_bytes).collect())])
}

fn sequence() -> u32 {
    unsafe { GetClipboardSequenceNumber() }
}

/// Every format on the clipboard that is plain memory, or None past the budget. Past it the read goes on in the
/// background until the owning app answers, and its result is dropped.
fn snapshot() -> Option<Items> {
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let _ = tx.send(read());
    });
    rx.recv_timeout(SNAPSHOT_BUDGET).ok().flatten()
}

fn read() -> Option<Items> {
    let _open = Open::new()?;
    let mut items = Items::new();
    let mut format = 0;
    unsafe {
        loop {
            format = EnumClipboardFormats(format);
            if format == 0 {
                break;
            }
            if !in_memory(format) {
                continue;
            }
            let Ok(handle) = GetClipboardData(format) else { continue };
            let memory = HGLOBAL(handle.0);
            let data = GlobalLock(memory) as *const u8;
            if data.is_null() {
                continue;
            }
            items.push((format, std::slice::from_raw_parts(data, GlobalSize(memory)).to_vec()));
            let _ = GlobalUnlock(memory);
        }
    }
    Some(items)
}

/// Formats whose data is a GDI object or private to the app that put it there can't be copied byte for byte. The
/// bitmap and metafile ones also come as memory (CF_DIB, CF_DIBV5), which is what goes back.
fn in_memory(format: u32) -> bool {
    !matches!(format, 2 | 3 | 9 | 14 | 0x80 | 0x82 | 0x83 | 0x8E) && !(0x200..=0x3FF).contains(&format)
}

fn write(items: &Items) -> bool {
    let Some(_open) = Open::new() else { return false };
    unsafe { EmptyClipboard().is_ok() && items.iter().all(|(format, data)| set(*format, data)) }
}

unsafe fn set(format: u32, data: &[u8]) -> bool {
    let Ok(memory) = GlobalAlloc(GMEM_MOVEABLE, data.len().max(1)) else { return false };
    let target = GlobalLock(memory) as *mut u8;
    if target.is_null() {
        let _ = GlobalFree(Some(memory));
        return false;
    }
    std::ptr::copy_nonoverlapping(data.as_ptr(), target, data.len());
    let _ = GlobalUnlock(memory);
    // Once it is set, the memory is the clipboard's.
    if SetClipboardData(format, Some(HANDLE(memory.0))).is_err() {
        let _ = GlobalFree(Some(memory));
        return false;
    }
    true
}

/// The markers clipboard history skips: Windows' own (Win+V and the cloud clipboard), and the one Ditto and other
/// clipboard managers read.
fn skip_history() -> Items {
    let zero = 0u32.to_le_bytes().to_vec();
    let marker = |name: PCWSTR, data: Vec<u8>| (unsafe { RegisterClipboardFormatW(name) }, data);
    vec![
        marker(w!("ExcludeClipboardContentFromMonitorProcessing"), zero.clone()),
        marker(w!("CanIncludeInClipboardHistory"), zero.clone()),
        marker(w!("CanUploadToCloudClipboard"), zero.clone()),
        marker(w!("Clipboard Viewer Ignore"), zero),
    ]
}

/// The clipboard, open until dropped. Another app may have it open for a moment, so opening is tried for 200 ms.
struct Open;

impl Open {
    fn new() -> Option<Open> {
        for _ in 0..20 {
            if unsafe { OpenClipboard(None) }.is_ok() {
                return Some(Open);
            }
            thread::sleep(Duration::from_millis(10));
        }
        None
    }
}

impl Drop for Open {
    fn drop(&mut self) {
        let _ = unsafe { CloseClipboard() };
    }
}
