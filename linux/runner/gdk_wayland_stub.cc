#include <gdk/gdk.h>

// Flutter's prebuilt engine references these two GDK Wayland symbols
// unconditionally; a GTK built for X11 alone has neither. No display is an
// instance of this type, so GDK_IS_WAYLAND_DISPLAY() is false for all.

typedef struct {
  GObject parent;
} GdkWaylandStubDisplay;

typedef struct {
  GObjectClass parent;
} GdkWaylandStubDisplayClass;

G_DEFINE_TYPE(GdkWaylandStubDisplay, gdk_wayland_stub_display, G_TYPE_OBJECT)

static void gdk_wayland_stub_display_init(GdkWaylandStubDisplay*) {}
static void gdk_wayland_stub_display_class_init(GdkWaylandStubDisplayClass*) {}

extern "C" {

struct wl_display;

GType gdk_wayland_display_get_type(void) {
  return gdk_wayland_stub_display_get_type();
}

struct wl_display* gdk_wayland_display_get_wl_display(GdkDisplay*) {
  return nullptr;
}

}  // extern "C"
