//! Takes over the runner's top-level window: subclasses it so the client
//! area covers the whole window (no frame, so no border), claims the resize
//! bands and the maximize button in its hit-test, and reports state changes
//! to Dart.
//!
//! Everything here runs on the thread that owns the window. Dart's calls do
//! too: Flutter on Windows runs the UI isolate on the platform thread by
//! default, and `install` finds the window by looking only among the
//! calling thread's own windows, so off that thread it finds none and
//! fails rather than subclassing across threads (which Windows refuses).
//! State is therefore thread-local, with `Cell`s rather than locks, and no
//! borrow is held across a Win32 call that can send a message back in.

use std::cell::{Cell, RefCell};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::rc::Rc;

use windows::Win32::Foundation::{HWND, LPARAM, LRESULT, POINT, RECT, WPARAM};
use windows::Win32::Graphics::Dwm::{
    DWMWA_BORDER_COLOR, DWMWA_COLOR_DEFAULT, DWMWA_COLOR_NONE, DwmExtendFrameIntoClientArea,
    DwmSetWindowAttribute,
};
use windows::Win32::Graphics::Gdi::ScreenToClient;
use windows::Win32::System::Threading::GetCurrentThreadId;
use windows::Win32::UI::Controls::MARGINS;
use windows::Win32::UI::HiDpi::{GetDpiForWindow, GetSystemMetricsForDpi};
use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetActiveWindow, ReleaseCapture, TME_LEAVE, TME_NONCLIENT, TRACKMOUSEEVENT, TrackMouseEvent,
};
use windows::Win32::UI::Shell::{DefSubclassProc, RemoveWindowSubclass, SetWindowSubclass};
use windows::Win32::UI::WindowsAndMessaging::{
    EnumThreadWindows, FindWindowExW, GetClassNameW, GetClientRect, GetCursorPos, HTBOTTOM,
    HTBOTTOMLEFT, HTBOTTOMRIGHT, HTCAPTION, HTCLIENT, HTLEFT, HTMAXBUTTON, HTRIGHT, HTTOP,
    HTTOPLEFT, HTTOPRIGHT, HTTRANSPARENT, IsZoomed, NCCALCSIZE_PARAMS, PostMessageW, SM_CXFRAME,
    SM_CXPADDEDBORDER, SM_CYFRAME, SW_MAXIMIZE, SW_MINIMIZE, SW_RESTORE, SWP_FRAMECHANGED,
    SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER, SetWindowPos, ShowWindow, WA_INACTIVE,
    WM_ACTIVATE, WM_CLOSE, WM_NCCALCSIZE, WM_NCDESTROY, WM_NCHITTEST, WM_NCLBUTTONDOWN,
    WM_NCLBUTTONUP, WM_NCMOUSELEAVE, WM_NCMOUSEMOVE, WM_SIZE,
};
use windows::core::{BOOL, PCWSTR, w};

use crate::frame::{self, Band, Hit, LogicalRect};

/// The runner's window class (`kWindowClassName` in
/// `windows/runner/win32_window.cpp`) and the Flutter view's, inside it.
const RUNNER_CLASS: &str = "FLUTTER_RUNNER_WIN32_WINDOW";
const VIEW_CLASS: PCWSTR = w!("FLUTTERVIEW");

/// Our subclass's id on each window. Any constant works: it only has to
/// tell our subclass apart from anyone else's on the same window.
const SUBCLASS_ID: usize = 0x6c6f_6166; // "loaf"

/// Called with [frame::state_bits] when the window's state changes. Dart's
/// `NativeCallable.listener` posts it to the isolate.
pub type StateFn = unsafe extern "C" fn(state: u32);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InstallError {
    /// No runner window on the calling thread: not the runner, or Dart is
    /// not on the platform thread.
    NotFound,
    /// Windows refused the subclass.
    Failed,
}

struct Chrome {
    window: HWND,
    view: HWND,
    report: StateFn,
    max_button: Cell<LogicalRect>,
    max_hovered: Cell<bool>,
    max_pressed: Cell<bool>,
    // From WM_ACTIVATE, because GetForegroundWindow() can lag the message.
    focused: Cell<bool>,
    // What Dart last heard, so a drag-resize's stream of WM_SIZE sends
    // nothing new.
    reported: Cell<Option<u32>>,
}

thread_local! {
    static CHROME: RefCell<Option<Rc<Chrome>>> = const { RefCell::new(None) };
}

/// The installed chrome, if any. The borrow ends before this returns.
fn current() -> Option<Rc<Chrome>> {
    CHROME.with(|c| c.try_borrow().ok().and_then(|c| c.clone()))
}

fn replace(next: Option<Rc<Chrome>>) -> Option<Rc<Chrome>> {
    CHROME.with(|c| match c.try_borrow_mut() {
        Ok(mut slot) => std::mem::replace(&mut *slot, next),
        Err(_) => None,
    })
}

impl Chrome {
    fn dpi(&self) -> u32 {
        // SAFETY: a window handle we hold; 0 back means "invalid", handled.
        match unsafe { GetDpiForWindow(self.window) } {
            0 => 96,
            dpi => dpi,
        }
    }

    /// The frame Windows would have drawn, as the resize band.
    fn band(&self) -> Band {
        let dpi = self.dpi();
        // SAFETY: plain metric lookups.
        // SM_CXPADDEDBORDER is the padding for both axes; there is no CY variant.
        unsafe {
            let padding = GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
            Band {
                x: GetSystemMetricsForDpi(SM_CXFRAME, dpi) + padding,
                y: GetSystemMetricsForDpi(SM_CYFRAME, dpi) + padding,
            }
        }
    }

    fn maximized(&self) -> bool {
        // SAFETY: a window handle we hold.
        unsafe { IsZoomed(self.window) }.as_bool()
    }

    fn hit_test(&self, screen: POINT) -> Hit {
        let mut p = screen;
        let mut client = RECT::default();
        // SAFETY: a window handle we hold, and locals to write to.
        let placed = unsafe {
            ScreenToClient(self.window, &mut p).as_bool()
                && GetClientRect(self.window, &mut client).is_ok()
        };
        if !placed {
            return Hit::Client;
        }
        frame::hit_test(
            (p.x, p.y),
            (client.right - client.left, client.bottom - client.top),
            self.band(),
            self.max_button.get(),
            f64::from(self.dpi()) / 96.0,
            self.maximized(),
        )
    }

    fn state(&self) -> u32 {
        frame::state_bits(self.maximized(), self.focused.get(), self.max_hovered.get())
    }

    fn send_state(&self) {
        let state = self.state();
        if self.reported.replace(Some(state)) == Some(state) {
            return;
        }
        // SAFETY: Dart's listener, live until `uninstall`, which clears this
        // Chrome first.
        unsafe { (self.report)(state) };
    }

    fn set_max_hovered(&self, hovered: bool) {
        if self.max_hovered.replace(hovered) != hovered {
            self.send_state();
        }
    }

    fn toggle_maximize(&self) {
        let show = if self.maximized() {
            SW_RESTORE
        } else {
            SW_MAXIMIZE
        };
        // SAFETY: a window handle we hold. The result is the old
        // visibility, not success.
        let _ = unsafe { ShowWindow(self.window, show) };
    }
}

fn ht(hit: Hit) -> u32 {
    match hit {
        Hit::Client => HTCLIENT,
        Hit::MaxButton => HTMAXBUTTON,
        Hit::Top => HTTOP,
        Hit::Bottom => HTBOTTOM,
        Hit::Left => HTLEFT,
        Hit::Right => HTRIGHT,
        Hit::TopLeft => HTTOPLEFT,
        Hit::TopRight => HTTOPRIGHT,
        Hit::BottomLeft => HTBOTTOMLEFT,
        Hit::BottomRight => HTBOTTOMRIGHT,
    }
}

/// GET_X_LPARAM / GET_Y_LPARAM: signed, since a second monitor can sit
/// left of or above the first.
fn point(lparam: LPARAM) -> POINT {
    POINT {
        x: i32::from((lparam.0 & 0xffff) as u16 as i16),
        y: i32::from(((lparam.0 >> 16) & 0xffff) as u16 as i16),
    }
}

/// MAKELPARAM.
fn make_lparam(p: POINT) -> LPARAM {
    LPARAM(((p.x as u16 as u32) | ((p.y as u16 as u32) << 16)) as i32 as isize)
}

unsafe extern "system" fn find_runner(window: HWND, found: LPARAM) -> BOOL {
    let mut name = [0u16; 64];
    // SAFETY: Windows hands us a live window; the buffer is ours.
    let len = unsafe { GetClassNameW(window, &mut name) };
    let len = usize::try_from(len).unwrap_or(0).min(name.len());
    if String::from_utf16_lossy(&name[..len]) == RUNNER_CLASS {
        // SAFETY: `found` is the &mut HWND `runner_window` passed.
        unsafe { *(found.0 as *mut HWND) = window };
        return BOOL::from(false); // found: stop
    }
    BOOL::from(true)
}

/// The runner's window, among the calling thread's own.
fn runner_window() -> Option<HWND> {
    let mut found = HWND::default();
    // SAFETY: `find_runner` writes through the pointer only while this call
    // runs. The result is false whenever it stopped early, so is ignored.
    let _ = unsafe {
        EnumThreadWindows(
            GetCurrentThreadId(),
            Some(find_runner),
            LPARAM(&mut found as *mut HWND as isize),
        )
    };
    (!found.is_invalid()).then_some(found)
}

/// Takes over the runner's window, which then has no frame of its own and
/// asks `report` to pass on each change of state. Replaces any earlier
/// install.
pub fn install(report: StateFn) -> Result<(), InstallError> {
    uninstall();
    let window = runner_window().ok_or(InstallError::NotFound)?;
    // SAFETY: a live window of ours; the class name is a static string.
    let view = unsafe { FindWindowExW(Some(window), None, VIEW_CLASS, PCWSTR::null()) }
        .map_err(|_| InstallError::NotFound)?;
    // SAFETY: a window handle we just found.
    let focused = unsafe { GetActiveWindow() } == window;
    let chrome = Rc::new(Chrome {
        window,
        view,
        report,
        max_button: Cell::new(LogicalRect::default()),
        max_hovered: Cell::new(false),
        max_pressed: Cell::new(false),
        focused: Cell::new(focused),
        reported: Cell::new(None),
    });
    replace(Some(chrome));

    // SAFETY: our own procs on windows of this thread. The ref data is
    // unused: the procs read the thread-local.
    let subclassed = unsafe {
        SetWindowSubclass(window, Some(frame_proc), SUBCLASS_ID, 0).as_bool()
            && SetWindowSubclass(view, Some(view_proc), SUBCLASS_ID, 0).as_bool()
    };
    if !subclassed {
        uninstall();
        return Err(InstallError::Failed);
    }

    // A one-pixel top margin keeps DWM's shadow, and Windows 11's rounded
    // corners, on a window with no frame.
    let margins = MARGINS {
        cyTopHeight: 1,
        ..Default::default()
    };
    // SAFETY: a window handle we hold; the margins are a local.
    if let Err(e) = unsafe { DwmExtendFrameIntoClientArea(window, &margins) } {
        eprintln!("[loaf chrome] no shadow: {e}");
    }
    border_color(window, DWMWA_COLOR_NONE);
    frame_changed(window);
    Ok(())
}

/// Hands the window back its own frame. After this returns nothing calls
/// the `report` it was installed with.
pub fn uninstall() {
    let Some(chrome) = replace(None) else {
        return;
    };
    // SAFETY: our own subclasses, removed from windows of this thread.
    unsafe {
        let _ = RemoveWindowSubclass(chrome.view, Some(view_proc), SUBCLASS_ID);
        let _ = RemoveWindowSubclass(chrome.window, Some(frame_proc), SUBCLASS_ID);
        let _ = DwmExtendFrameIntoClientArea(chrome.window, &MARGINS::default());
    }
    border_color(chrome.window, DWMWA_COLOR_DEFAULT);
    frame_changed(chrome.window);
}

/// Windows 11 draws its own 1px border, in the accent colour, even round a
/// window with no frame; `DWMWA_COLOR_NONE` turns it off. Windows 10 has no
/// such border and refuses the attribute, which is fine to ignore.
fn border_color(window: HWND, color: u32) {
    // SAFETY: a window handle of this thread; the colour is a local whose
    // size is passed with it.
    let _ = unsafe {
        DwmSetWindowAttribute(
            window,
            DWMWA_BORDER_COLOR,
            (&raw const color).cast(),
            size_of::<u32>() as u32,
        )
    };
}

/// Has Windows ask WM_NCCALCSIZE again, so the frame follows whoever
/// answers it now.
fn frame_changed(window: HWND) {
    // SAFETY: a window handle of this thread.
    let result = unsafe {
        SetWindowPos(
            window,
            None,
            0,
            0,
            0,
            0,
            SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE,
        )
    };
    if let Err(e) = result {
        eprintln!("[loaf chrome] frame change: {e}");
    }
}

pub fn state() -> Option<u32> {
    current().map(|c| c.state())
}

pub fn minimize() -> bool {
    current()
        .map(|c| {
            // SAFETY: a window handle we hold.
            let _ = unsafe { ShowWindow(c.window, SW_MINIMIZE) };
        })
        .is_some()
}

pub fn toggle_maximize() -> bool {
    current().map(|c| c.toggle_maximize()).is_some()
}

pub fn close() -> bool {
    current()
        .map(|c| {
            // SAFETY: a window handle we hold.
            if let Err(e) = unsafe { PostMessageW(Some(c.window), WM_CLOSE, WPARAM(0), LPARAM(0)) }
            {
                eprintln!("[loaf chrome] close: {e}");
            }
        })
        .is_some()
}

/// The system's own move loop, so Aero Snap and snap layouts work. Posted,
/// not sent, so Dart's call returns now rather than after the whole move.
/// The cursor position rides along because the loop starts from it.
pub fn start_drag() -> bool {
    current()
        .map(|c| {
            let mut cursor = POINT::default();
            // SAFETY: a local to write to; the window is ours.
            unsafe {
                let at = match GetCursorPos(&mut cursor) {
                    Ok(()) => make_lparam(cursor),
                    Err(_) => LPARAM(0),
                };
                // The Flutter view holds the capture from the press.
                let _ = ReleaseCapture();
                if let Err(e) = PostMessageW(
                    Some(c.window),
                    WM_NCLBUTTONDOWN,
                    WPARAM(HTCAPTION as usize),
                    at,
                ) {
                    eprintln!("[loaf chrome] drag: {e}");
                }
            }
        })
        .is_some()
}

/// Where Loaf's maximize button is, in logical pixels from the window's
/// top-left; all zero when there is none.
pub fn set_max_button(rect: LogicalRect) -> bool {
    current().map(|c| c.max_button.set(rect)).is_some()
}

/// Runs a window proc's body, and on a panic lets the window behave as if
/// we were not there rather than unwind into Windows.
fn guarded(f: impl FnOnce() -> Option<LRESULT>) -> Option<LRESULT> {
    catch_unwind(AssertUnwindSafe(f)).unwrap_or(None)
}

unsafe extern "system" fn frame_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    _id: usize,
    _data: usize,
) -> LRESULT {
    // SAFETY: the parameters come from Windows for this message.
    let handled = guarded(|| unsafe { frame_message(hwnd, message, wparam, lparam) });
    match handled {
        Some(result) => result,
        // SAFETY: forwarding the message as received.
        None => unsafe { DefSubclassProc(hwnd, message, wparam, lparam) },
    }
}

/// # Safety
/// The parameters are those Windows sent with `message`.
unsafe fn frame_message(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> Option<LRESULT> {
    if message == WM_NCDESTROY {
        // The window is going; nothing is left to hand back.
        if current().is_some_and(|c| c.window == hwnd) {
            replace(None);
        }
        // SAFETY: our own subclass, on the window being destroyed.
        let _ = unsafe { RemoveWindowSubclass(hwnd, Some(frame_proc), SUBCLASS_ID) };
        return None;
    }
    let chrome = current()?;
    match message {
        WM_NCCALCSIZE => {
            // SAFETY: with wparam set, lparam is NCCALCSIZE_PARAMS, whose
            // first rect is the window rect in and the client rect out;
            // without, it is that one rect alone.
            let rect = unsafe {
                if wparam.0 != 0 {
                    &mut (*(lparam.0 as *mut NCCALCSIZE_PARAMS)).rgrc[0]
                } else {
                    &mut *(lparam.0 as *mut RECT)
                }
            };
            let (left, top, right, bottom) =
                frame::client_insets(chrome.maximized(), chrome.band());
            rect.left += left;
            rect.top += top;
            rect.right -= right;
            rect.bottom -= bottom;
            Some(LRESULT(0))
        }
        WM_NCHITTEST => match chrome.hit_test(point(lparam)) {
            Hit::Client => None,
            hit => Some(LRESULT(ht(hit) as isize)),
        },
        // Over the maximize button the frame gets the mouse, which is what
        // makes Windows 11 offer snap layouts. Its clicks and hover are
        // forwarded so the button still behaves and looks like Loaf's.
        WM_NCMOUSEMOVE => {
            let over = wparam.0 == HTMAXBUTTON as usize;
            chrome.set_max_hovered(over);
            if over {
                let mut track = TRACKMOUSEEVENT {
                    cbSize: size_of::<TRACKMOUSEEVENT>() as u32,
                    dwFlags: TME_LEAVE | TME_NONCLIENT,
                    hwndTrack: hwnd,
                    dwHoverTime: 0,
                };
                // SAFETY: a local, for this window.
                let _ = unsafe { TrackMouseEvent(&mut track) };
            }
            None
        }
        WM_NCMOUSELEAVE => {
            chrome.set_max_hovered(false);
            chrome.max_pressed.set(false);
            None
        }
        WM_NCLBUTTONDOWN if wparam.0 == HTMAXBUTTON as usize => {
            chrome.max_pressed.set(true);
            Some(LRESULT(0)) // no classic button press
        }
        WM_NCLBUTTONUP if wparam.0 == HTMAXBUTTON as usize => {
            if chrome.max_pressed.replace(false) {
                chrome.toggle_maximize();
            }
            Some(LRESULT(0))
        }
        WM_ACTIVATE => {
            chrome
                .focused
                .set((wparam.0 & 0xffff) as u32 != WA_INACTIVE);
            chrome.send_state();
            None
        }
        WM_SIZE => {
            chrome.send_state();
            None
        }
        _ => None,
    }
}

/// The Flutter view fills the window, so the resize bands and the maximize
/// button lie over it; it passes those spots through to the frame.
unsafe extern "system" fn view_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    _id: usize,
    _data: usize,
) -> LRESULT {
    let handled = guarded(|| match message {
        WM_NCDESTROY => {
            // SAFETY: our own subclass, on the window being destroyed.
            let _ = unsafe { RemoveWindowSubclass(hwnd, Some(view_proc), SUBCLASS_ID) };
            None
        }
        WM_NCHITTEST => {
            let chrome = current()?;
            (chrome.view == hwnd && chrome.hit_test(point(lparam)) != Hit::Client)
                .then_some(LRESULT(HTTRANSPARENT as isize))
        }
        _ => None,
    });
    match handled {
        Some(result) => result,
        // SAFETY: forwarding the message as received.
        None => unsafe { DefSubclassProc(hwnd, message, wparam, lparam) },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lparam_points_are_signed() {
        let p = point(LPARAM(0xfff6_0014));
        assert_eq!((p.x, p.y), (20, -10));
        let back = point(make_lparam(POINT { x: -1920, y: 300 }));
        assert_eq!((back.x, back.y), (-1920, 300));
    }
}
