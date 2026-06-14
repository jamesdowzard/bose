#!/bin/bash
# Raycast script command — route the Bose QC Ultra to a device.
# Install: copy into your Raycast script-commands dir (~/.config/raycast/script-commands/).
#
# @raycast.schemaVersion 1
# @raycast.title Bose: Connect Device
# @raycast.mode compact
# @raycast.icon 🎧
# @raycast.packageName Bose
# @raycast.argument1 { "type": "dropdown", "placeholder": "Device", "data": [{"title":"Mac","value":"mac"},{"title":"Phone","value":"phone"},{"title":"iPad","value":"ipad"},{"title":"iPhone","value":"iphone"},{"title":"Quest","value":"quest"},{"title":"TV","value":"tv"},{"title":"Apple TV","value":"appletv"}] }

"$HOME/bin/bose" connect "$1"
