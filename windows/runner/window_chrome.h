#ifndef RUNNER_WINDOW_CHROME_H_
#define RUNNER_WINDOW_CHROME_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <optional>

// Removes the caption, keeps the resize frame and Aero Snap, and answers
// Loaf's own window buttons over `loaf/window`.
class WindowChrome {
 public:
  WindowChrome(HWND window, flutter::BinaryMessenger* messenger);
  ~WindowChrome();

  // Lets the Flutter view pass the top resize edge and the maximize button
  // through to the frame, which owns them.
  void AttachChild(HWND child);

  // Frame messages for the top-level window; a value when handled.
  std::optional<LRESULT> HandleMessage(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam);

 private:
  static LRESULT CALLBACK ChildProc(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam, UINT_PTR id,
                                    DWORD_PTR data);

  // Where |screen| falls: HTTOP*, HTMAXBUTTON, or HTCLIENT.
  LRESULT HitTest(POINT screen) const;
  int FrameX() const;
  int FrameY() const;
  flutter::EncodableValue State() const;
  void SendState();
  void SetMaxHovered(bool hovered);

  HWND window_;
  HWND child_ = nullptr;
  RECT max_button_{};  // physical pixels, client coordinates
  bool max_hovered_ = false;
  bool max_pressed_ = false;
  // From WM_ACTIVATE, because GetForegroundWindow() can lag the message.
  bool focused_ = false;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_WINDOW_CHROME_H_
