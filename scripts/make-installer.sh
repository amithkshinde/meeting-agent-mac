#!/bin/bash
# Builds two installers you can send to someone else:
#   dist/MeetingAgent-<version>-arm64.dmg   for Apple Silicon Macs (M1, M2, M3, M4...)
#   dist/MeetingAgent-<version>-intel.dmg   for Intel Macs
# Run it on your Mac (double-click "Make Installer.command" in the project folder).
# Usage: scripts/make-installer.sh [signing identity]
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(uname)" != "Darwin" ]; then
  echo "This has to run on a Mac."
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
mkdir -p dist

# Not sure which chip you have? Apple menu > About This Mac. "Chip: Apple M..." is Apple Silicon,
# "Processor: Intel..." is Intel.

make_dmg() {
  local ARCH="$1" CHIP="$2" CHIPNAME="$3" LOCALAI="$4"
  local NAME="MeetingAgent-${VERSION}-${CHIP}"
  local DMG="dist/${NAME}.dmg"
  local STAGE="build/dmg-${CHIP}"

  echo
  echo "=== ${CHIPNAME} installer ==="

  # 1. Build and sign the app (uses the same "Meeting Agent Dev" certificate as your own builds).
  ARCH="$ARCH" scripts/build-app.sh ${SIGN[@]+"${SIGN[@]}"}
  local ARCHS
  ARCHS="$(lipo -archs build/MeetingAgent.app/Contents/MacOS/MeetingAgent)"
  echo "Built for: $ARCHS"
  if [ "$ARCHS" != "$ARCH" ]; then
    echo "The app was built for '$ARCHS' but '$ARCH' was expected. Copy the text above and report it at https://github.com/amithkshinde/meeting-agent-mac/issues"
    exit 1
  fi

  # 2. Lay out what the person will see when they open the disk image.
  rm -rf "$STAGE"
  mkdir -p "$STAGE"
  ditto "build/MeetingAgent.app" "$STAGE/Meeting Agent.app"
  ln -s /Applications "$STAGE/Applications"

  cat > "$STAGE/READ ME FIRST.txt" <<TXT
MEETING AGENT  -  INSTALL IN 3 STEPS

This installer is for ${CHIPNAME} Macs, running macOS 15 or later.
macOS 26 gives the best live transcript.


STEP 1.  Install
Drag "Meeting Agent" onto the "Applications" folder in this window.


STEP 2.  Open it the first time
macOS shows a warning because this app is shared directly with you and
is not from the App Store. It is safe to allow. You only do this once.

  a) Open your Applications folder and double-click Meeting Agent.
     A message says it can't be opened. Click "Done" (or "OK").
  b) Open System Settings > Privacy & Security.
     Scroll down to the Security section. You will see
     "Meeting Agent was blocked". Click "Open Anyway", type your Mac
     password, and click "Open Anyway" once more.

  Faster way: open the Terminal app, paste this line and press Return,
  then open Meeting Agent normally:

     xattr -dr com.apple.quarantine "/Applications/Meeting Agent.app"


STEP 3.  Follow the setup inside the app (about 3 minutes)
  - Allow Screen Recording, Microphone and Speech Recognition when
    macOS asks. The app tells you exactly what to click.
  - Connect the AI. The app walks you through it:
      * Google Gemini: free, takes about 2 minutes to get a key
      * Claude: pay as you go, best answers
${LOCALAI}


AFTER THAT
  - Find Meeting Agent in Launchpad or Spotlight (press Command + Space).
    It also lives in the menu bar at the top of your screen.
  - When you join a call (Meet, Teams, Zoom...) it offers to record.
  - Recordings, transcripts and summaries are saved in
    Movies > MeetingAgent. Audio and video never leave your Mac.
    Only text is sent to the AI you choose.
  - Always tell people on a call that you are recording.

TO REMOVE: drag Meeting Agent from Applications to the Bin.
TXT

  # 3. Make the disk image and check it.
  rm -f "$DMG"
  hdiutil create -volname "Meeting Agent" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
  hdiutil verify "$DMG" >/dev/null
  echo "Ready: $DMG  ($(du -h "$DMG" | cut -f1))"
}

SIGN=("$@")

make_dmg arm64 arm64 "Apple Silicon (M1, M2, M3, M4)" "      * This Mac: no key and no sign-up. Uses Apple Intelligence on this Mac."
make_dmg x86_64 intel "Intel" "      * This Mac: not available on Intel Macs. Use Gemini or Claude instead."

echo
echo "Both installers are in the dist folder:"
ls -lh dist/MeetingAgent-${VERSION}-*.dmg
echo
echo "Send the arm64 one to people with Apple Silicon Macs, and the intel one to people with Intel Macs."
