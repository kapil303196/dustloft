#!/usr/bin/env bash
# Builds Dustloft.app without Xcode — Swift Command Line Tools are enough.
set -euo pipefail
cd "$(dirname "$0")"

APP="Dustloft"
BUNDLE="dist/${APP}.app"
BIN=".build/release/${APP}"

echo "==> Compiling (release)"
# UNIVERSAL=1 produces one binary that runs natively on both Apple Silicon
# and Intel Macs, which is what a downloadable DMG has to ship.
if [ "${UNIVERSAL:-0}" = "1" ]; then
  # Multi-arch builds go through xcbuild, which ships with full Xcode only.
  # CI has it; a Command Line Tools machine does not, so fall back cleanly
  # rather than failing the whole build.
  if swift build -c release --arch arm64 --arch x86_64 2>/dev/null; then
    BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/${APP}"
  else
    echo "    universal build needs full Xcode; falling back to this machine's architecture"
    swift build -c release
    BIN=".build/release/${APP}"
  fi
else
  swift build -c release
  BIN=".build/release/${APP}"
fi

echo "==> Assembling ${BUNDLE}"
rm -rf "${BUNDLE}"
mkdir -p "${BUNDLE}/Contents/MacOS" "${BUNDLE}/Contents/Resources"
cp "${BIN}" "${BUNDLE}/Contents/MacOS/${APP}"
cp "Resources/Info.plist" "${BUNDLE}/Contents/Info.plist"
[ -f "Resources/${APP}.icns" ] && cp "Resources/${APP}.icns" "${BUNDLE}/Contents/Resources/"

# A stable identity matters: macOS ties Full Disk Access to the code signature,
# so an ad-hoc signature (which changes every build) silently revokes it.
IDENTITY="Dustloft Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "${IDENTITY}"; then
  echo "==> Signing with '${IDENTITY}' (stable across rebuilds)"
  codesign --force --deep --options runtime --sign "${IDENTITY}" "${BUNDLE}"
else
  echo "==> Signing ad-hoc (run ./tools/setup_signing.sh so permissions survive rebuilds)"
  codesign --force --deep --sign - "${BUNDLE}"
fi
codesign --verify --verbose "${BUNDLE}" 2>&1 | sed 's/^/    /'

echo "==> Built ${BUNDLE}"
