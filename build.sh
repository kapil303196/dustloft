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

echo "==> Signing (ad-hoc)"
codesign --force --deep --sign - "${BUNDLE}"
codesign --verify --verbose "${BUNDLE}" 2>&1 | sed 's/^/    /'

echo "==> Built ${BUNDLE}"
