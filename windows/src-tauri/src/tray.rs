//! The notification-area icon, the menu bar item's counterpart: a click opens Kay's window, the menu has the rest.

use std::sync::Arc;

use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Emitter, Manager,
};

use crate::{i18n::t, kay::Kay};

const ID: &str = "kay";

pub fn create(app: &AppHandle, visible: bool) -> tauri::Result<()> {
    let item = |id: &str, text: &str| MenuItem::with_id(app, id, t(text), true, None::<&str>);
    let menu = Menu::with_items(
        app,
        &[
            &item("open", "Open Kay")?,
            &item("settings", "Settings…")?,
            &item("updates", "Check for Updates…")?,
            &PredefinedMenuItem::separator(app)?,
            &item("quit", "Quit Kay")?,
        ],
    )?;
    let mut builder = TrayIconBuilder::with_id(ID).tooltip("Kay").menu(&menu).show_menu_on_left_click(false);
    if let Some(icon) = app.default_window_icon() {
        builder = builder.icon(icon.clone());
    }
    let tray = builder
        .on_menu_event(|app, event| match event.id().as_ref() {
            "open" => show_window(app, None),
            "settings" => show_window(app, Some("settings")),
            "updates" => show_window(app, Some("updates")),
            "quit" => app.state::<Arc<Kay>>().quit(),
            _ => {}
        })
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { button: MouseButton::Left, button_state: MouseButtonState::Up, .. } = event {
                show_window(tray.app_handle(), None);
            }
        })
        .build(app)?;
    tray.set_visible(visible)
}

pub fn show(app: &AppHandle, visible: bool) {
    if let Some(tray) = app.tray_by_id(ID) {
        let _ = tray.set_visible(visible);
    }
}

/// Brings Kay's window up, on `pane` when given: "settings" for the settings pane seen last, "updates" for General
/// with an update check under way.
pub fn show_window(app: &AppHandle, pane: Option<&str>) {
    let Some(window) = app.get_webview_window("main") else { return };
    let _ = window.unminimize();
    let _ = window.show();
    let _ = window.set_focus();
    if let Some(pane) = pane {
        let _ = app.emit_to("main", "pane", pane);
    }
}
