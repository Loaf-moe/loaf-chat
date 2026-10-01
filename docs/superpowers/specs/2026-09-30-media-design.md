# loaf native — images, files and video (SDK phase 9)

Phase 9 of `docs/superpowers/plans/2026-09-26-sdk-wiring-roadmap.md`: media
sent to you arrives as media. Pictures show in the timeline, video plays in
place in each platform's real player, every file opens in the platform's own
viewer and can be saved, and encrypted rooms work the same as plain ones. The
phase also closes the phase 3 deferral of how long "didn't send" takes
offline. It amends, and never contradicts, `2026-09-20-loaf-native-design.md`
("send and receive text, images, files"; the media viewer among the edges).

Sending landed ahead of this phase (`0c77e3b`): the composer's + picks files
with each platform's picker and sends `m.image`, `m.video`, `m.audio` or
`m.file`.

## Scope

**In:**

- Received images, GIFs, video, audio and files drawn as media rows, with
  captions (MSC2530).
- Encrypted media (`file` / `thumbnail_file`) everywhere plain media works.
- Previews load as rows come into view. Full images, video and files load
  when opened, played or saved.
- Video plays inline, streaming while it downloads: AVPlayer on Apple,
  GStreamer on Linux.
- Opening: Quick Look on iOS and macOS, a Flutter viewer for images on
  Linux, and the OpenURI portal for other files on Linux.
- Saving: Save as… on desktop, the share sheet on iOS.
- Upload progress on a sending file.
- Edit offered on text, notice and emote rows only (deferred from phase 3).
- A per-request timeout, so "didn't send" shows within about 30 s offline
  (deferred from phase 3).
- The mock backend serves sample media, so tests and previews draw every
  row kind.

**Out, logged in the roadmap:**

| Deferred | Why |
|---|---|
| Dragging a media row out to Finder or Files | Save as… and Open cover it for now; it's `NSFilePromiseProvider` and a GTK drag source when it comes |
| Browsing a room's media from the viewer (next/previous) | It needs a media index per room, which the timeline doesn't keep |
| Audio playing inline (voice-message rows) | Audio opens in Quick Look or the default app |
| Checking an encrypted file against its SHA-256 | Chris's call: video plays as it arrives, and no half-measure is kept for saved files |
| Encrypting decrypted media at rest | Same class as the deferred sqlcipher database; both come before anyone but Chris uses the app |
| Resuming a download after a quit | tuwunel serves no byte ranges to resume from |

## Findings (verified 2026-09-30 against `matrix` 13.0.0 and tuwunel `main`)

- **Today every media message is a text row reading `📎 <body>`**
  (`lib/matrix/matrix_timeline.dart`, `_message`). A caption's HTML is
  dropped.
- **`Event.downloadAndDecryptAttachment` holds the whole file in memory**,
  and with `MatrixSdkDatabase.maxFileSize` at its default of 0 (as
  `openClient` leaves it) it caches nothing. It is fine for a thumbnail and
  wrong for a 300 MB video on a phone.
- **Matrix file encryption is AES-256-CTR.** `CryptoUtils.aesCtr(input, key,
  iv)` from `vodozemac` (already a direct dependency) is stateless, so any
  16-byte-aligned chunk decrypts alone with the IV advanced by its block
  index. Ciphertext and plaintext are the same length.
- **tuwunel sends media whole.** Its download handler
  (`src/api/client/media.rs`) handles no `Range` request and never answers
  `206`. AVPlayer will not play HTTP video from such a server, and libmpv
  plays it only front to back. So the server can't be streamed from
  directly, encrypted or not.
- **`video_player` has no Linux backend,** and its AVFoundation backend makes
  its own `AVURLAsset`, so it can't take a resource loader delegate. It is
  not used.
- **`media_kit` can't be a dependency.** `media_kit_video` declares iOS and
  macOS plugins that are CocoaPods-only and link `-framework Mpv`. A Dart
  dependency can't be limited to Linux, and our Apple builds are pure Swift
  Package Manager, so it would break them.
- **AVFoundation's hook for custom streaming is
  `AVAssetResourceLoaderDelegate`:** an asset with a custom URL scheme asks
  the delegate for byte ranges as it plays.
- **GStreamer's hook for custom streaming is a source element:** a `BaseSrc`
  subclass that implements `URIHandler` for a scheme is what `playbin` uses
  for that scheme's URIs. `gstreamer-rs`, maintained by the GStreamer
  developers, subclasses both in Rust.
- **The Flatpak packs the bundle the Ubuntu 22.04 runner built** and compiles
  nothing (`linux/packaging/moe.loaf.chat.yml`). The GNOME 51 runtime
  already carries GStreamer, and the manifest already has
  `--socket=pulseaudio`. Linux video adds no Flatpak module and no
  permission. (A release that adds a permission can't update in-app.)
- **The SDK already limits idle response bodies.** `Client` wraps every
  `httpClient` in `FixedTimeoutHttpClient`, which times out a response
  stream with no data for 35 s (`defaultNetworkRequestTimeout`). Nothing
  limits the wait for response headers, which for an upload includes
  sending the whole body.
- **`Client.sendTimelineEventTimeout`** (default 1 min) is checked only after
  an attempt fails, so an attempt hung on a dead network is never cut off.
- **A sending file's bytes are on disk.** `Room.sendFileEvent` stores them as
  `cache://file/<txid>` (and a thumbnail as `cache://thumbnail/<txid>`) in
  the SDK's file store before its echo appears.
- **The SDK's old-file cleanup skips directories,** so a `files/` folder
  inside the media directory is ours alone.
- **Sign-out already clears the media directory** (`5e90a40`), folders
  included.

## The seam

### `Media`

`ui.Message` gains `Media? media`, null for text. It replaces the mock's
`imageAspect` placeholder.

```dart
enum MediaKind { image, video, audio, file }

class Media {
  final MediaKind kind;
  final String name;          // the file's name, as sent
  final int? size;            // bytes, when the sender said
  final String? mimeType;
  final Size? dimensions;     // image/video w×h, for layout before load
  final Duration? duration;   // video/audio
  final bool hasPreview;      // a thumbnail exists, or the image is small
  final Object ref;           // opaque: only the backend that made it reads it
}
```

- **Kind** comes from `msgtype`. `m.sticker` maps to an image.
- **Caption:** when `filename` is present and differs from `body`, `body`
  (and `formatted_body`) is a caption, drawn under the media through the
  existing `Message.body` / `formatted`. Otherwise the message has no text.
- **`ref`** for Matrix holds the event's media content (url or file map,
  thumbnail url or file map, info), so nothing looks the event up again.

### `MediaSource`

In `lib/ui/model/media_source.dart`, provided like `AvatarImages` through
the overlay-safe scope.

```dart
abstract interface class MediaSource {
  /// The row's picture: a thumbnail, or the image itself when it is small.
  /// Null when the row should offer "load" rather than fetch on its own.
  ImageProvider? preview(Media media, double physicalWidth);

  /// The full image, for the viewer.
  ImageProvider image(Media media);

  /// The file on disk: started on first ask, shared by every caller,
  /// kept in the media cache.
  MediaFile open(Media media);
}

abstract interface class MediaFile implements Listenable {
  int get received;           // bytes on disk so far
  int? get total;
  String get partialPath;     // the growing file the players read
  Future<String> get path;    // completes when the whole file is down
  Object? get error;
  void retry();
}
```

The UI never sees a URL, an mxc or a key.

- **`MatrixMediaSource`** (`lib/matrix/`) is the only code that knows mxc,
  encrypted file maps and the download pipeline.
- **`MockMediaSource`** serves bundled samples: a landscape photo, a portrait
  photo, a GIF, a short MP4 and a PDF.

## The download pipeline

One download per mxc, shared by every caller of `open`:

1. GET the authenticated media URL (`/_matrix/client/v1/media/download/…`,
   bearer token) as a streamed response.
2. Encrypted: decrypt each chunk with `aesCtr`, the IV advanced to the
   chunk's block offset, carrying a partial 16-byte remainder into the next
   chunk. Plain: pass through.
3. Append to `media/files/<sha256(mxc)>/<name>.part`, notify listeners as
   bytes land, and rename to `<name>` when complete. `<name>` is the
   sender's file name made safe for a path, so Quick Look, the default app
   and the save panel all see a real name and extension.
4. A failure (offline, gone from the server, refused) becomes
   `MediaFile.error`, and `retry()` starts again from zero.

A `.part` left by a quit is deleted and restarted.

### Previews

| Media | Preview |
|---|---|
| Has `thumbnail_file` / `thumbnail_url` | The thumbnail, through the pipeline |
| Plain image, no thumbnail | The server's thumbnail endpoint, in buckets of 64, 128, 320, 640 and 1280 px |
| Encrypted image, no thumbnail, ≤ 2 MB | The image itself, through the pipeline |
| Encrypted image, no thumbnail, > 2 MB | None: a sized placeholder with "load" |
| Video with no thumbnail | A sized placeholder with the play badge |

Decoding goes through `ResizeImage` at the row's physical width, so a large
photo doesn't decode at full size to draw a 400 px row.

### The cache

- Lives in `media/files/` under the media directory, which sign-out already
  clears. Sign-out also cancels running downloads.
- Capped at 2 GB, evicting least recently used files at launch and after each
  download. A file being played, opened or saved is never evicted.

## Video

The player reads the growing `.part` file through each platform's own
streaming hook. A read past what has arrived waits for more, and fails if the
download fails.

Both players live in one local Flutter plugin, `packages/loaf_media/`, with
shared Swift for iOS and macOS (`sharedDarwinSource`, Swift Package
Manager) and a Linux plugin. Quick Look and the macOS default-app calls
live there too.

### Apple: Swift

- An `AVURLAsset` for `loaf-media://<file id>` whose
  `AVAssetResourceLoaderDelegate` answers content information (length, type)
  and data requests from the `.part` file, holding a request until Dart
  reports the bytes it needs.
- Dart reports progress over the plugin's method channel.
- The range bookkeeping is a pure Swift type, apart from the AVFoundation
  glue, so XCTest can test it.
- Shown as a platform view: `AVPlayerView` (inline controls) on macOS, an
  embedded `AVPlayerViewController` on iOS, with its full screen, picture in
  picture and AirPlay.

### Linux: GStreamer, in Rust

- **A Rust crate** (`packages/loaf_media/linux/rust/`, a `staticlib`) on
  `gstreamer`, `gstreamer-base`, `gstreamer-app` and `gstreamer-video`:
  - **`loafsrc`**, a `BaseSrc` subclass implementing `URIHandler` for
    `loaf-media://<id>`, registered with the process at plugin start.
    `create(offset, length)` waits on a `Condvar` under a `Mutex` until the
    download covers the range, completes or fails. `unlock` and
    `unlock_stop`, GStreamer's flush hooks, wake it. `size` gives the total
    once known, and `is_seekable` is true.
  - **A player:** `playbin` with an `appsink` for `video/x-raw,format=RGBA`
    as its video sink. The newest frame is kept behind a `Mutex`, and a
    callback says a frame is ready.
  - **Its C API:** create, play, pause, seek, position, duration, state and
    dispose, plus `progress(id, received, total, state)` for downloads and
    `frame(player)` for the texture. Every `extern "C"` function catches
    panics, and nothing `unwrap`s.
- **A thin C plugin** (`packages/loaf_media/linux/`) is the Flutter glue the
  Linux embedder needs. It handles registration, an `FlPixelBufferTexture`
  whose `copy_pixels` takes the newest frame from Rust, the method channel,
  and marking frames available on the main loop. CMake builds the crate
  with `cargo` and links it statically.
- **Controls** are drawn in Flutter (play/pause, scrubber, time, mute, full
  window), since Linux has no native player UI.
- GStreamer comes from the system: the GNOME runtime in the Flatpak, and the
  host in the AppImage. Codecs are whatever that GStreamer has. A video it
  can't decode says so and offers Open.

### Playback rules

- Only one video plays at a time. Scrolling a playing video out of view
  pauses it.
- An iPhone camera original with its index (`moov`) at the end can't start
  until the download reaches it. The row shows download progress until it
  does.

## On screen

### Rows

- **Image:** the preview at its real aspect, sized from `dimensions` before
  it loads, up to 400 × 360 on a computer and the column width on a phone,
  with large radius corners like the mock placeholder. A GIF within the
  preview cap animates inline; a larger one shows its still thumbnail with a
  GIF badge until opened.
- **Video:** the thumbnail with a play badge and duration. Play swaps in the
  platform's player in place.
- **Audio, file:** a card with a type icon, name and size, and a progress ring
  while downloading.
- **Caption:** under the media, selectable on a computer like any message.
- **Loading:** the sized placeholder. **Failed:** "couldn't load · try again"
  in place.
- **Sending:** an outgoing file draws from the picked local file, dimmed like
  any sending message, with "uploading 42%" from the upload's progress.

### Opening

| | Images | Video | Other files |
|---|---|---|---|
| iOS | `QLPreviewController` | inline player | `QLPreviewController` |
| macOS | `QLPreviewPanel` | inline player | `QLPreviewPanel`, or the default app |
| Linux | Flutter viewer | inline player | default app via the OpenURI portal's `OpenFile` |

- **iOS Quick Look** gives pinch zoom, swipe down to close, and a share sheet
  with Save Image and Save to Files.
- **macOS Quick Look** is Finder's panel. Space on a focused media row opens
  it, as in Finder.
- **The Linux image viewer** zooms by scroll or pinch, pans, offers Save as…,
  and closes with Escape.
- Open waits for the whole file, showing progress on the row.

### Actions

Media rows add to the existing message actions:

- **Desktop:** Open, Open with <default app> (macOS, `NSWorkspace`), Save
  as… (`NSSavePanel` on macOS; the GTK chooser, which is the file chooser
  portal inside Flatpak, on Linux).
- **iOS:** Open, Share (the system share sheet).
- **Edit** is offered on text, notice and emote rows only.

## Timeouts

`openClient` gets `LoafHttpClient` (`lib/matrix/`), an `http.BaseClient`
over an `IOClient` whose `HttpClient` has a 10 s `connectionTimeout`.

| Request | Limit |
|---|---|
| `/sync` | none added; it long-polls by design |
| Media upload | 30 s idle: the body is re-chunked into 64 KB pieces, and no chunk accepted by the socket for 30 s fails the attempt. The same chunks report upload progress |
| Media download (the pipeline) | 20 s for headers; the SDK's own 35 s idle limit on the body |
| Anything else | 20 s per attempt |

`sendTimelineEventTimeout` drops from 1 min to 30 s.

## Errors

- **Download failed:** in place, "couldn't load · try again".
- **Too big to upload:** already handled by the composer (the server's
  upload limit).
- **Open or save failed** (no default app, disk full, the panel refused):
  a toast that says which, and the row stays as it was.
- **Playback failed** (codec, corrupt file): the player's own error on Apple;
  on Linux, "couldn't play this · open it instead" with Open beside it.

## Testing

Existing tests pass unchanged.

- **Chunked decryption** equals the SDK's whole-file decrypt across random
  sizes and chunk boundaries (1, 15, 16, 17 bytes, 64 KB ± 1). Needs the
  macOS build, like the other encryption tests.
- **The pipeline**, over `MockClient` streaming chunks: shared downloads,
  progress, failure and retry, idle timeout, sign-out cancelling and
  clearing, eviction sparing files in use, a `.part` from a quit restarting.
- **Mapping**, over `FakeMatrixApi`: each `msgtype` to `Media`, captions,
  encrypted and plain thumbnails, missing `info`.
- **Widgets**, on the mock backend: each row kind, loading and failed states,
  Edit absent on media, desktop and phone actions.
- **Rust** (`cargo test`): `loafsrc` blocking past the download and waking on
  progress, seeking, size, failure and flush waking it with an error,
  threaded stress on the `Condvar`, and a `playbin` pipeline playing a
  sample file through `loafsrc` while a thread feeds it.
- **Swift** (XCTest): the resource loader's range bookkeeping.
- **`LoafHttpClient`** under `fake_async`: per-request limits, upload idle,
  the `/sync` exemption.

**By hand on loaf.moe**, logged in the roadmap: an encrypted image and video
from FluffyChat; an iPhone camera original; a 200 MB file; a send while
offline; Quick Look on iOS and macOS; video in the Flatpak and the AppImage.

## Release

- **The Linux runner** installs `libgstreamer1.0-dev` and
  `libgstreamer-plugins-base1.0-dev`, and Rust through mise. The crate
  targets the GStreamer 1.20 on Ubuntu 22.04, the oldest it will meet.
- **Flatpak:** unchanged. It packs that bundle, and the GNOME 51 runtime
  provides GStreamer. Task 8 checks which codecs the runtime decodes (H.264
  needs the `codecs-extra` extension) and records it.
- **AppImage:** doesn't bundle GStreamer; it links the host's, like GTK.
- **The Rust toolchain** is pinned in `mise.toml`.
- **Apple:** the plugin ships in the app. No new entitlements: both already
  have `files.user-selected.read-write`.

## Order

1. `Media`, `MediaSource` and the mock source, with rows on the mock backend.
2. `LoafHttpClient` and the shorter send timeout.
3. The download pipeline, chunked decryption and the cache.
4. Matrix mapping and `MatrixMediaSource`: images and files work end to end.
5. Opening and saving: Quick Look, the Linux viewer and portal, save panels.
6. Video on Apple: Swift in `loaf_media`.
7. Video on Linux: the Rust crate, the C glue and Flutter controls.
8. Release: GStreamer and Rust on the Linux runner, the codec check.
9. Checks by hand on loaf.moe, and the roadmap updated.
