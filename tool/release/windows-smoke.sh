#!/usr/bin/env bash
# What a tester does with Setup, on the CI runner: install silently, open
# the app, check it stays up, then uninstall and check nothing is left.
# Between, it does what lib/update/bundle_swap.dart relies on: renames the
# running app's own files and puts new ones under their names.
# Runs in Git Bash. usage: windows-smoke.sh <Setup.exe>
set -euo pipefail
# Git Bash would read /VERYSILENT as a path and rewrite it.
export MSYS_NO_PATHCONV=1

setup="$1"
app="$(cygpath "$LOCALAPPDATA")/Programs/Loaf Chat"

running() { tasklist /FI "IMAGENAME eq loaf-chat.exe" /NH | grep -qi loaf-chat.exe; }

"$setup" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
for f in loaf-chat.exe unins000.exe unins000.dat data/app.so; do
  test -f "$app/$f" || { echo "::error::Setup left no $f"; exit 1; }
done

"$app/loaf-chat.exe" &
sleep 20
running || { echo "::error::Loaf Chat did not stay open"; exit 1; }

# Every kind of file a running build holds: its executable, the engine, the
# compiled Dart, and the data the engine maps.
for f in loaf-chat.exe flutter_windows.dll data/app.so data/icudtl.dat; do
  mv "$app/$f" "$app/$f.old" \
    || { echo "::error::a running build's $f cannot step aside"; exit 1; }
  cp "$app/$f.old" "$app/$f"
done
sleep 5
running || { echo "::error::Loaf Chat fell over when its files moved"; exit 1; }

taskkill /IM loaf-chat.exe /F
sleep 2
"$app/unins000.exe" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
# The uninstaller hands off to a copy of itself and returns at once.
for _ in $(seq 60); do
  [ -e "$app" ] || break
  sleep 1
done
if [ -e "$app" ]; then
  echo "::error::uninstalling left files behind:"
  find "$app"
  exit 1
fi
echo "installed, ran, swapped and uninstalled cleanly"
