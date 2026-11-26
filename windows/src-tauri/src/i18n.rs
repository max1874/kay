//! English, or Simplified Chinese when Windows' display language is Chinese. One table for the window and for
//! what Rust says (the HUD, errors): `src/strings.zh.json`, English to Chinese, English being the key.

use std::{collections::HashMap, sync::OnceLock};

static ZH: OnceLock<Option<HashMap<String, String>>> = OnceLock::new();

fn table() -> &'static Option<HashMap<String, String>> {
    ZH.get_or_init(|| {
        // LANG_CHINESE is the primary language of zh-CN, zh-TW and zh-HK alike; the table is Simplified Chinese.
        let language = unsafe { windows::Win32::Globalization::GetUserDefaultUILanguage() };
        (language & 0x3ff == 0x04)
            .then(|| serde_json::from_str(include_str!("../../src/strings.zh.json")).expect("strings.zh.json is valid"))
    })
}

pub fn is_chinese() -> bool {
    table().is_some()
}

pub fn t(english: &str) -> String {
    table().as_ref().and_then(|zh| zh.get(english)).cloned().unwrap_or_else(|| english.to_string())
}

/// `english` with its `{}` replaced by `value`, after translation.
pub fn tf(english: &str, value: impl std::fmt::Display) -> String {
    t(english).replacen("{}", &value.to_string(), 1)
}
