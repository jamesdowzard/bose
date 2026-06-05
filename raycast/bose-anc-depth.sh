#!/bin/bash
# Raycast script command — get/set Bose ANC depth (0=min … 10=max).
# Leave the argument blank to read the current depth.
# Requires the Bose to be connected to this Mac (it talks over RFCOMM on demand).
#
# @raycast.schemaVersion 1
# @raycast.title Bose: ANC Depth
# @raycast.mode inline
# @raycast.icon 🎧
# @raycast.packageName Bose
# @raycast.argument1 { "type": "text", "placeholder": "0-10 (blank = read)", "optional": true }

"$HOME/bin/bose-ctl" anc-depth "$1"
