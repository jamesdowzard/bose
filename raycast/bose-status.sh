#!/bin/bash
# Raycast script command — show Bose QC Ultra status (battery, ANC, volume, EQ).
# Requires the Bose to be connected to this Mac (it talks over RFCOMM on demand).
#
# @raycast.schemaVersion 1
# @raycast.title Bose: Status
# @raycast.mode fullOutput
# @raycast.icon 🎧
# @raycast.packageName Bose

"$HOME/bin/bose-ctl" status
