#!/bin/bash
# Raycast script command — get/set auto-pause (pause when the headphones are
# removed, BMAP 01,18). Leave the argument blank to read the current state.
# Requires the Bose to be connected to this Mac (it talks over RFCOMM on demand).
#
# @raycast.schemaVersion 1
# @raycast.title Bose: Auto-Pause
# @raycast.mode inline
# @raycast.icon 🎧
# @raycast.packageName Bose
# @raycast.argument1 { "type": "text", "placeholder": "on/off (blank=read)", "optional": true }

"$HOME/bin/bose" auto-pause "$1"
