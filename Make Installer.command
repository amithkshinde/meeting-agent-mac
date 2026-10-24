#!/bin/bash
# Double-click this file to build an installer you can share (a single .dmg file).
cd "$(dirname "$0")"
echo "Building two installers, one for Apple Silicon Macs and one for Intel Macs. This takes about four to six minutes..."
echo
if scripts/make-installer.sh; then
  echo
  echo "Done. Opening the folder that holds your two installers."
  open dist
else
  echo
  echo "Something went wrong. Copy the red text above and report it at https://github.com/amithkshinde/meeting-agent-mac/issues"
fi
echo
read -n 1 -s -r -p "Press any key to close this window."
