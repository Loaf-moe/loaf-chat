# PoC: GPU video surfaces in GPUI on Linux

Shows that WebRTC-shaped video can be drawn by GPUI's wgpu renderer (Linux)
without any CPU colour conversion: I420 planes are uploaded as `R8Unorm`
textures and converted to RGB in the fragment shader.

Stock GPUI has `surface()` on macOS only (it takes a `CVPixelBuffer`). The
wgpu renderer already declares a `surfaces` pipeline and shader but its draw
arm is a no-op, and `PaintSurface` carries nothing off Apple platforms.

## The patch

`vendor/` holds `gpui-pre` 0.3.12 and `gpui-pre-wgpu` 0.3.12, the snapshot
gpui-component 0.10 pins, applied with `[patch.crates-io]`. Commit `dbf655b`
is the unmodified crates; `git diff dbf655b -- vendor` is the whole patch.

- **`gpui-pre`:** `VideoStream` / `VideoFrame` / `I420Planes`
  (`elements/video_frame.rs`). A frame wraps whatever owns the decoded
  buffer (a libwebrtc `I420Buffer` in the app) without copying it, and is
  validated on construction so the renderer can never read out of bounds.
  `surface(frame)` and `Window::paint_video_frame` work off Apple platforms.
- **`gpui-pre-wgpu`:** `wgpu_video.rs` keeps three plane textures per
  stream, re-uploads only when the frame's generation changes (a window
  repainting at 144 Hz uploads a 30 fps stream 30 times a second), passes
  the decoder's stride straight to `write_texture`, and evicts streams not
  painted this frame. Per-draw bounds, clip and colour matrix live in one
  dynamic-offset uniform buffer. The shader handles BT.601/BT.709 in
  limited or full range.

The one CPU copy left is wgpu staging the planes for upload. Removing it
means importing decoder output as dmabuf (VA-API decode), a separate step.

## Correctness

- `cargo test --release --test patch`: frame validation (tight and padded
  strides accepted, overruns rejected) and naga validation of both shader
  variants the renderer compiles.
- `tools/check_colours.py target/release/gpui-video-poc`: runs the PoC,
  screenshots it with grim and checks every BT.709 limited-range colour bar
  renders at its expected RGB. Result on 2026-11-20: all eight bars within
  ±1 level.

## Cost, against the Dart app's path

`tools/measure.py <binary> 20`, run on both binaries back to back. CPU is %
of one core, GPU is the process's own graphics-engine time from DRM fdinfo,
both over 20 s after a 5 s warm-up. Synthetic frames are generated up front,
so this is the display path alone (decode is extra and the same in either).

The Flutter side is `../flutter-video`: flutter_webrtc's Linux renderer path
(per-raster `ConvertToARGB` into a pixel buffer texture, the same
`libwebrtc.so`) in Flutter 3.47.5, which used Impeller on OpenGL ES here.

Ryzen 9 5900X, Radeon RX 9070 (RADV), Wayland, 2026-11-20:

| Scenario | GPUI CPU | Flutter CPU | GPUI GPU | Flutter GPU | GPUI RSS | Flutter RSS |
|---|---:|---:|---:|---:|---:|---:|
| idle, 4 tiles | 0.0 | 0.0 | 0.00 | 0.00 | 88 | 268 |
| 4 × 720p30 | 3.5 | 12.0 | 1.78 | 4.55 | 169 | 277 |
| 9 × 720p30 | 6.3 | 20.1 | 3.68 | 7.37 | 169 | 285 |
| 4 × 1080p30 | 5.7 | 20.6 | 2.19 | 7.55 | 268 | 396 |
| 1 × 1080p60 | 3.3 | 15.5 | 3.65 | 5.63 | 269 | 371 |

CPU and GPU in %, RSS in MiB. Both delivered and painted every frame. GPUI
uses 3.2–4.7× less CPU and 1.5–3.5× less GPU. Runs vary by about a point
of CPU (an earlier GPUI run read 4.5 / 7.7 / 7.1 / 4.1). The compositor
tiled the two windows to its own sizes, so raster area isn't identical;
uploads and conversion don't depend on it.

**Colour.** `check_colours.py` fails the Flutter path: yellow renders as
(252, 255, 12), red as (233, 0, 3), blue as (3, 0, 243). libwebrtc's
`ConvertToARGB` (libyuv `I420ToABGR`) always applies BT.601, so BT.709 video
shows shifted colours. The GPUI path applies each frame's own matrix.

## Run

```sh
cargo run --release -- --tiles 4 --res 1280x720 --fps 30
```

Flags: `--tiles N`, `--res WxH`, `--fps F`, `--seconds S` (quit after),
`--idle` (one frame per tile, then nothing).
