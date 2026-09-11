#!/usr/bin/env bash
# One-command install of the latest Dustloft release.
#
# Why this exists: a DMG downloaded through a browser is tagged with
# com.apple.quarantine, and macOS 15 removed the Control-click -> Open bypass
# for apps that are not notarised. curl does not apply that tag, so installing
# this way avoids the "cannot verify it is free from malware" dialog entirely.
set -euo pipefail

REPO="kapil303196/dustloft"
APP="Dustloft"

say() { printf "==> %s\n" "$1"; }

# /Applications is writable only by admin accounts. A standard account (common
# on work Macs) gets "Permission denied", so fall back to the per-user
# Applications folder, which macOS treats the same for launching and Spotlight.
DEST="/Applications"
if [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
  mkdir -p "$DEST"
  say "No write access to /Applications (not an admin account); using ${DEST}"
fi
TARGET="${DEST}/${APP}.app"

say "Finding the latest release"
URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.dmg"' \
  | head -1 | cut -d'"' -f4)
[ -n "${URL:-}" ] || { echo "No DMG found in the latest release."; exit 1; }
say "Downloading $(basename "$URL")"

TMP="$(mktemp -d)"
# -force: the image is read-only and we are done with it, and a plain detach can
# sit retrying for a long time if Spotlight has touched the volume. It also keeps
# rm -rf from descending into a volume that is still mounted.
trap 'hdiutil detach "$TMP/mnt" -force -quiet >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/dustloft.dmg" "$URL"

say "Mounting"
mkdir -p "$TMP/mnt"
hdiutil attach "$TMP/dustloft.dmg" -nobrowse -quiet -mountpoint "$TMP/mnt"
[ -d "$TMP/mnt/${APP}.app" ] || { echo "Disk image did not contain ${APP}.app"; exit 1; }

if pgrep -f "${APP}.app" >/dev/null 2>&1; then
  say "Quitting the running copy"
  osascript -e "quit app \"${APP}\"" >/dev/null 2>&1 || true
  sleep 2
fi

say "Installing to ${TARGET}"
rm -rf "$TARGET"
# ditto preserves the code signature and extended attributes; cp does not.
ditto "$TMP/mnt/${APP}.app" "$TARGET"

# Defensive: strip quarantine even though curl should not have set it.
xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true

# LaunchServices may not know about the bundle yet, and `open -a NAME` resolves
# through its database — which is why opening by name can fail right after a
# fresh copy. Register it, then open by full path.
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
[ -x "$LSREG" ] && "$LSREG" -f "$TARGET" >/dev/null 2>&1 || true

say "Verifying the installed app"
if ! codesign --verify --deep --strict "$TARGET" 2>/dev/null; then
  echo "    note: signature check reported an issue; the app is ad-hoc signed, which is expected"
fi

say "Opening ${APP}"
if ! open "$TARGET" 2>/tmp/dustloft-open.err; then
  echo
  echo "Could not open it automatically. The app is installed at:"
  echo "  $TARGET"
  echo
  echo "Open it from Finder, or run:"
  echo "  open '$TARGET'"
  echo
  [ -s /tmp/dustloft-open.err ] && { echo "macOS said:"; sed 's/^/  /' /tmp/dustloft-open.err; }
  exit 0
fi

sleep 3
if ! pgrep -f "${APP}.app" >/dev/null 2>&1; then
  echo
  echo "${APP} was installed but is not running yet. If macOS blocked it, open"
  echo "System Settings > Privacy & Security, scroll down, and click Open Anyway."
fi

cat <<'NOTE'

Dustloft will ask for Full Disk Access on first run and explain why.
macOS applies that permission only to a freshly launched app, so Dustloft
restarts itself once after you grant it.
NOTE
