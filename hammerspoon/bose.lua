-- Bose QC Ultra Controller
-- Hammerspoon module with floating webview panel for device switching
--
-- Keybinding: ⌥B (toggle panel)
-- Requires: bose-ctl binary at ~/bin/bose-ctl

local M = {}
local log = hs.logger.new("bose-ctl", "info")

-- Configuration
M.boseCtl = os.getenv("HOME") .. "/bin/bose-ctl"
M.hotkey = nil

-- Webview state
local webview = nil
local activeTask = nil
local autoHideTimer = nil

-- Switchable devices (mac excluded — always connected as control channel)
local switchableDevices = { "phone", "ipad", "iphone", "tv" }

-- Device display info
local deviceMeta = {
  phone  = { icon = "\xF0\x9F\x93\xB1", label = "Phone" },
  ipad   = { icon = "\xF0\x9F\x93\xB1", label = "iPad" },
  iphone = { icon = "\xF0\x9F\x93\xB1", label = "iPhone" },
  tv     = { icon = "\xF0\x9F\x93\xBA", label = "TV" },
}

-- =============================================================================
-- Status parsing
-- =============================================================================

local function parseStatus(output)
  local status = {
    active = nil,
    slots = { used = 0, total = 2 },
    paired = {},
  }

  for line in output:gmatch("[^\r\n]+") do
    local active = line:match("^Active:%s+(%S+)")
    if active then
      status.active = active
    end

    local used, total = line:match("^Slots:%s+(%d+)/(%d+)")
    if used then
      status.slots.used = tonumber(used)
      status.slots.total = tonumber(total)
    end

    local _, name = line:match("^%s+(%d+)%.%s+(%S+)")
    if name then
      table.insert(status.paired, name)
    end
  end

  return status
end

-- =============================================================================
-- HTML generation
-- =============================================================================

local function buildDeviceListJS()
  local parts = {}
  for _, dev in ipairs(switchableDevices) do
    table.insert(parts, '"' .. dev .. '"')
  end
  return "[" .. table.concat(parts, ",") .. "]"
end

local function buildHTML()
  local deviceListJS = buildDeviceListJS()

  -- Build device tile markup
  local tiles = {}
  for _, dev in ipairs(switchableDevices) do
    local meta = deviceMeta[dev]
    table.insert(tiles, string.format(
      '<div class="tile" id="tile-%s" onclick="onTileClick(\'%s\')">'
      .. '<div class="tile-status" id="status-%s"><span class="dot dot-dim"></span></div>'
      .. '<div class="tile-icon">%s</div>'
      .. '<div class="tile-label">%s</div>'
      .. '</div>',
      dev, dev, dev, meta.icon, meta.label
    ))
  end
  local tilesHTML = table.concat(tiles, "\n    ")

  return [[<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    background: #0c0c0c;
    color: #e0e0e0;
    font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif;
    overflow: hidden;
    user-select: none;
    -webkit-user-select: none;
    cursor: default;
  }
  .container {
    display: flex;
    align-items: center;
    justify-content: center;
    height: 100%;
    padding: 0 16px;
    gap: 10px;
  }
  .tile {
    display: flex;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    width: 116px;
    height: 68px;
    border-radius: 10px;
    background: #161616;
    border: 1px solid #2a2a2a;
    cursor: pointer;
    transition: background 0.15s, border-color 0.15s, opacity 0.15s;
    position: relative;
  }
  .tile:hover {
    background: #1e1e1e;
    border-color: #00ff88;
  }
  .tile.active {
    border-color: #00ff88;
    background: #0a1f12;
  }
  .tile.loading {
    opacity: 0.5;
    pointer-events: none;
  }
  .tile-icon {
    font-size: 20px;
    line-height: 1;
  }
  .tile-label {
    font-size: 11px;
    font-weight: 500;
    margin-top: 4px;
    letter-spacing: 0.3px;
    color: #aaa;
  }
  .tile.active .tile-label {
    color: #e0e0e0;
  }
  .tile-status {
    position: absolute;
    top: 7px;
    right: 9px;
  }
  .dot {
    display: inline-block;
    width: 6px;
    height: 6px;
    border-radius: 50%;
  }
  .dot-active {
    background: #00ff88;
    box-shadow: 0 0 6px #00ff8866;
  }
  .dot-dim {
    background: #333;
  }
  .connecting-label {
    position: absolute;
    bottom: 5px;
    font-size: 9px;
    color: #00ff88;
    letter-spacing: 0.2px;
    animation: pulse 1.2s ease-in-out infinite;
  }
  @keyframes pulse {
    0%, 100% { opacity: 0.3; }
    50% { opacity: 1; }
  }
  .overlay {
    position: absolute;
    inset: 0;
    display: flex;
    align-items: center;
    justify-content: center;
    background: #0c0c0c;
    z-index: 10;
    transition: opacity 0.3s;
  }
  .overlay.hidden {
    opacity: 0;
    pointer-events: none;
  }
  .overlay-text {
    font-size: 12px;
    color: #555;
    letter-spacing: 0.5px;
    animation: pulse 1.2s ease-in-out infinite;
  }
</style>
</head>
<body>
  <div class="overlay" id="overlay">
    <span class="overlay-text">querying headphones ...</span>
  </div>
  <div class="container">
    ]] .. tilesHTML .. [[

  </div>
<script>
  var DEVICES = ]] .. deviceListJS .. [[;
  var currentActive = null;
  var swapping = false;

  function updateTiles(activeDevice) {
    currentActive = activeDevice;
    DEVICES.forEach(function(dev) {
      var tile = document.getElementById("tile-" + dev);
      var dot  = document.getElementById("status-" + dev);
      if (!tile || !dot) return;

      tile.classList.remove("active", "loading");
      var cl = tile.querySelector(".connecting-label");
      if (cl) cl.remove();

      if (dev === activeDevice) {
        tile.classList.add("active");
        dot.innerHTML = '<span class="dot dot-active"></span>';
      } else {
        dot.innerHTML = '<span class="dot dot-dim"></span>';
      }
    });
  }

  function showConnecting(dev) {
    var tile = document.getElementById("tile-" + dev);
    if (!tile) return;
    tile.classList.add("loading");
    var lbl = document.createElement("span");
    lbl.className = "connecting-label";
    lbl.textContent = "connecting\u2026";
    tile.appendChild(lbl);
    swapping = true;
  }

  function onTileClick(dev) {
    if (swapping) return;
    showConnecting(dev);
    window.webkit.messageHandlers.bose.postMessage(JSON.stringify({
      action: "swap", device: dev
    }));
  }

  // Called from Lua after status query completes
  function onStatusLoaded(activeDevice) {
    document.getElementById("overlay").classList.add("hidden");
    updateTiles(activeDevice);
  }

  // Called from Lua after swap completes
  function onSwapComplete(activeDevice) {
    swapping = false;
    updateTiles(activeDevice);
  }

  // Called from Lua on error
  function onError(msg) {
    swapping = false;
    document.getElementById("overlay").classList.add("hidden");
    DEVICES.forEach(function(dev) {
      var tile = document.getElementById("tile-" + dev);
      if (!tile) return;
      tile.classList.remove("loading");
      var cl = tile.querySelector(".connecting-label");
      if (cl) cl.remove();
    });
  }

  document.addEventListener("keydown", function(e) {
    if (e.key === "Escape") {
      window.webkit.messageHandlers.bose.postMessage(JSON.stringify({
        action: "hide"
      }));
    }
  });
</script>
</body>
</html>]]
end

-- =============================================================================
-- Command execution (async via hs.task)
-- =============================================================================

local function runBoseCtl(args, callback)
  local task = hs.task.new(M.boseCtl, function(exitCode, stdout, stderr)
    if callback then
      callback(exitCode, stdout, stderr)
    end
  end, args)

  if not task then
    log.e("Failed to create task for bose-ctl")
    if callback then callback(-1, "", "Failed to create task") end
    return nil
  end

  task:start()
  return task
end

-- =============================================================================
-- Webview management
-- =============================================================================

local function cancelAutoHide()
  if autoHideTimer then
    autoHideTimer:stop()
    autoHideTimer = nil
  end
end

local function hidePanel()
  cancelAutoHide()
  if webview then
    webview:delete()
    webview = nil
  end
  if activeTask and activeTask:isRunning() then
    activeTask:terminate()
    activeTask = nil
  end
end

local function evalJS(js)
  if webview then
    webview:evaluateJavaScript(js, nil)
  end
end

local function autoHideAfter(seconds)
  cancelAutoHide()
  autoHideTimer = hs.timer.doAfter(seconds, function()
    hidePanel()
  end)
end

local function handleSwap(device)
  if activeTask and activeTask:isRunning() then
    log.w("Command already in progress, ignoring")
    return
  end

  log.i("Swapping to " .. device)
  activeTask = runBoseCtl({ "swap", device }, function(exitCode, stdout, stderr)
    activeTask = nil
    if exitCode == 0 then
      local swappedTo = stdout:match("Swapped to (%S+)")
      local connected = stdout:match("OK %— (%S+) connected")
      local newActive = swappedTo or connected or device

      log.i("Swap complete: " .. newActive)
      local safe = newActive:gsub("'", "\\'")
      evalJS("onSwapComplete('" .. safe .. "')")
      autoHideAfter(2)
    else
      local err = stdout:match("Error: (.+)") or stderr:match("Error: (.+)") or "unknown error"
      log.w("Swap failed: " .. err)
      evalJS("onError('" .. err:gsub("'", "\\'"):gsub("\n", " ") .. "')")
      hs.alert.show("Bose: " .. err, nil, nil, 2)
    end
  end)
end

local function showPanel()
  local screen = hs.screen.mainScreen()
  local frame = screen:frame()
  local w = 540
  local h = 90
  local x = frame.x + (frame.w - w) / 2
  local y = frame.y + frame.h * 0.30

  local rect = hs.geometry.rect(x, y, w, h)

  -- Usercontentcontroller for JS -> Lua messaging
  local ucc = hs.webview.usercontent.new("bose")
  ucc:setCallback(function(msg)
    local ok, data = pcall(hs.json.decode, msg.body)
    if not ok or not data then
      log.w("Invalid message from webview: " .. tostring(msg.body))
      return
    end

    if data.action == "swap" and data.device then
      handleSwap(data.device)
    elseif data.action == "hide" then
      hidePanel()
    end
  end)

  webview = hs.webview.new(rect, { developerExtrasEnabled = false }, ucc)
  webview:windowStyle({ "borderless", "nonactivating" })
  webview:level(hs.drawing.windowLevels.floating)
  webview:allowTextEntry(true)
  webview:closeOnEscape(false) -- handled in JS
  webview:transparent(false)
  webview:alpha(0.97)
  webview:shadow(true)

  -- Hide panel when focus is lost (click outside)
  webview:windowCallback(function(action, _, ...)
    if action == "focusChange" then
      local args = { ... }
      if not args[1] then
        -- Lost focus — hide after a tiny delay to avoid race with tile click
        hs.timer.doAfter(0.05, function()
          if webview then hidePanel() end
        end)
      end
    end
  end)

  webview:html(buildHTML())
  webview:show()
  webview:hswindow():focus()

  -- Query status asynchronously
  activeTask = runBoseCtl({ "status" }, function(exitCode, stdout, stderr)
    activeTask = nil
    if exitCode == 0 then
      local status = parseStatus(stdout)
      local active = status.active or "none"
      if active == "mac" then
        evalJS("onStatusLoaded(null)")
      else
        evalJS("onStatusLoaded('" .. active:gsub("'", "\\'") .. "')")
      end
    else
      log.w("Status query failed: " .. (stderr or ""))
      evalJS("onError('headphones not connected')")
      hs.alert.show("Bose: headphones not connected", nil, nil, 2)
    end
  end)
end

-- =============================================================================
-- Public API
-- =============================================================================

function M.toggle()
  if webview then
    hidePanel()
  else
    showPanel()
  end
end

function M.start()
  M.hotkey = hs.hotkey.bind({ "alt" }, "b", function()
    M.toggle()
  end)
  log.i("Bose controller started (\xe2\x8c\xa5B)")
end

function M.stop()
  hidePanel()
  if M.hotkey then
    M.hotkey:delete()
    M.hotkey = nil
  end
  log.i("Bose controller stopped")
end

return M
