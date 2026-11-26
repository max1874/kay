//! The capsule above the taskbar while you dictate. It never takes focus or clicks: the text is about to land in
//! whatever app you are typing in, and that app has to stay in front.
//!
//! Its window is created once, hidden, at a fixed size, and only ever moved: on the Mac, resizing the panel while
//! its content changed crashed every dictation for 27 hours (1.4.4–1.5.2). The capsule inside changes; the window
//! doesn't. The page (`hud.html`) draws it and fades it in and out.

use std::{sync::Mutex, time::Duration};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, WebviewWindow};
use windows::Win32::UI::WindowsAndMessaging::{
    GetWindowLongPtrW, SetWindowLongPtrW, SetWindowPos, ShowWindow, GWL_EXSTYLE, HWND_TOPMOST, SWP_NOACTIVATE,
    SWP_NOMOVE, SWP_NOSIZE, SW_HIDE, SW_SHOWNOACTIVATE, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW,
    WS_EX_TRANSPARENT,
};

#[derive(Clone, PartialEq, Serialize)]
#[serde(tag = "mode", rename_all = "camelCase")]
pub enum Mode {
    /// Hidden: nothing that animates.
    Idle,
    Listening,
    Recognizing,
    Message { text: String, symbol: &'static str },
}

pub struct Hud {
    app: AppHandle,
    /// The mode shown, and a count of changes, so a delayed hide never hides what came after it.
    state: Mutex<(Mode, u64)>,
}

/// How far the capsule's window sits above the taskbar, in logical pixels: the Mac's 56 pt to the capsule,
/// less the 12 pt of shadow under it.
const ABOVE_TASKBAR: f64 = 44.0;

impl Hud {
    pub fn new(app: AppHandle) -> Hud {
        if let Some(window) = app.get_webview_window("hud") {
            // No activation, clicks fall through, not in Alt+Tab.
            if let Ok(hwnd) = window.hwnd() {
                unsafe {
                    let style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
                    let extra = WS_EX_NOACTIVATE.0 | WS_EX_TRANSPARENT.0 | WS_EX_LAYERED.0 | WS_EX_TOOLWINDOW.0;
                    SetWindowLongPtrW(hwnd, GWL_EXSTYLE, style | extra as isize);
                }
            }
        }
        Hud { app, state: Mutex::new((Mode::Idle, 0)) }
    }

    pub fn mode(&self) -> Mode {
        self.state.lock().unwrap().0.clone()
    }

    pub fn listen(&self) {
        self.present(Mode::Listening);
    }

    pub fn recognize(&self) {
        self.present(Mode::Recognizing);
    }

    pub fn flash(&self, text: String, symbol: &'static str, seconds: f64) {
        let generation = self.present(Mode::Message { text, symbol });
        self.later(Duration::from_secs_f64(seconds), generation, |hud| hud.hide());
    }

    /// From the recording thread, about 20 times a second; ignored unless listening.
    pub fn level(&self, value: f32) {
        if self.state.lock().unwrap().0 == Mode::Listening {
            let _ = self.app.emit_to("hud", "level", value);
        }
    }

    pub fn hide(&self) {
        let generation = self.set(Mode::Idle);
        // After the page's fade: a dictation that began meanwhile has already brought it back.
        self.later(Duration::from_millis(200), generation, |hud| {
            hud.on_window(|hwnd, _| unsafe {
                let _ = ShowWindow(hwnd, SW_HIDE);
            })
        });
    }

    fn set(&self, mode: Mode) -> u64 {
        let mut state = self.state.lock().unwrap();
        state.1 += 1;
        state.0 = mode.clone();
        let _ = self.app.emit_to("hud", "hud", mode);
        state.1
    }

    fn present(&self, mode: Mode) -> u64 {
        let generation = self.set(mode);
        self.on_window(|hwnd, window| unsafe {
            place(window);
            let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            let _ = SetWindowPos(hwnd, Some(HWND_TOPMOST), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        });
        generation
    }

    /// `action` after `delay`, unless the HUD changed meanwhile.
    fn later(&self, delay: Duration, generation: u64, action: fn(&Hud)) {
        let app = self.app.clone();
        tauri::async_runtime::spawn(async move {
            tokio::time::sleep(delay).await;
            let kay = app.state::<std::sync::Arc<crate::kay::Kay>>();
            if kay.hud.state.lock().unwrap().1 == generation {
                action(&kay.hud);
            }
        });
    }

    /// Window calls belong on the thread that owns the window.
    fn on_window(&self, action: impl FnOnce(windows::Win32::Foundation::HWND, &WebviewWindow) + Send + 'static) {
        let Some(window) = self.app.get_webview_window("hud") else { return };
        let _ = self.app.run_on_main_thread(move || {
            if let Ok(hwnd) = window.hwnd() {
                action(hwnd, &window);
            }
        });
    }
}

/// Centered above the taskbar on the screen the pointer is on. Moves the window, never resizes it.
fn place(window: &WebviewWindow) {
    let Ok(cursor) = window.cursor_position() else { return };
    let Ok(Some(monitor)) = window.monitor_from_point(cursor.x, cursor.y) else { return };
    let Ok(size) = window.outer_size() else { return };
    let area = monitor.work_area();
    let x = area.position.x + (area.size.width as i32 - size.width as i32) / 2;
    let y = area.position.y + area.size.height as i32
        - size.height as i32
        - (ABOVE_TASKBAR * monitor.scale_factor()).round() as i32;
    let _ = window.set_position(PhysicalPosition::new(x, y));
}
