#!/bin/bash
# Raycast script command — get/set the active mode's Bose Immersive Audio (spatial)
# mode: off / still / motion. Leave the argument blank to read the current value.
# Only works on an adjustable custom mode (Quiet/Aware/Immersion/Cinema are fixed —
# Immersion carries Motion, Cinema carries Still). Requires the Bose to be connected
# to this Mac (it talks over RFCOMM on demand).
#
# @raycast.schemaVersion 1
# @raycast.title Bose: Immersive Audio
# @raycast.mode inline
# @raycast.icon 🎧
# @raycast.packageName Bose
# @raycast.argument1 { "type": "dropdown", "placeholder": "mode", "optional": true, "data": [{ "title": "Read current", "value": "" }, { "title": "Off", "value": "off" }, { "title": "Still", "value": "still" }, { "title": "Motion", "value": "motion" }] }

# Pass the mode only when one was chosen — a blank/"Read current" arg must omit it
# entirely (a literal "" makes `bose spatial` reject it instead of reading).
"$HOME/bin/bose" spatial ${1:+"$1"}
