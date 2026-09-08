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

EASIEST INSTALL (skips the macOS security warning entirely)
-----------------------------------------------------------
Open Terminal and paste this one line:

  curl -fsSL https://raw.githubusercontent.com/kapil303196/reclaim/main/install-online.sh | bash

That downloads and installs the same app you are looking at now. It avoids the
warning because macOS only quarantines files downloaded by a browser, not by
curl.


INSTALLING FROM THIS DISK IMAGE
-------------------------------
1. Drag Reclaim onto the Applications folder.

2. Open it. macOS will say it "could not verify this app is free from malware".
   That is expected: this build is not notarised by Apple, which requires a paid
   Apple Developer account. It is not a statement that anything was found.

3. On macOS 15 and later, Control-clicking and choosing Open no longer works.
   Instead go to:

     System Settings > Privacy & Security

   Scroll down. There will be a line saying Reclaim was blocked, with an
   "Open Anyway" button. Click it, then open Reclaim again.

   Or, in Terminal:

     xattr -dr com.apple.quarantine /Applications/Reclaim.app


AFTER INSTALLING
----------------
Reclaim asks for Full Disk Access and explains why. macOS applies that
permission only to a freshly launched app, so Reclaim restarts itself once.

Reclaim never deletes anything without showing it to you first.
TXT

echo "==> Building ${DMG}"
hdiutil create -volname "${APP}" -srcfolder "${STAGE}" -ov -format UDZO "${DMG}" >/dev/null
rm -rf "${STAGE}"
shasum -a 256 "${DMG}" | tee "${DMG}.sha256"
echo "==> $(du -h "${DMG}" | cut -f1)  ${DMG}"
