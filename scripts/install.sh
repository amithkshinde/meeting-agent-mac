#!/bin/bash
# Builds the app and installs it into Applications, then opens it.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh "$@"

APP="MeetingAgent.app"
DEST="/Applications"
[ -w "$DEST" ] || DEST="$HOME/Applications"
mkdir -p "$DEST"

# Ask a running copy to quit politely, so an open recording is saved properly.
if pgrep -x MeetingAgent >/dev/null 2>&1; then
  echo "Closing the running Meeting Agent..."
  osascript -e 'tell application "MeetingAgent" to quit' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    pgrep -x MeetingAgent >/dev/null 2>&1 || break
    sleep 1
  done
  pkill -x MeetingAgent >/dev/null 2>&1 || true
fi

rm -rf "$DEST/$APP"
ditto "build/$APP" "$DEST/$APP"
echo "Installed: $DEST/$APP"
open "$DEST/$APP"
