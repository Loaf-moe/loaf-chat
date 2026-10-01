# Loaf Chat

A Matrix client for loaf.moe, shaped like a place you hang out.

## Running the tests

Build the macOS app once with `mise exec -- flutter build macos --debug`,
then run `mise exec -- flutter test`. Encryption tests load vodozemac's
native library from that build, and fail saying so without it.

## Installing

Download Loaf Chat for macOS or Linux from <https://get.loaf.moe>. Every copy
installed from there updates itself. Phones get Loaf Chat through TestFlight.

## Releasing

Push a tag like `v0.1.0` that sits on `main`. `.github/workflows/release.yml`
does the rest: it builds, signs and notarizes, publishes a GitHub Release, and
rewrites get.loaf.moe, including the download page in `tool/release/site/`.
The same tag sends iOS to TestFlight, where the Testing group picks it up.
Preview that page with `tool/release/site.sh <latest.json> <out dir>`.
The signing keys were made once by `tool/release/keygen.sh`.

## Licence

AGPL-3.0-only. See `LICENSE`.
