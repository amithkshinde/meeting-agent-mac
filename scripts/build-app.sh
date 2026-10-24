#!/bin/bash
# Builds MeetingAgent.app from the Swift package. Run on a Mac with Xcode or the Swift toolchain.
# Usage: scripts/build-app.sh [signing identity]
#   Default identity is "-" (ad-hoc). macOS forgets Screen Recording permission every time an
#   ad-hoc build changes. To keep it, create a self-signed "Meeting Agent Dev" certificate in
#   Keychain Access (Certificate Assistant > Create a Certificate > Code Signing) and pass its name.
set -euo pipefail

cd "$(dirname "$0")/.."
IDENTITY="${1:-}"
if [ -z "$IDENTITY" ]; then
  if security find-identity -p codesigning | grep -q "Meeting Agent Dev"; then
    IDENTITY="Meeting Agent Dev"
  else
    IDENTITY="-"
    echo "WARNING: no stable certificate found. Run scripts/setup-signing.sh once, or macOS will forget permissions on every build."
  fi
fi
echo "Signing with: $IDENTITY"
APP="build/MeetingAgent.app"

if [ -n "${ARCH:-}" ]; then
  # One chip only: ARCH=arm64 for Apple Silicon, ARCH=x86_64 for Intel. Gives a smaller app.
  echo "Building for ${ARCH} only..."
  swift build -c release --triple "${ARCH}-apple-macosx15.0"
  BIN="$(swift build -c release --triple "${ARCH}-apple-macosx15.0" --show-bin-path)/MeetingAgent"
elif [ "${UNIVERSAL:-0}" = "1" ]; then
  # One app that runs on both Apple Silicon and Intel Macs.
  echo "Building for Apple Silicon and Intel. This takes a little longer..."
  swift build -c release --triple arm64-apple-macosx15.0
  swift build -c release --triple x86_64-apple-macosx15.0
  ARM_BIN="$(swift build -c release --triple arm64-apple-macosx15.0 --show-bin-path)/MeetingAgent"
  X86_BIN="$(swift build -c release --triple x86_64-apple-macosx15.0 --show-bin-path)/MeetingAgent"
  mkdir -p build
  lipo -create "$ARM_BIN" "$X86_BIN" -output build/MeetingAgent-universal
  BIN="build/MeetingAgent-universal"
else
  swift build -c release
  BIN=".build/release/MeetingAgent"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MeetingAgent"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

# App icon: turn Resources/AppIcon.png into an .icns file (skipped quietly if the tools are missing).
if [ -f "Resources/AppIcon.png" ] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
  ICONSET="build/AppIcon.iconset"
  rm -rf "$ICONSET"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size "Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double "Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" || echo "Icon step skipped."
  rm -rf "$ICONSET"
fi

codesign --force --sign "$IDENTITY" "$APP"

echo "Built $APP"
echo "Run it with: open $APP"
