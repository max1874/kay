//! Holding a trigger dictates. A trigger is one or more modifier keys, told apart by side (Right Alt is not Left
//! Alt), since modifiers alone type nothing. Pressing any other key while one is held cancels, so Alt and Ctrl
//! shortcuts keep working.
//!
//! A low-level keyboard hook on a thread of its own sees keys in every app, without any permission. Windows drops
//! a hook whose callback is slow, so the callback only updates a few bits and hands the event on.
//!
//! Letting go of a modifier with no other key in between means something on Windows: Alt focuses the menu bar,
//! the Windows key opens Start, Shift switches a Chinese IME between Chinese and English. After a dictation that
//! would land the text in a menu, or in the wrong mode, so the release of a trigger is preceded by an unassigned
//! key (0xE8, as AutoHotkey does), and the press no longer looks like a tap.

use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use windows::Win32::{
    Foundation::{LPARAM, LRESULT, WPARAM},
    System::LibraryLoader::GetModuleHandleW,
    UI::{
        Input::KeyboardAndMouse::*,
        WindowsAndMessaging::{
            CallNextHookEx, GetMessageW, SetWindowsHookExW, UnhookWindowsHookEx, HC_ACTION, KBDLLHOOKSTRUCT,
            LLKHF_EXTENDED, MSG, WH_KEYBOARD_LL, WM_KEYDOWN, WM_SYSKEYDOWN,
        },
    },
};

use crate::i18n::t;

/// Marks the keys Kay sends itself (the mask key, Ctrl+V), so the hook lets them through untouched. Keys other
/// software sends, such as a remapper turning Caps Lock into Right Alt, still count.
pub const INJECTED: usize = 0x4B41_5900;

/// A set of modifier keys, one bit each in `KEYS` order.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(transparent)]
pub struct Trigger(pub u8);

const KEYS: [&str; 8] = [
    "Left Ctrl",
    "Right Ctrl",
    "Left Alt",
    "Right Alt",
    "Left Shift",
    "Right Shift",
    "Left Windows",
    "Right Windows",
];

impl Trigger {
    pub const RIGHT_ALT: Trigger = Trigger(1 << 3);

    /// The modifier a hooked key is, if it is one.
    fn of(key: &KBDLLHOOKSTRUCT) -> Option<Trigger> {
        let right = key.flags.contains(LLKHF_EXTENDED);
        let index = match VIRTUAL_KEY(key.vkCode as u16) {
            VK_LCONTROL => 0,
            VK_RCONTROL => 1,
            VK_LMENU => 2,
            VK_RMENU => 3,
            VK_LSHIFT => 4,
            VK_RSHIFT => 5,
            VK_LWIN => 6,
            VK_RWIN => 7,
            // The generic codes, which some keyboards and remappers send: the side is in the scan code.
            VK_CONTROL => right as usize,
            VK_MENU => 2 + right as usize,
            VK_SHIFT => 4 + (key.scanCode == 0x36) as usize,
            _ => return None,
        };
        Some(Trigger(1 << index))
    }

    pub fn is_empty(self) -> bool {
        self.0 == 0
    }

    fn is_subset(self, of: Trigger) -> bool {
        self.0 & !of.0 == 0
    }

    pub fn name(self) -> String {
        KEYS.iter()
            .enumerate()
            .filter(|(i, _)| self.0 & (1 << i) != 0)
            .map(|(_, name)| t(name))
            .collect::<Vec<_>>()
            .join(" + ")
    }
}

pub enum KeyEvent {
    Press,
    Release,
    Interrupt,
    /// While Settings records a new trigger: the keys pressed together so far, whether they are all up again (so
    /// the set is complete), and whether a key that isn't a modifier was typed instead.
    Recorded { keys: Trigger, complete: bool, typed: bool },
}

struct Hook {
    triggers: Vec<Trigger>,
    recording: bool,
    /// Every modifier down as of the last change.
    down: Trigger,
    /// The trigger being held, while one is.
    held: Option<Trigger>,
    recorded: Trigger,
    typed: bool,
    send: Box<dyn Fn(KeyEvent) + Send>,
}

static HOOK: Mutex<Option<Hook>> = Mutex::new(None);

pub fn start(triggers: Vec<Trigger>, send: impl Fn(KeyEvent) + Send + 'static) {
    *lock() = Some(Hook {
        triggers,
        recording: false,
        down: Trigger::default(),
        held: None,
        recorded: Trigger::default(),
        typed: false,
        send: Box::new(send),
    });
    std::thread::Builder::new()
        .name("kay-hotkey".into())
        .spawn(|| unsafe {
            let module = GetModuleHandleW(None).ok().map(Into::into);
            let hook = match SetWindowsHookExW(WH_KEYBOARD_LL, Some(callback), module, 0) {
                Ok(hook) => hook,
                Err(e) => return crate::log::error(format!("keyboard hook not installed: {e}")),
            };
            crate::log::notice("keyboard hook installed");
            // The hook runs inside this thread's message loop, which nothing ever ends.
            let mut message = MSG::default();
            while GetMessageW(&mut message, None, 0, 0).0 > 0 {}
            let _ = UnhookWindowsHookEx(hook);
        })
        .expect("hotkey thread starts");
}

/// A held trigger is cancelled: it may no longer be one.
pub fn set_triggers(triggers: Vec<Trigger>) {
    if let Some(hook) = lock().as_mut() {
        hook.triggers = triggers;
        hook.interrupt();
    }
}

/// While Settings records a trigger, keys are reported to it and nothing dictates.
pub fn set_recording(recording: bool) {
    if let Some(hook) = lock().as_mut() {
        hook.recording = recording;
        hook.recorded = Trigger::default();
        hook.typed = false;
        hook.interrupt();
    }
}

fn lock() -> std::sync::MutexGuard<'static, Option<Hook>> {
    HOOK.lock().unwrap_or_else(|e| e.into_inner())
}

unsafe extern "system" fn callback(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code == HC_ACTION as i32 {
        let key = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
        let down = matches!(wparam.0 as u32, WM_KEYDOWN | WM_SYSKEYDOWN);
        let release = key.dwExtraInfo != INJECTED && lock().as_mut().is_some_and(|hook| hook.handle(key, down));
        if release {
            // Swallowed and sent again behind the mask key, so the two arrive in that order.
            let up = if key.flags.contains(LLKHF_EXTENDED) { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) };
            send(&[
                input(VIRTUAL_KEY(0xE8), 0, KEYBD_EVENT_FLAGS(0)),
                input(VIRTUAL_KEY(0xE8), 0, KEYEVENTF_KEYUP),
                input(VIRTUAL_KEY(key.vkCode as u16), key.scanCode as u16, KEYEVENTF_KEYUP | up),
            ]);
            return LRESULT(1);
        }
    }
    CallNextHookEx(None, code, wparam, lparam)
}

impl Hook {
    /// Returns true for the key-up that ends a dictation, which the callback masks.
    fn handle(&mut self, key: &KBDLLHOOKSTRUCT, down: bool) -> bool {
        // Right Alt on layouts where it is AltGr comes with a Left Ctrl that no one pressed.
        if VIRTUAL_KEY(key.vkCode as u16) == VK_LCONTROL && key.scanCode == 0x21D {
            return false;
        }
        let Some(modifier) = Trigger::of(key) else {
            if down {
                if self.recording {
                    // Enter and Escape still press Add and Cancel; any other key is not one that can be held.
                    let vk = VIRTUAL_KEY(key.vkCode as u16);
                    if !(self.down.is_empty() && (vk == VK_RETURN || vk == VK_ESCAPE)) {
                        self.recorded = Trigger::default();
                        self.typed = true;
                        self.report();
                    }
                }
                self.interrupt();
            }
            return false;
        };
        let before = self.down;
        let now = if down { Trigger(before.0 | modifier.0) } else { Trigger(before.0 & !modifier.0) };
        // Held keys repeat their key-down.
        if now == before {
            return false;
        }
        self.down = now;
        if self.recording {
            if before.is_empty() {
                self.recorded = now;
                self.typed = false;
            } else {
                self.recorded.0 |= now.0;
            }
            self.report();
            return false;
        }
        // A trigger starts only as its last key goes down, so letting go of Ctrl in Ctrl+Shift never starts a
        // Shift trigger. Once held, letting go of one of its keys ends the dictation, and another modifier joining
        // cancels it, as another key does.
        if let Some(held) = self.held.take() {
            if now.is_subset(held) {
                (self.send)(KeyEvent::Release);
                return !down;
            }
            (self.send)(KeyEvent::Interrupt);
        } else if before.is_subset(now) && self.triggers.contains(&now) {
            self.held = Some(now);
            (self.send)(KeyEvent::Press);
        }
        false
    }

    fn report(&self) {
        (self.send)(KeyEvent::Recorded {
            keys: self.recorded,
            complete: self.down.is_empty() && !self.recorded.is_empty(),
            typed: self.typed,
        });
    }

    fn interrupt(&mut self) {
        if self.held.take().is_some() {
            (self.send)(KeyEvent::Interrupt);
        }
    }
}

pub fn input(vk: VIRTUAL_KEY, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT { wVk: vk, wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: INJECTED },
        },
    }
}

/// Whether Windows took all of them. It also says yes when the window in front runs as administrator and drops
/// them (UIPI), which Kay can't see.
pub fn send(inputs: &[INPUT]) -> bool {
    unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) as usize == inputs.len() }
}
