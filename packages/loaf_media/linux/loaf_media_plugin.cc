#include "include/loaf_media/loaf_media_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

// The Linux half of package:loaf_media. Opening a file goes through the
// OpenURI portal from Dart, so for now this only claims the channel; video
// arrives on it later.

#define LOAF_MEDIA_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), loaf_media_plugin_get_type(), \
                              LoafMediaPlugin))

struct _LoafMediaPlugin {
  GObject parent_instance;

  // Held for the plugin's life, so the channel's handler is never dropped
  // and native code can call into Dart on it.
  FlMethodChannel* channel;
};

G_DEFINE_TYPE(LoafMediaPlugin, loaf_media_plugin, g_object_get_type())

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  g_autoptr(FlMethodResponse) response =
      FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  fl_method_call_respond(method_call, response, nullptr);
}

static void loaf_media_plugin_dispose(GObject* object) {
  LoafMediaPlugin* self = LOAF_MEDIA_PLUGIN(object);
  g_clear_object(&self->channel);
  G_OBJECT_CLASS(loaf_media_plugin_parent_class)->dispose(object);
}

static void loaf_media_plugin_class_init(LoafMediaPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = loaf_media_plugin_dispose;
}

static void loaf_media_plugin_init(LoafMediaPlugin* self) {
  self->channel = nullptr;
}

void loaf_media_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  LoafMediaPlugin* plugin = LOAF_MEDIA_PLUGIN(
      g_object_new(loaf_media_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "moe.loaf.chat/media", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(plugin->channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_object_unref(plugin);
}
