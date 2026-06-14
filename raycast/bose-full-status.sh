#!/bin/bash
# Raycast script command — full Bose QC Ultra state (identity, power, all audio
# config, multipoint, codec, and the audio-active device list).
# Requires the Bose to be connected to this Mac (it talks over RFCOMM on demand).
#
# @raycast.schemaVersion 1
# @raycast.title Bose: Full Status
# @raycast.mode fullOutput
# @raycast.icon 🎧
# @raycast.packageName Bose

"$HOME/bin/bose" info
