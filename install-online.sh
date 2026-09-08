#!/usr/bin/env bash
# One-command install of the latest Reclaim release.
#
# Why this exists: a DMG downloaded through a browser is tagged with
# com.apple.quarantine, and macOS 15 removed the Control-click -> Open bypass
# for apps that are not notarised. curl does not apply that tag, so installing
# this way avoids the "cannot verify it is free from malware" dialog entirely.
set -euo pipefail

REPO="kapil303196/reclaim"
APP="Reclaim"
TARGET="/Applications/${APP}.app"

say() { printf "==> %s\n" "$1"; }

say "Finding the latest release"
URL=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | grep -o '"browser_download_url": *"[^"]*\.dmg"' \
  | head -1 | cut -d'"' -f4)
[ -n "${URL:-}" ] || { echo "No DMG found in the latest release."; exit 1; }
say "Downloading $(basename "$URL")"

TMP="$(mktemp -d)"
trap 'hdiutil detach "$TMP/mnt" -quiet >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/reclaim.dmg" "$URL"

say "Mounting"
mkdir -p "$TMP/mnt"
hdiutil attach "$TMP/reclaim.dmg" -nobrowse -quiet -mountpoint "$TMP/mnt"
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

say "Installed. Opening ${APP}"
open -a "$APP"

cat <<'NOTE'

Reclaim will ask for Full Disk Access on first run and explain why.
macOS applies that permission only to a freshly launched app, so Reclaim
restarts itself once after you grant it.
NOTE
