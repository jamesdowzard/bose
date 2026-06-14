#!/bin/bash
# Raycast script command — apply a Bose settings profile (or list them if blank).
# Profiles live in profiles.json (see the repo README). Requires the Bose to be
# connected to this Mac (it talks over RFCOMM on demand).
#
# @raycast.schemaVersion 1
# @raycast.title Bose: Profile
# @raycast.mode fullOutput
# @raycast.icon 🎧
# @raycast.packageName Bose
# @raycast.argument1 { "type": "text", "placeholder": "profile name (blank = list)", "optional": true }

"$HOME/bin/bose" profile "$1"
