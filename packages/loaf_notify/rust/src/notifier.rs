//! Toasts under the app's AUMID, each kept until withdrawn so its
//! Activated handler stays alive. Clicks arrive on a WinRT thread; the
//! callback must hand them to the platform thread itself.

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use windows::Data::Xml::Dom::XmlDocument;
use windows::Foundation::TypedEventHandler;
use windows::UI::Notifications::{
    NotificationSetting, ToastActivatedEventArgs, ToastNotification, ToastNotificationManager,
};
use windows::Win32::System::Registry::{HKEY_CURRENT_USER, REG_SZ, RegSetKeyValueW};
use windows::core::{HSTRING, IInspectable, Interface, PCWSTR, Result};

use crate::toast::{Toast, key, parse_launch, xml};

pub const AUMID: &str = "moe.loaf.chat";

pub type Clicked = Arc<dyn Fn(&str, &str) + Send + Sync>;

pub struct Notifier {
    clicked: Clicked,
    /// Each toast with its `Activated` token.
    shown: Mutex<HashMap<String, Vec<(ToastNotification, i64)>>>,
}

impl Notifier {
    pub fn new(clicked: Clicked) -> Self {
        Self {
            clicked,
            shown: Mutex::new(HashMap::new()),
        }
    }

    pub fn show(&self, toast: &Toast) -> Result<()> {
        let doc = XmlDocument::new()?;
        doc.LoadXml(&HSTRING::from(xml(toast)))?;
        let notification = ToastNotification::CreateToastNotification(&doc)?;
        let group = key(toast.room_id);
        notification.SetGroup(&HSTRING::from(group.as_str()))?;
        notification.SetTag(&HSTRING::from(key(toast.event_id)))?;
        let clicked = self.clicked.clone();
        let token = notification.Activated(&TypedEventHandler::<ToastNotification, IInspectable>::new(
            move |_, args| {
                if let Some(args) = args.as_ref()
                    && let Ok(args) = args.cast::<ToastActivatedEventArgs>()
                {
                    let launch = args.Arguments()?.to_string();
                    if let Some((room, event)) = parse_launch(&launch) {
                        clicked(room, event);
                    }
                }
                Ok(())
            },
        ))?;
        ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(AUMID))?
            .Show(&notification)?;
        if let Ok(mut shown) = self.shown.lock() {
            shown.entry(group).or_default().push((notification, token));
        }
        Ok(())
    }

    pub fn withdraw(&self, room_id: &str) -> Result<()> {
        let group = key(room_id);
        ToastNotificationManager::History()?
            .RemoveGroupWithId(&HSTRING::from(group.as_str()), &HSTRING::from(AUMID))?;
        if let Ok(mut shown) = self.shown.lock()
            && let Some(toasts) = shown.remove(&group)
        {
            detach(toasts);
        }
        Ok(())
    }
}

/// Takes the click handlers off toasts we stop tracking, so they stop
/// holding the callback.
fn detach(toasts: Vec<(ToastNotification, i64)>) {
    for (toast, token) in toasts {
        let _ = toast.RemoveActivated(token);
    }
}

impl Drop for Notifier {
    fn drop(&mut self) {
        if let Ok(mut shown) = self.shown.lock() {
            for (_, toasts) in shown.drain() {
                detach(toasts);
            }
        }
    }
}

pub fn blocked() -> Result<bool> {
    let setting =
        ToastNotificationManager::CreateToastNotifierWithId(&HSTRING::from(AUMID))?.Setting()?;
    Ok(setting != NotificationSetting::Enabled)
}

/// The name and icon Windows shows beside the app's toasts. An unpackaged
/// app may register these for itself under HKCU.
pub fn register(icon: &std::path::Path) -> Result<()> {
    let key = HSTRING::from(format!(r"Software\Classes\AppUserModelId\{AUMID}"));
    set(&key, "DisplayName", "Loaf Chat")?;
    set(&key, "IconUri", &icon.to_string_lossy())
}

fn set(key: &HSTRING, name: &str, value: &str) -> Result<()> {
    let wide: Vec<u16> = value.encode_utf16().chain(std::iter::once(0)).collect();
    let name = HSTRING::from(name);
    // SAFETY: every pointer is to a live, NUL-terminated wide string;
    // the length is the data's in bytes, NUL included.
    unsafe {
        RegSetKeyValueW(
            HKEY_CURRENT_USER,
            PCWSTR(key.as_ptr()),
            PCWSTR(name.as_ptr()),
            REG_SZ.0,
            Some(wide.as_ptr().cast()),
            u32::try_from(wide.len() * 2).unwrap_or(u32::MAX),
        )
        .ok()
    }
}

/// Where Flutter bundles the app icon asset for the running exe.
pub fn icon_path() -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok()?;
    Some(
        exe.parent()?
            .join("data")
            .join("flutter_assets")
            .join("linux")
            .join("packaging")
            .join("moe.loaf.chat.png"),
    )
}
