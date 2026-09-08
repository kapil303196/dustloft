#!/usr/bin/env bash
# Packages Reclaim.app into a drag-to-install DMG.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="Reclaim"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
BUNDLE="dist/${APP}.app"
STAGE="dist/dmg"
DMG="dist/${APP}-${VERSION}.dmg"

[ -d "${BUNDLE}" ] || { echo "Build first: ./build.sh"; exit 1; }

rm -rf "${STAGE}" "${DMG}"
mkdir -p "${STAGE}"
cp -R "${BUNDLE}" "${STAGE}/"
ln -s /Applications "${STAGE}/Applications"

cat > "${STAGE}/Read me first.txt" <<'TXT'
Reclaim

1. Drag Reclaim onto the Applications folder.
2. Open it. macOS will warn that the developer cannot be verified, because
   this build is not notarised by Apple. Right-click Reclaim in Applications
   and choose Open, then confirm. You only do this once.
3. Reclaim will ask for Full Disk Access and explain why. Grant it, then let
   Reclaim relaunch — macOS only applies that permission to a freshly
   launched app.

Reclaim never deletes anything without showing it to you first.
TXT

echo "==> Building ${DMG}"
hdiutil create -volname "${APP}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}" >/dev/null
rm -rf "${STAGE}"
echo "==> $(du -h "${DMG}" | cut -f1)  ${DMG}"
