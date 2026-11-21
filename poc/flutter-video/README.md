# Flutter baseline for the GPUI video PoC

The GPUI PoC's scenario (`../gpui-video`) through the Dart app's Linux video
path, so the two can be measured the same way.

## What it reproduces

`flutter_webrtc` at the revision loaf-native main pins (Loaf-moe fork
`5462125`), where it costs anything:

- an `FlPixelBufferTexture` per renderer whose `copy_pixels` runs
  `RTCVideoFrame::ConvertToARGB(kABGR)` on the latest frame, under the
  renderer's mutex, every time Flutter rasterizes the texture
  (`common/cpp/src/flutter_video_renderer.cc`, `CopyPixelBuffer`);
- `fl_texture_registrar_mark_texture_frame_available` called straight from
  the thread delivering the frame (`OnFrame`);
- the same prebuilt `libwebrtc.so` (m150.7871.03), linked through the fork's
  own CMake;
- each tile is `RTCVideoView`'s widget tree (contain, `FilterQuality.low`).

Frames, flags, window size and label are the GPUI PoC's, so
`../gpui-video/tools/measure.py` and `check_colours.py` drive either binary.
`linux/runner/video_harness.cc` is the native side; `lib/main.dart` the UI.

## Build and run

```sh
flutter build linux --release      # Flutter 3.47.5, as main pins
build/linux/x64/release/bundle/flutter_video_poc --tiles 4 --res 1280x720 --fps 30
```

Results are in `../gpui-video/README.md`.
