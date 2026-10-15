# Loaf Chat

A Matrix client for loaf.moe, shaped like a place you hang out.

## Running the tests

Tools, environment and tasks all come from `mise.toml`. `mise install` brings
the toolchains and then every Dart package and Rust crate; run it again after
a pull to catch up. `mise tasks` lists what there is to run.

Encryption tests load vodozemac's native library, and fail saying so without
it. On macOS, build the app once with `mise run build:macos`. On Linux, build
just the library once with `mise run vodozemac` (after `mise install`). Then
run `mise run test:all`, and `mise run check` for the analyzer and the
formatter.

## Building on macOS

Xcode, selected with `sudo xcode-select -s
/Applications/Xcode.app/Contents/Developer`, and for iOS its platform:
`xcodebuild -downloadPlatform iOS`. Plugins come as Swift packages, so
CocoaPods is not needed. `mise run run:macos` runs the app on the Mac and
`mise run run:ios:sim` in a simulator.

## Building on Linux

Video plays through GStreamer, and the player is a Rust crate that CMake
builds with cargo. Install the development packages, then Rust:

```nu
sudo apt-get install -y libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
mise install
```

`mise install` brings Rust (pinned in `mise.toml`) along with Flutter. Run the
build as `mise run build:linux` so cargo is on the path.

Flutter's engine expects GTK's Wayland backend. Where GTK is built for X11
alone, the build adds `libgdk-wayland-stub.so` to the bundle to stand in for
it.

Voice channels use LiveKit's client, which links WebRTC. On Linux the build
fetches a prebuilt `libwebrtc.so` from
<https://github.com/webrtc-sdk/libwebrtc/releases> while CMake configures,
keeps the zip in `flutter_webrtc`'s own directory in the pub cache
(`third_party/downloads/`), and copies the library into the bundle's `lib/`.
A zip already there is used as it is. The library needs libX11, libXcomposite,
libXdamage, libXext, libXfixes, libXrandr, libgbm and libdrm to load, and
PulseAudio's or ALSA's client library to open a microphone.

## Installing

Download Loaf Chat for macOS, Windows or Linux from <https://get.loaf.moe>.
Every copy installed from there updates itself. Phones get Loaf Chat through
TestFlight.

The Windows build isn't signed. SmartScreen warns on first run (More info,
then Run anyway), and Smart App Control, where it is on, blocks it outright.
Setup installs for the current user only and never asks for admin.

## Releasing

Push a tag like `v0.1.0` that sits on `main`. `.github/workflows/release.yml`
does the rest: it builds, signs and notarizes (on Windows, only the feed
entry is signed), publishes a GitHub Release, and rewrites get.loaf.moe,
including the download page in `tool/release/site/`.
The same tag sends iOS to TestFlight, where the Testing group picks it up.
Every step it takes is a `release:*` task in `mise.toml`, runnable by hand.
Preview that page with `mise run release:site <latest.json> <out dir>`.
The signing keys were made once by `mise run release:keygen`.

## Licence

AGPL-3.0-only. See `LICENSE`.
