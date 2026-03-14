-- Bose QC Ultra Controller
-- Hammerspoon module for quick device switching via popup chooser
--
-- Keybinding: Ctrl+Alt+B (alt+b taken by Bowser)
-- Requires: bose-ctl binary at ~/bin/bose-ctl

local M = {}
local log = hs.logger.new("bose-ctl", "info")

-- Configuration
M.boseCtl = os.getenv("HOME") .. "/bin/bose-ctl"
M.hotkey = nil
M.chooser = nil

-- Known devices (must match BoseCtl.swift knownDevices)
local devices = { "mac", "phone", "ipad", "iphone" }

-- Icons for display
local icons = {
  mac = "💻",
  phone = "📱",
  ipad = "📱",
  iphone = "📱",
}

-- State from last status query
local lastStatus = nil

-- =============================================================================
-- Status parsing
-- =============================================================================

-- Parse bose-ctl status output into structured data
-- Example output:
--   Active:   mac (BC:D0:74:11:DB:27)
--   Slots:    1/2 connected
--   Paired:   4 devices
--     1. mac (BC:D0:74:11:DB:27)
--     2. ipad (F4:81:C4:B5:FA:AB)
--     ...
local function parseStatus(output)
  local status = {
    active = nil,
    slots = { used = 0, total = 2 },
    paired = {},
  }

  for line in output:gmatch("[^\r\n]+") do
    -- Active device
    local active = line:match("^Active:%s+(%S+)")
    if active then
      status.active = active
    end

    -- Slot count
    local used, total = line:match("^Slots:%s+(%d+)/(%d+)")
    if used then
      status.slots.used = tonumber(used)
      status.slots.total = tonumber(total)
    end

    -- Paired device list entries
    local idx, name = line:match("^%s+(%d+)%.%s+(%S+)")
    if idx and name then
      table.insert(status.paired, name)
    end
  end

  return status
end

-- Check if a device is connected by checking if it appears in paired list
-- and comparing with active device
local function isConnected(deviceName, status)
  if not status then return false end
  -- If the device is the active device, it's connected
  if status.active == deviceName then return true end
  -- We can't distinguish "paired but disconnected" from "paired and connected
  -- in second slot" without more protocol info, so we just show active status
  return false
end

-- =============================================================================
-- Chooser items
-- =============================================================================

local function buildChooserItems(status)
  local items = {}

  if not status then
    table.insert(items, {
      text = "Headphones not connected",
      subText = "Make sure Bose QC Ultra are connected to Mac",
      action = "none",
    })
    return items
  end

  -- Header: current state
  local activeText = status.active and (status.active) or "none"
  table.insert(items, {
    text = "Active: " .. activeText,
    subText = status.slots.used .. "/" .. status.slots.total .. " slots in use",
    action = "none",
  })

  -- Swap options for non-mac devices
  for _, dev in ipairs(devices) do
    if dev ~= "mac" then
      local icon = icons[dev] or "🎧"
      local isActive = (status.active == dev)

      if isActive then
        table.insert(items, {
          text = icon .. "  " .. dev .. "  —  active",
          subText = "Select to disconnect",
          action = "disconnect",
          device = dev,
        })
      else
        table.insert(items, {
          text = icon .. "  Swap to " .. dev,
          subText = "Disconnect other devices and connect " .. dev,
          action = "swap",
          device = dev,
        })
      end
    end
  end

  -- Show status refresh option
  table.insert(items, {
    text = "🔄  Refresh status",
    subText = "Query headphones for current state",
    action = "refresh",
  })

  return items
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
    return
  end

  task:start()
  return task
end

-- =============================================================================
-- Actions
-- =============================================================================

local function showWorking(message)
  hs.alert.closeAll()
  hs.alert.show("🎧 " .. message, nil, nil, 10)
end

local function showResult(message)
  hs.alert.closeAll()
  hs.alert.show("🎧 " .. message, nil, nil, 2)
end

local function handleChoice(choice)
  if not choice then return end

  local action = choice.action
  local device = choice.device

  if action == "none" then
    return
  end

  if action == "refresh" then
    M.show()
    return
  end

  if action == "swap" then
    showWorking("Swapping to " .. device .. "...")
    runBoseCtl({ "swap", device }, function(exitCode, stdout, stderr)
      if exitCode == 0 and stdout:match("Swapped") then
        showResult("Swapped to " .. device)
      elseif exitCode == 0 and stdout:match("OK") then
        showResult("Connected " .. device)
      else
        local err = stdout:match("Error: (.+)") or stderr:match("Error: (.+)") or "unknown error"
        showResult("Failed: " .. err)
      end
    end)
    return
  end

  if action == "disconnect" then
    showWorking("Disconnecting " .. device .. "...")
    runBoseCtl({ "disconnect", device }, function(exitCode, stdout, stderr)
      if exitCode == 0 then
        showResult("Disconnected " .. device)
      else
        local err = stdout:match("Error: (.+)") or stderr:match("Error: (.+)") or "unknown error"
        showResult("Failed: " .. err)
      end
    end)
    return
  end

  if action == "connect" then
    showWorking("Connecting " .. device .. "...")
    runBoseCtl({ "connect", device }, function(exitCode, stdout, stderr)
      if exitCode == 0 and (stdout:match("OK") or stdout:match("connected")) then
        showResult("Connected " .. device)
      else
        local err = stdout:match("Error: (.+)") or stderr:match("Error: (.+)") or "unknown error"
        showResult("Failed: " .. err)
      end
    end)
    return
  end
end

-- =============================================================================
-- Public API
-- =============================================================================

-- Show the chooser popup, querying status first
function M.show()
  -- Show loading state immediately
  if M.chooser then
    M.chooser:delete()
  end

  M.chooser = hs.chooser.new(handleChoice)
  M.chooser:placeholderText("Bose QC Ultra")
  M.chooser:searchSubText(true)

  -- Show with loading indicator while we query status
  M.chooser:choices({
    { text = "Querying headphones...", subText = "Please wait", action = "none" },
  })
  M.chooser:show()

  -- Query status asynchronously
  runBoseCtl({ "status" }, function(exitCode, stdout, stderr)
    if exitCode == 0 then
      lastStatus = parseStatus(stdout)
    else
      lastStatus = nil
      log.w("bose-ctl status failed: " .. (stderr or ""))
    end

    -- Update chooser with real data (must run on main thread)
    local items = buildChooserItems(lastStatus)

    -- Check chooser is still visible before updating
    if M.chooser and M.chooser:isVisible() then
      M.chooser:choices(items)
    end
  end)
end

function M.start()
  M.hotkey = hs.hotkey.bind({ "alt" }, "b", function()
    M.show()
  end)
  log.i("Bose controller started (⌥B)")
end

function M.stop()
  if M.hotkey then
    M.hotkey:delete()
    M.hotkey = nil
  end
  if M.chooser then
    M.chooser:delete()
    M.chooser = nil
  end
  log.i("Bose controller stopped")
end

return M
