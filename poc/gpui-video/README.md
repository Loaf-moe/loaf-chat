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

## Cost

`tools/measure.py target/release/gpui-video-poc 20`. CPU is % of one core,
GPU is the process's own graphics-engine time from DRM fdinfo, both over 20 s
after a 3 s warm-up. Synthetic frames are generated up front, so this is the
display path alone (decode is extra and the same in any UI).

Ryzen 9 5900X, Radeon RX 9070 (RADV, Vulkan), Wayland, 1600×900 window,
2026-11-20:

| Scenario | CPU % core | GPU % | RSS MiB |
|---|---:|---:|---:|
| idle, 4 tiles, no frames | 0.0 | 0.00 | 88 |
| 4 × 720p30 | 4.5 | 1.36 | 169 |
| 9 × 720p30 | 7.7 | 2.64 | 169 |
| 4 × 1080p30 | 7.1 | 2.39 | 269 |
| 1 × 1080p60 | 4.1 | 1.81 | 268 |

Every delivered frame was painted (the app counts both). Idle is zero: GPUI
draws nothing when nothing changes.

## Run

```sh
cargo run --release -- --tiles 4 --res 1280x720 --fps 30
```

Flags: `--tiles N`, `--res WxH`, `--fps F`, `--seconds S` (quit after),
`--idle` (one frame per tile, then nothing).
