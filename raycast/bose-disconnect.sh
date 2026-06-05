#!/bin/bash
# Raycast script command — disconnect a device from the Bose QC Ultra.
#
# @raycast.schemaVersion 1
# @raycast.title Bose: Disconnect Device
# @raycast.mode compact
# @raycast.icon 🎧
# @raycast.packageName Bose
# @raycast.argument1 { "type": "dropdown", "placeholder": "Device", "data": [{"title":"Mac","value":"mac"},{"title":"Phone","value":"phone"},{"title":"iPad","value":"ipad"},{"title":"iPhone","value":"iphone"},{"title":"Quest","value":"quest"},{"title":"TV","value":"tv"}] }

"$HOME/bin/bose-ctl" disconnect "$1"
