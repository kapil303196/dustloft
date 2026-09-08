#!/usr/bin/env bash
# Builds Reclaim.app without Xcode — Swift Command Line Tools are enough.
set -euo pipefail
cd "$(dirname "$0")"

APP="Reclaim"
BUNDLE="dist/${APP}.app"

echo "==> Compiling (release)"
swift build -c release

echo "==> Assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp ".build/release/${APP}" "${BUNDLE}/Contents/MacOS/${APP}"
cp "Resources/Info.plist" "${BUNDLE}/Contents/Info.plist"
[ -f "Resources/${APP}.icns" ] && cp "Resources/${APP}.icns" "${BUNDLE}/Contents/Resources/"

# A stable identity matters: macOS ties Full Disk Access to the code signature,
# so an ad-hoc signature (which changes every build) silently revokes it.
IDENTITY="Reclaim Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "${IDENTITY}"; then
  echo "==> Signing with '${IDENTITY}' (stable across rebuilds)"
  codesign --force --deep --options runtime --sign "${IDENTITY}" "${BUNDLE}"
else
  echo "==> Signing ad-hoc (run ./tools/setup_signing.sh so permissions survive rebuilds)"
  codesign --force --deep --sign - "${BUNDLE}"
fi
codesign --verify --verbose "${BUNDLE}" 2>&1 | sed 's/^/    /'

echo "==> Built ${BUNDLE}"
