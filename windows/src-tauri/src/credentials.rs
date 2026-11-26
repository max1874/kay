//! Each service's API key, as a generic credential in Windows Credential Manager (the Keychain's counterpart), named
//! `com.max1874.kay/<account>` with the account names the Mac uses.

use windows::{
    core::{HSTRING, PWSTR},
    Win32::Security::Credentials::{
        CredDeleteW, CredFree, CredReadW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE, CRED_TYPE_GENERIC,
    },
};

#[derive(Clone, Copy)]
pub enum Account {
    Dashscope,
    Volcengine,
    /// Not a speech service: correction after recognition.
    Deepseek,
}

impl Account {
    fn target(self) -> String {
        let name = match self {
            Account::Dashscope => "dashscope-api-key",
            Account::Volcengine => "volc-api-key",
            Account::Deepseek => "deepseek-api-key",
        };
        format!("com.max1874.kay/{name}")
    }
}

pub fn get(account: Account) -> Option<String> {
    let target = HSTRING::from(account.target());
    let mut credential: *mut CREDENTIALW = std::ptr::null_mut();
    unsafe {
        CredReadW(&target, CRED_TYPE_GENERIC, None, &mut credential).ok()?;
        let c = &*credential;
        let blob = std::slice::from_raw_parts(c.CredentialBlob, c.CredentialBlobSize as usize);
        let value = String::from_utf8(blob.to_vec()).ok();
        CredFree(credential as *const _);
        value.filter(|v| !v.is_empty())
    }
}

/// Empty deletes. Returns whether Credential Manager took the change.
pub fn set(account: Account, value: &str) -> bool {
    let target = HSTRING::from(account.target());
    unsafe {
        if value.is_empty() {
            // Deleting what isn't there is fine too.
            return CredDeleteW(&target, CRED_TYPE_GENERIC, None).is_ok() || get(account).is_none();
        }
        let mut name: Vec<u16> = account.target().encode_utf16().chain([0]).collect();
        let mut user: Vec<u16> = "Kay".encode_utf16().chain([0]).collect();
        let mut blob = value.as_bytes().to_vec();
        let credential = CREDENTIALW {
            Type: CRED_TYPE_GENERIC,
            TargetName: PWSTR(name.as_mut_ptr()),
            UserName: PWSTR(user.as_mut_ptr()),
            CredentialBlobSize: blob.len() as u32,
            CredentialBlob: blob.as_mut_ptr(),
            Persist: CRED_PERSIST_LOCAL_MACHINE,
            ..Default::default()
        };
        CredWriteW(&credential, 0).is_ok() && get(account).as_deref() == Some(value)
    }
}

pub fn mask(key: &str) -> String {
    let tail: String = key.chars().rev().take(4).collect::<Vec<_>>().into_iter().rev().collect();
    format!("••••{tail}")
}
