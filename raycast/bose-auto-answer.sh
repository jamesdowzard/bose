#!/bin/bash
# Raycast script command — get/set auto-answer (answer an incoming call when the
# headphones are donned, BMAP 01,1B). Leave the argument blank to read the state.
# Requires the Bose to be connected to this Mac (it talks over RFCOMM on demand).
#
# @raycast.schemaVersion 1
# @raycast.title Bose: Auto-Answer
# @raycast.mode inline
# @raycast.icon 🎧
# @raycast.packageName Bose
# @raycast.argument1 { "type": "text", "placeholder": "on/off (blank=read)", "optional": true }

"$HOME/bin/bose" auto-answer "$1"
