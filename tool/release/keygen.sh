#!/usr/bin/env bash
# Makes the three release signing keys. Run once, on a Mac.
# Private keys go to the folder you name, which must be outside the repo.
# Public keys go to tool/release/keys/, to be committed.
set -euo pipefail

private="${1:?usage: keygen.sh <folder outside the repo for private keys>}"
public="$(cd "$(dirname "$0")" && pwd)/keys"
sparkle_version="${SPARKLE_VERSION:-2.8.0}"

case "$(cd "$(dirname "$private")" && pwd)/" in
  "$(git rev-parse --show-toplevel)"/*) echo "that folder is inside the repo" >&2; exit 1 ;;
esac
mkdir -p "$private" "$public"
chmod 700 "$private"

# The AppImage key: Ed25519, read by lib/update/ed25519.dart.
openssl genpkey -algorithm ed25519 -out "$private/appimage-private.pem"
openssl pkey -in "$private/appimage-private.pem" -pubout -outform DER \
  | tail -c 32 | base64 > "$public/appimage.pub"

# Sparkle's key, made by Sparkle's own tool so its format is Sparkle's.
work="$(mktemp -d)"
curl -fsSL "https://github.com/sparkle-project/Sparkle/releases/download/$sparkle_version/Sparkle-$sparkle_version.tar.xz" \
  | tar -xJ -C "$work"
"$work/bin/generate_keys" --account moe.loaf.chat >/dev/null
"$work/bin/generate_keys" --account moe.loaf.chat -p > "$public/sparkle.pub"
"$work/bin/generate_keys" --account moe.loaf.chat -x "$private/sparkle-private.txt"

# The Flatpak repo's key: GPG, no passphrase, because CI signs unattended.
export GNUPGHOME="$private/gnupg"
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
gpg --batch --passphrase '' --quick-generate-key \
  'Loaf Chat releases <releases@loaf.moe>' ed25519 sign never
gpg --armor --export > "$public/flatpak.asc"
gpg --armor --export-secret-keys > "$private/flatpak-private.asc"

echo "public keys:  $public  (commit these)"
echo "private keys: $private  (copy offline; never commit)"
