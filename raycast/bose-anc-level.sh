#!/bin/bash
# Raycast script command — get/set the active mode's Bose noise level (0 = max
# cancellation … 10 = full transparency). Leave the argument blank to read it.
# Only works on an adjustable custom mode (Quiet/Aware/spatial modes are fixed).
# Requires the Bose to be connected to this Mac (it talks over RFCOMM on demand).
#
# @raycast.schemaVersion 1
# @raycast.title Bose: Noise Level
# @raycast.mode inline
# @raycast.icon 🎧
# @raycast.packageName Bose
# @raycast.argument1 { "type": "text", "placeholder": "0-10 (0=max cancel, blank=read)", "optional": true }

"$HOME/bin/bose-ctl" anc-level "$1"
