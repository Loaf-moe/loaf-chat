#include "include/loaf_media/loaf_media_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include "include/loaf_media/loaf_media_rs.h"
#include "video_texture.h"

// The Linux half of package:loaf_media. Opening a file goes through the
// OpenURI portal from Dart; this plays video in place. Dart reports each
// download's progress (`stream.*`) to the Rust source reading it, and drives
// the players drawn into Flutter textures (`video.*`). The other ends are
// `lib/src/streams.dart` and `lib/src/linux_video.dart`.

#define LOAF_MEDIA_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), loaf_media_plugin_get_type(), \
                              LoafMediaPlugin))

static constexpr char kFailed[] = "video-failed";

struct _LoafMediaPlugin {
  GObject parent_instance;

  // Held for the plugin's life, so the channel's handler is never dropped
  // and native code can call into Dart on it. The handler holds the plugin
  // in turn: that cycle is what keeps both alive as long as the engine.
  FlMethodChannel* channel;

  FlTextureRegistrar* textures;

  // GStreamer starts with the first video rather than with the app: its
  // registry scan would hold up every launch. Without it every video
  // offers Open.
  gboolean video_tried;
  gboolean video;

  // Textures no view uses, for the next video. They are never finalized
  // while the engine runs: see video_texture.h.
  GPtrArray* idle;

  // view id → VideoView.
  GHashTable* views;
  int64_t next_view;
};

G_DEFINE_TYPE(LoafMediaPlugin, loaf_media_plugin, g_object_get_type())

// One inline video, by the view id Dart knows it by.
typedef struct {
  int64_t view;
  LoafMediaPlugin* plugin;  // Not owned: it outlives its views.
  LoafVideoTexture* texture;
  void* player;  // Owned by the texture while attached.
  // What Dart has been told, so each is said once.
  gboolean ready;
  gboolean failed;
} VideoView;

static void video_view_free(gpointer data) {
  VideoView* view = static_cast<VideoView*>(data);
  fl_texture_registrar_unregister_texture(view->plugin->textures,
                                          FL_TEXTURE(view->texture));
  // Stops the video now, and lets go of the view so queued marks don't
  // reach it. The texture itself waits for the next video.
  loaf_video_texture_detach(view->texture);
  g_ptr_array_add(view->plugin->idle, view->texture);
  g_free(view);
}

static void send(LoafMediaPlugin* self, const char* method, int64_t view) {
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "view", fl_value_new_int(view));
  fl_method_channel_invoke_method(self->channel, method, args, nullptr,
                                  nullptr, nullptr);
}

// The player had something new to show. Dart drops the download progress
// over the row once the video can start, and offers Open if it can't. Runs
// for every frame, so it only reads the player's flags.
static void video_changed(LoafVideoTexture* texture, gpointer user) {
  VideoView* view = static_cast<VideoView*>(user);
  if (view->failed) {
    return;
  }
  int32_t ready = 0, error = 0;
  if (loaf_rs_player_status(view->player, &ready, &error) != 0 ||
      error != 0) {
    view->failed = TRUE;
    send(view->plugin, "video.failed", view->view);
    return;
  }
  if (ready != 0 && !view->ready) {
    view->ready = TRUE;
    send(view->plugin, "video.ready", view->view);
  }
}

static FlMethodResponse* error_response(const char* message) {
  return FL_METHOD_RESPONSE(
      fl_method_error_response_new(kFailed, message, nullptr));
}

static FlMethodResponse* ok_response(FlValue* result = nullptr) {
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* status_response(int32_t status, const char* what) {
  if (status == 0) {
    return ok_response();
  }
  g_autofree gchar* message = g_strdup_printf("%s failed (%d)", what, status);
  return error_response(message);
}

static const gchar* string_arg(FlValue* args, const char* key) {
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  return fl_value_get_string(value);
}

// [fallback] when absent or null, as Dart sends an unknown total.
static int64_t int_arg(FlValue* args, const char* key, int64_t fallback) {
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) {
    return fallback;
  }
  return fl_value_get_int(value);
}

static gboolean bool_arg(FlValue* args, const char* key) {
  FlValue* value = fl_value_lookup_string(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL &&
         fl_value_get_bool(value);
}

static FlMethodResponse* stream_call(const gchar* method, FlValue* args) {
  const gchar* id = string_arg(args, "id");
  if (id == nullptr) {
    return error_response("no stream id");
  }
  if (g_str_equal(method, "stream.end")) {
    return status_response(loaf_rs_stream_end(id), "stream.end");
  }
  int64_t received = int_arg(args, "received", 0);
  int64_t total = int_arg(args, "total", -1);
  int32_t complete = bool_arg(args, "complete");
  int32_t failed = bool_arg(args, "failed");
  if (g_str_equal(method, "stream.begin")) {
    const gchar* path = string_arg(args, "path");
    if (path == nullptr) {
      return error_response("no path");
    }
    int32_t status = loaf_rs_stream_begin(id, path, received, total);
    if (status != 0) {
      return status_response(status, "stream.begin");
    }
    // Begin carries the whole progress, which may already be complete or
    // failed (a stream begun again after a retry).
  }
  return status_response(
      loaf_rs_stream_progress(id, received, total, complete, failed),
      "stream.progress");
}

static FlMethodResponse* video_create(LoafMediaPlugin* self, FlValue* args) {
  const gchar* id = string_arg(args, "id");
  if (id == nullptr) {
    return error_response("no file id");
  }
  if (!self->video_tried) {
    self->video_tried = TRUE;
    self->video = loaf_rs_init() == 0;
    if (!self->video) {
      g_warning("[loaf media] GStreamer did not start; video will offer Open");
    }
  }
  if (!self->video) {
    return error_response("GStreamer did not start");
  }
  VideoView* view = g_new0(VideoView, 1);
  view->plugin = self;
  view->view = ++self->next_view;
  view->texture =
      self->idle->len > 0
          ? LOAF_VIDEO_TEXTURE(g_ptr_array_steal_index_fast(
                self->idle, self->idle->len - 1))
          : loaf_video_texture_new(self->textures);
  if (!loaf_video_texture_attach(view->texture, id, video_changed, view)) {
    g_ptr_array_add(self->idle, view->texture);
    g_free(view);
    return error_response("no player for this file");
  }
  view->player = loaf_video_texture_get_player(view->texture);
  if (!fl_texture_registrar_register_texture(self->textures,
                                             FL_TEXTURE(view->texture))) {
    loaf_video_texture_detach(view->texture);
    g_ptr_array_add(self->idle, view->texture);
    g_free(view);
    return error_response("the texture was refused");
  }
  g_hash_table_insert(self->views, &view->view, view);

  g_autoptr(FlValue) result = fl_value_new_map();
  fl_value_set_string_take(
      result, "texture",
      fl_value_new_int(fl_texture_get_id(FL_TEXTURE(view->texture))));
  fl_value_set_string_take(result, "view", fl_value_new_int(view->view));
  return ok_response(result);
}

static FlMethodResponse* video_call(LoafMediaPlugin* self, const gchar* method,
                                    FlValue* args) {
  int64_t id = int_arg(args, "view", -1);
  VideoView* view =
      static_cast<VideoView*>(g_hash_table_lookup(self->views, &id));
  // Pausing or disposing a view that's already gone has nothing to do:
  // Dart may pause a row as it goes.
  if (g_str_equal(method, "video.dispose")) {
    if (view != nullptr) {
      g_hash_table_remove(self->views, &id);
    }
    return ok_response();
  }
  if (view == nullptr) {
    return g_str_equal(method, "video.pause") ? ok_response()
                                              : error_response("no such view");
  }
  void* player = view->player;
  if (g_str_equal(method, "video.play")) {
    return status_response(loaf_rs_player_play(player), method);
  }
  if (g_str_equal(method, "video.pause")) {
    return status_response(loaf_rs_player_pause(player), method);
  }
  if (g_str_equal(method, "video.seek")) {
    return status_response(
        loaf_rs_player_seek(player, int_arg(args, "ms", 0)), method);
  }
  if (g_str_equal(method, "video.mute")) {
    return status_response(
        loaf_rs_player_set_muted(player, bool_arg(args, "muted")), method);
  }
  if (g_str_equal(method, "video.state")) {
    int64_t position = 0, duration = 0;
    int32_t playing = 0, error = 0;
    int32_t status =
        loaf_rs_player_state(player, &position, &duration, &playing, &error);
    if (status != 0) {
      return status_response(status, method);
    }
    g_autoptr(FlValue) result = fl_value_new_map();
    fl_value_set_string_take(result, "position",
                             fl_value_new_int(position < 0 ? 0 : position));
    fl_value_set_string_take(
        result, "duration",
        duration < 0 ? fl_value_new_null() : fl_value_new_int(duration));
    fl_value_set_string_take(result, "playing", fl_value_new_bool(playing));
    fl_value_set_string_take(result, "error", fl_value_new_bool(error));
    return ok_response(result);
  }
  return FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
}

// Whether the clipboard holds a picture or files, without fetching either.
static FlMethodResponse* clipboard_has() {
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  g_autoptr(FlValue) has = fl_value_new_bool(
      gtk_clipboard_wait_is_image_available(clipboard) ||
      gtk_clipboard_wait_is_uris_available(clipboard));
  return ok_response(has);
}

// The clipboard's picture as PNG bytes, or null when it holds none: what a
// screenshot tool or "copy image" leaves there. GTK reads it from whoever
// owns the clipboard, so this waits for them, briefly, on the main loop.
static FlMethodResponse* clipboard_image() {
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  g_autoptr(GdkPixbuf) pixbuf = gtk_clipboard_wait_for_image(clipboard);
  if (pixbuf == nullptr) {
    return ok_response();
  }
  gchar* buffer = nullptr;
  gsize size = 0;
  g_autoptr(GError) error = nullptr;
  if (!gdk_pixbuf_save_to_buffer(pixbuf, &buffer, &size, "png", &error,
                                 nullptr)) {
    return error_response(error != nullptr ? error->message
                                           : "couldn't encode the picture");
  }
  g_autoptr(FlValue) bytes =
      fl_value_new_uint8_list(reinterpret_cast<const uint8_t*>(buffer), size);
  g_free(buffer);
  return ok_response(bytes);
}

// The paths of the files copied in a file manager: the regular, local files
// on the clipboard's `text/uri-list`. Empty when there are none.
static FlMethodResponse* clipboard_files() {
  GtkClipboard* clipboard = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  g_autoptr(FlValue) paths = fl_value_new_list();
  gchar** uris = gtk_clipboard_wait_for_uris(clipboard);
  for (gchar** uri = uris; uri != nullptr && *uri != nullptr; uri++) {
    g_autofree gchar* path = g_filename_from_uri(*uri, nullptr, nullptr);
    if (path != nullptr && g_file_test(path, G_FILE_TEST_IS_REGULAR)) {
      fl_value_append_take(paths, fl_value_new_string(path));
    }
  }
  g_strfreev(uris);
  return ok_response(paths);
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  LoafMediaPlugin* self = LOAF_MEDIA_PLUGIN(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);

  g_autoptr(FlMethodResponse) response = nullptr;
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  } else if (g_str_equal(method, "clipboard.has")) {
    response = clipboard_has();
  } else if (g_str_equal(method, "clipboard.image")) {
    response = clipboard_image();
  } else if (g_str_equal(method, "clipboard.files")) {
    response = clipboard_files();
  } else if (g_str_has_prefix(method, "stream.")) {
    response = stream_call(method, args);
  } else if (g_str_equal(method, "video.create")) {
    response = video_create(self, args);
  } else if (g_str_has_prefix(method, "video.")) {
    response = video_call(self, method, args);
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("[loaf media] %s: %s", method, error->message);
  }
}

static void loaf_media_plugin_dispose(GObject* object) {
  LoafMediaPlugin* self = LOAF_MEDIA_PLUGIN(object);
  // Views first: freeing one unregisters its texture and makes it idle.
  g_clear_pointer(&self->views, g_hash_table_unref);
  g_clear_pointer(&self->idle, g_ptr_array_unref);
  g_clear_object(&self->textures);
  g_clear_object(&self->channel);
  G_OBJECT_CLASS(loaf_media_plugin_parent_class)->dispose(object);
}

static void loaf_media_plugin_class_init(LoafMediaPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = loaf_media_plugin_dispose;
}

static void loaf_media_plugin_init(LoafMediaPlugin* self) {
  self->channel = nullptr;
  self->textures = nullptr;
  self->video_tried = FALSE;
  self->video = FALSE;
  self->idle = g_ptr_array_new_with_free_func(g_object_unref);
  self->views = g_hash_table_new_full(g_int64_hash, g_int64_equal, nullptr,
                                      video_view_free);
  self->next_view = 0;
}

void loaf_media_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  LoafMediaPlugin* plugin = LOAF_MEDIA_PLUGIN(
      g_object_new(loaf_media_plugin_get_type(), nullptr));

  plugin->textures = FL_TEXTURE_REGISTRAR(
      g_object_ref(fl_plugin_registrar_get_texture_registrar(registrar)));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  plugin->channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "moe.loaf.chat/media", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(plugin->channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  g_object_unref(plugin);
}
