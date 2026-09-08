#!/usr/bin/env bash
# Installs the built app into /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP="Attic"
BUNDLE="dist/${APP}.app"
TARGET="/Applications/${APP}.app"

[ -d "${BUNDLE}" ] || { echo "Build first: ./build.sh"; exit 1; }

echo "==> Installing to ${TARGET}"
rm -rf "${TARGET}"
cp -R "${BUNDLE}" "${TARGET}"
echo "==> Installed. Launch with: open -a ${APP}"
echo
echo "NOTE: grant Full Disk Access for accurate sizes:"
echo "  System Settings > Privacy & Security > Full Disk Access > add ${TARGET}"
