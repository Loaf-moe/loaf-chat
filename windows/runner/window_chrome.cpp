#include "window_chrome.h"

#include <commctrl.h>
#include <dwmapi.h>
#include <flutter/standard_method_codec.h>
#include <windowsx.h>

#include <string>
#include <variant>

namespace {

constexpr UINT_PTR kChildSubclassId = 1;

double ArgDouble(const flutter::EncodableMap& map, const char* key) {
  auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end()) return 0;
  if (auto* d = std::get_if<double>(&it->second)) return *d;
  if (auto* i = std::get_if<int32_t>(&it->second)) return *i;
  return 0;
}

}  // namespace

WindowChrome::WindowChrome(HWND window, flutter::BinaryMessenger* messenger)
    : window_(window), focused_(GetActiveWindow() == window) {
  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "loaf/window", &flutter::StandardMethodCodec::GetInstance());
  channel_->SetMethodCallHandler([this](const auto& call, auto result) {
    const std::string& method = call.method_name();
    if (method == "state") {
      result->Success(State());
      return;
    }
    if (method == "minimize") {
      ShowWindow(window_, SW_MINIMIZE);
    } else if (method == "toggleMaximize" || method == "titlebarDoubleClick") {
      ShowWindow(window_, IsZoomed(window_) ? SW_RESTORE : SW_MAXIMIZE);
    } else if (method == "close") {
      PostMessage(window_, WM_CLOSE, 0, 0);
    } else if (method == "startDrag") {
      // The system's own move loop, so Aero Snap and snap layouts work.
      // Posted, not sent, so this reply isn't held up for the whole move.
      // The cursor position rides along because the loop starts from it.
      POINT cursor{};
      GetCursorPos(&cursor);
      ReleaseCapture();
      PostMessage(window_, WM_NCLBUTTONDOWN, HTCAPTION,
                  MAKELPARAM(cursor.x, cursor.y));
    } else if (method == "setMaxButtonRect") {
      const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
      if (args != nullptr) {
        const double scale = GetDpiForWindow(window_) / 96.0;
        max_button_ = RECT{
            static_cast<LONG>(ArgDouble(*args, "x") * scale),
            static_cast<LONG>(ArgDouble(*args, "y") * scale),
            static_cast<LONG>((ArgDouble(*args, "x") + ArgDouble(*args, "w")) *
                              scale),
            static_cast<LONG>((ArgDouble(*args, "y") + ArgDouble(*args, "h")) *
                              scale)};
      }
    } else {
      result->NotImplemented();
      return;
    }
    result->Success();
  });

  // A one-pixel top margin keeps DWM's shadow on a window with no caption.
  const MARGINS margins{0, 0, 1, 0};
  DwmExtendFrameIntoClientArea(window_, &margins);
  // Recalculates the frame now that WM_NCCALCSIZE is ours.
  SetWindowPos(window_, nullptr, 0, 0, 0, 0,
               SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER |
                   SWP_NOACTIVATE);
}

WindowChrome::~WindowChrome() {
  if (child_ != nullptr) {
    RemoveWindowSubclass(child_, ChildProc, kChildSubclassId);
  }
  channel_->SetMethodCallHandler(nullptr);
}

void WindowChrome::AttachChild(HWND child) {
  child_ = child;
  SetWindowSubclass(child, ChildProc, kChildSubclassId,
                    reinterpret_cast<DWORD_PTR>(this));
}

int WindowChrome::FrameX() const {
  const UINT dpi = GetDpiForWindow(window_);
  return GetSystemMetricsForDpi(SM_CXFRAME, dpi) +
         GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

int WindowChrome::FrameY() const {
  const UINT dpi = GetDpiForWindow(window_);
  return GetSystemMetricsForDpi(SM_CYFRAME, dpi) +
         GetSystemMetricsForDpi(SM_CXPADDEDBORDER, dpi);
}

LRESULT WindowChrome::HitTest(POINT screen) const {
  POINT p = screen;
  ScreenToClient(window_, &p);
  RECT client;
  GetClientRect(window_, &client);
  // The caption is gone, so the top resize edge lies inside the client
  // area and has to be claimed here.
  if (!IsZoomed(window_) && p.y >= 0 && p.y < FrameY()) {
    if (p.x < FrameX()) return HTTOPLEFT;
    if (p.x >= client.right - FrameX()) return HTTOPRIGHT;
    return HTTOP;
  }
  if (PtInRect(&max_button_, p)) return HTMAXBUTTON;
  return HTCLIENT;
}

LRESULT CALLBACK WindowChrome::ChildProc(HWND hwnd, UINT message,
                                         WPARAM wparam, LPARAM lparam,
                                         UINT_PTR, DWORD_PTR data) {
  if (message == WM_NCHITTEST) {
    auto* self = reinterpret_cast<WindowChrome*>(data);
    const POINT screen{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
    if (self->HitTest(screen) != HTCLIENT) return HTTRANSPARENT;
  }
  return DefSubclassProc(hwnd, message, wparam, lparam);
}

std::optional<LRESULT> WindowChrome::HandleMessage(HWND hwnd, UINT message,
                                                   WPARAM wparam,
                                                   LPARAM lparam) {
  switch (message) {
    case WM_NCCALCSIZE: {
      if (!wparam) return std::nullopt;
      auto* params = reinterpret_cast<NCCALCSIZE_PARAMS*>(lparam);
      RECT& r = params->rgrc[0];
      // Sides and bottom keep the resize frame; the caption at the top goes.
      r.left += FrameX();
      r.right -= FrameX();
      r.bottom -= FrameY();
      // A maximized window hangs its frame off the screen; keep the top of
      // the client area on it.
      if (IsZoomed(hwnd)) r.top += FrameY();
      return 0;
    }
    case WM_NCHITTEST: {
      const POINT screen{GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
      const LRESULT hit = HitTest(screen);
      if (hit != HTCLIENT) return hit;
      return std::nullopt;  // sides and bottom: the default frame
    }
    // Over the maximize button the frame gets the mouse, which is what
    // makes Windows 11 offer snap layouts. Its clicks and hover are
    // forwarded so the button still behaves and looks like Loaf's.
    case WM_NCMOUSEMOVE: {
      SetMaxHovered(wparam == HTMAXBUTTON);
      if (wparam == HTMAXBUTTON) {
        TRACKMOUSEEVENT track{sizeof(track), TME_LEAVE | TME_NONCLIENT, hwnd,
                              0};
        TrackMouseEvent(&track);
      }
      return std::nullopt;
    }
    case WM_NCMOUSELEAVE:
      SetMaxHovered(false);
      max_pressed_ = false;
      return std::nullopt;
    case WM_NCLBUTTONDOWN:
      if (wparam == HTMAXBUTTON) {
        max_pressed_ = true;
        return 0;  // no classic button press
      }
      return std::nullopt;
    case WM_NCLBUTTONUP:
      if (wparam == HTMAXBUTTON) {
        if (max_pressed_) {
          ShowWindow(hwnd, IsZoomed(hwnd) ? SW_RESTORE : SW_MAXIMIZE);
        }
        max_pressed_ = false;
        return 0;
      }
      return std::nullopt;
    case WM_ACTIVATE:
      focused_ = LOWORD(wparam) != WA_INACTIVE;
      SendState();
      return std::nullopt;
    case WM_SIZE:
      SendState();
      return std::nullopt;
  }
  return std::nullopt;
}

flutter::EncodableValue WindowChrome::State() const {
  return flutter::EncodableValue(flutter::EncodableMap{
      {flutter::EncodableValue("maximized"),
       flutter::EncodableValue(IsZoomed(window_) != 0)},
      {flutter::EncodableValue("focused"), flutter::EncodableValue(focused_)},
      {flutter::EncodableValue("maxHovered"),
       flutter::EncodableValue(max_hovered_)},
  });
}

void WindowChrome::SendState() {
  channel_->InvokeMethod("stateChanged",
                         std::make_unique<flutter::EncodableValue>(State()));
}

void WindowChrome::SetMaxHovered(bool hovered) {
  if (hovered == max_hovered_) return;
  max_hovered_ = hovered;
  SendState();
}
