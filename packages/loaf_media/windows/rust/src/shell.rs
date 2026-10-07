//! The shell's own idea of how a file opens: the app it opens in, by name,
//! and opening it there.

use windows::Win32::UI::Shell::{
    ASSOCF_INIT_IGNOREUNKNOWN, ASSOCF_NOTRUNCATE, ASSOCSTR_FRIENDLYAPPNAME, AssocQueryStringW,
    SEE_MASK_NOASYNC, SHELLEXECUTEINFOW, ShellExecuteExW,
};
use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;
use windows_core::{HSTRING, PCWSTR, PWSTR};

/// The app files ending `.<extension>` open in ("Photos"), or None when
/// none is set.
pub fn default_app_name(extension: &str) -> Option<String> {
    let assoc = HSTRING::from(format!(".{extension}"));
    let mut buf = [0u16; 260];
    let mut len = buf.len() as u32;
    // SAFETY: [buf] holds [len] UTF-16 units.
    let hr = unsafe {
        AssocQueryStringW(
            ASSOCF_INIT_IGNOREUNKNOWN | ASSOCF_NOTRUNCATE,
            ASSOCSTR_FRIENDLYAPPNAME,
            &assoc,
            PCWSTR::null(),
            Some(PWSTR(buf.as_mut_ptr())),
            &mut len,
        )
    };
    if hr.is_err() {
        return None;
    }
    let end = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    let name = String::from_utf16_lossy(&buf[..end]);
    (!name.is_empty()).then_some(name)
}

/// Opens [path] the way double-clicking it in Explorer would. With no app
/// set, Windows asks which to use: its own way forward, not an error.
pub fn open(path: &str) -> windows_core::Result<()> {
    let file = HSTRING::from(path.replace('/', "\\"));
    let verb = HSTRING::from("open");
    let mut info = SHELLEXECUTEINFOW {
        cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
        // The plugin's thread may end before the shell is done otherwise.
        fMask: SEE_MASK_NOASYNC,
        lpVerb: PCWSTR(verb.as_ptr()),
        lpFile: PCWSTR(file.as_ptr()),
        nShow: SW_SHOWNORMAL.0,
        ..Default::default()
    };
    // SAFETY: [info] and the strings it points at outlive the call.
    unsafe { ShellExecuteExW(&mut info) }
}
