#include "window_chrome.h"

#include <cstring>

#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

namespace {

struct WindowChrome {
  GtkWindow* window;
  FlMethodChannel* channel;
  GdkWindowState state;
};

// Raw facts for Dart's tiling-WM rules; native decides nothing.
constexpr const char* kTilingEnv[] = {
    "XDG_CURRENT_DESKTOP", "SWAYSOCK", "HYPRLAND_INSTANCE_SIGNATURE",
    "NIRI_SOCKET", "I3SOCK",
};

constexpr int kAllTiled =
    GDK_WINDOW_STATE_TOP_TILED | GDK_WINDOW_STATE_RIGHT_TILED |
    GDK_WINDOW_STATE_BOTTOM_TILED | GDK_WINDOW_STATE_LEFT_TILED;

FlValue* state_value(WindowChrome* self) {
  FlValue* map = fl_value_new_map();
  fl_value_set_string_take(
      map, "maximized",
      fl_value_new_bool(self->state & GDK_WINDOW_STATE_MAXIMIZED));
  fl_value_set_string_take(
      map, "fullscreen",
      fl_value_new_bool(self->state & GDK_WINDOW_STATE_FULLSCREEN));
  fl_value_set_string_take(map, "focused",
                           fl_value_new_bool(gtk_window_is_active(self->window)));
  fl_value_set_string_take(
      map, "tiled", fl_value_new_bool((self->state & kAllTiled) == kAllTiled));

  FlValue* wm_name = fl_value_new_null();
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(self->window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* name = gdk_x11_screen_get_window_manager_name(screen);
    if (name != nullptr) {
      fl_value_unref(wm_name);
      wm_name = fl_value_new_string(name);
    }
  }
#endif
  fl_value_set_string_take(map, "wmName", wm_name);

  FlValue* env = fl_value_new_map();
  for (const char* name : kTilingEnv) {
    const gchar* value = g_getenv(name);
    if (value != nullptr) {
      fl_value_set_string_take(env, name, fl_value_new_string(value));
    }
  }
  fl_value_set_string_take(map, "env", env);

  g_autofree gchar* layout = nullptr;
  g_object_get(gtk_settings_get_default(), "gtk-decoration-layout", &layout,
               nullptr);
  if (layout != nullptr) {
    fl_value_set_string_take(map, "decorationLayout",
                             fl_value_new_string(layout));
  }
  return map;
}

void send_state(WindowChrome* self) {
  g_autoptr(FlValue) state = state_value(self);
  fl_method_channel_invoke_method(self->channel, "stateChanged", state,
                                  nullptr, nullptr, nullptr);
}

void toggle_maximize(WindowChrome* self) {
  if (self->state & GDK_WINDOW_STATE_MAXIMIZED) {
    gtk_window_unmaximize(self->window);
  } else {
    gtk_window_maximize(self->window);
  }
}

// Flutter starts a drag from a press it is still holding, so the window
// manager sees a live button and takes over the move, snapping included.
// On Wayland GDK uses the seat's grab serial and ignores the coordinates.
void start_drag(WindowChrome* self) {
  GdkWindow* gdk_window = gtk_widget_get_window(GTK_WIDGET(self->window));
  if (gdk_window == nullptr) return;
  GdkSeat* seat = gdk_display_get_default_seat(gdk_window_get_display(gdk_window));
  GdkDevice* pointer = gdk_seat_get_pointer(seat);
  gint x = 0, y = 0;
  gdk_device_get_position(pointer, nullptr, &x, &y);
  gtk_window_begin_move_drag(self->window, GDK_BUTTON_PRIMARY, x, y,
                             gtk_get_current_event_time());
}

void method_call_cb(FlMethodChannel* channel, FlMethodCall* call,
                    gpointer user_data) {
  auto* self = static_cast<WindowChrome*>(user_data);
  const gchar* method = fl_method_call_get_name(call);
  g_autoptr(FlMethodResponse) response = nullptr;
  if (strcmp(method, "state") == 0) {
    g_autoptr(FlValue) state = state_value(self);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(state));
  } else {
    if (strcmp(method, "minimize") == 0) {
      gtk_window_iconify(self->window);
    } else if (strcmp(method, "toggleMaximize") == 0 ||
               strcmp(method, "titlebarDoubleClick") == 0) {
      toggle_maximize(self);
    } else if (strcmp(method, "close") == 0) {
      gtk_window_close(self->window);
    } else if (strcmp(method, "startDrag") == 0) {
      start_drag(self);
    } else if (strcmp(method, "setMaxButtonRect") != 0) {
      fl_method_call_respond_not_implemented(call, nullptr);
      return;
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  }
  fl_method_call_respond(call, response, nullptr);
}

gboolean window_state_cb(GtkWidget*, GdkEventWindowState* event,
                         gpointer user_data) {
  auto* self = static_cast<WindowChrome*>(user_data);
  self->state = event->new_window_state;
  send_state(self);
  return FALSE;
}

void notify_cb(GObject*, GParamSpec*, gpointer user_data) {
  send_state(static_cast<WindowChrome*>(user_data));
}

void destroy_cb(GtkWidget*, gpointer user_data) {
  auto* self = static_cast<WindowChrome*>(user_data);
  g_signal_handlers_disconnect_by_data(gtk_settings_get_default(), self);
  fl_method_channel_set_method_call_handler(self->channel, nullptr, nullptr,
                                            nullptr);
  g_object_unref(self->channel);
  delete self;
}

}  // namespace

void window_chrome_attach(GtkWindow* window, FlView* view) {
  // A titlebar widget that is never shown keeps GTK's client-side
  // decorations (shadow, resize edges) and draws no bar. A shown one would
  // take the theme's title bar height.
  gtk_window_set_titlebar(window, gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0));

  auto* self = new WindowChrome{window, nullptr, GdkWindowState(0)};
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)), "loaf/window",
      FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(self->channel, method_call_cb,
                                            self, nullptr);
  g_signal_connect(window, "window-state-event", G_CALLBACK(window_state_cb),
                   self);
  g_signal_connect(window, "notify::is-active", G_CALLBACK(notify_cb), self);
  g_signal_connect(gtk_settings_get_default(), "notify::gtk-decoration-layout",
                   G_CALLBACK(notify_cb), self);
  g_signal_connect(window, "destroy", G_CALLBACK(destroy_cb), self);
}
