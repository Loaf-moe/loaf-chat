#!/usr/bin/env bash
# Makes the three release signing keys. Run once, on a Mac.
# Private keys go to the folder you name, which must be outside the repo.
# Public keys go to tool/release/keys/, to be committed.
set -euo pipefail
umask 077

private="${1:?usage: keygen.sh <folder outside the repo for private keys>}"
public="$(cd "$(dirname "$0")" && pwd)/keys"
sparkle_version="${SPARKLE_VERSION:-2.8.0}"

# Validate that the private keys folder is outside the repo.
mkdir -p "$private"
private="$(cd "$private" && pwd -P)"
top="$(cd "$(git -C "$(dirname "$0")" rev-parse --show-toplevel)" && pwd -P)"
if [[ "$private" == "$top" ]] || [[ "$private" == "$top"/* ]]; then
  echo "that folder is inside the repo" >&2
  rmdir "$private" 2>/dev/null || true
  exit 1
fi

# Refuse if keys already exist; they are never replaced by re-running.
for file in "$private/appimage-private.pem" "$private/sparkle-private.txt" \
            "$private/flatpak-private.asc" "$private/gnupg" \
            "$public/appimage.pub" "$public/sparkle.pub" "$public/flatpak.asc"; do
  if [[ -e "$file" ]]; then
    echo "keys already exist at $file; they are never replaced by re-running" >&2
    exit 1
  fi
done

mkdir -p "$public"
chmod 700 "$private"

# Detect OpenSSL 3, which is required (macOS default is LibreSSL).
if [[ -n "${OPENSSL:-}" ]]; then
  openssl_bin="$OPENSSL"
elif openssl version 2>/dev/null | grep -q '^OpenSSL 3'; then
  openssl_bin="openssl"
elif [[ -x "$(brew --prefix openssl@3 2>/dev/null || true)/bin/openssl" ]]; then
  openssl_bin="$(brew --prefix openssl@3)/bin/openssl"
else
  echo "OpenSSL 3 not found; install with: brew install openssl@3" >&2
  exit 1
fi

# The AppImage key: Ed25519, read by lib/update/ed25519.dart.
"$openssl_bin" genpkey -algorithm ed25519 -out "$private/appimage-private.pem"
"$openssl_bin" pkey -in "$private/appimage-private.pem" -pubout -outform DER \
  | tail -c 32 | base64 > "$public/appimage.pub"

# Sparkle's key, made by Sparkle's own tool so its format is Sparkle's.
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
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
gpgconf --kill gpg-agent

echo "public keys:  $public  (commit these)"
echo "private keys: $private  (copy offline; never commit)"
