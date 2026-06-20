#!/bin/bash
# Raycast script command — show which AudioModes slots are marked favourite
# (BMAP 1F,08). Display-only. Requires the Bose to be connected to this Mac
# (it talks over RFCOMM on demand).
#
# @raycast.schemaVersion 1
# @raycast.title Bose: Favourites
# @raycast.mode inline
# @raycast.icon 🎧
# @raycast.packageName Bose

"$HOME/bin/bose" favorites
