#!/bin/bash
# Double-click this file to build and install Meeting Agent.
cd "$(dirname "$0")"
echo "Building Meeting Agent. This takes a minute..."
echo
if scripts/install.sh; then
  echo
  echo "All done. Meeting Agent is in your Applications folder and running in the menu bar."
else
  echo
  echo "Something went wrong. Copy the red text above and report it at https://github.com/amithkshinde/meeting-agent-mac/issues"
fi
echo
read -n 1 -s -r -p "Press any key to close this window."
