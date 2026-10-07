# Loaf Chat

A Matrix client for loaf.moe, shaped like a place you hang out.

## Running the tests

Encryption tests load vodozemac's native library, and fail saying so without
it. On macOS, build the app once with `mise exec -- flutter build macos
--debug`. On Linux, build just the library once with `sh tool/build-vodozemac`
(it needs `flutter pub get` first, and Rust). Then run
`mise exec -- flutter test`.

## Building on Linux

Video plays through GStreamer, and the player is a Rust crate that CMake
builds with cargo. Install the development packages, then Rust:

```nu
sudo apt-get install -y libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev
mise install
```

`mise install` brings Rust (pinned in `mise.toml`) along with Flutter. Run the
build as `mise exec -- flutter build linux` so cargo is on the path.

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
Preview that page with `tool/release/site.sh <latest.json> <out dir>`.
The signing keys were made once by `tool/release/keygen.sh`.

## Licence

AGPL-3.0-only. See `LICENSE`.
