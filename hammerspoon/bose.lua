-- Bose QC Ultra Controller
-- Hammerspoon module using hs.chooser for device switching
--
-- Keybinding: ⌥B (toggle chooser)
-- Requires: bose-ctl binary at ~/bin/bose-ctl

local M = {}
local log = hs.logger.new("bose-ctl", "info")

-- Configuration
M.boseCtl = os.getenv("HOME") .. "/bin/bose-ctl"
M.hotkey = nil

local chooser = nil

-- Devices and display info
local devices = {
  { name = "mac",    icon = "\xF0\x9F\x92\xBB", label = "Mac" },
  { name = "phone",  icon = "\xF0\x9F\x93\xB1", label = "Phone" },
  { name = "ipad",   icon = "\xF0\x9F\x93\xB1", label = "iPad" },
  { name = "iphone", icon = "\xF0\x9F\x93\xB1", label = "iPhone" },
  { name = "tv",     icon = "\xF0\x9F\x93\xBA", label = "TV" },
}

-- =============================================================================
-- Status query and formatting
-- =============================================================================

local function getStatus()
  local output, status = hs.execute(M.boseCtl .. " status")
  if not status then return nil, nil end

  local active = nil
  local connected = {}
  for line in (output or ""):gmatch("[^\r\n]+") do
    local a = line:match("^Active:%s+(%S+)")
    if a then active = a end
    local cl = line:match("^Connected:%s+(.+)")
    if cl then
      for name in cl:gmatch("(%w+)") do
        connected[name] = true
      end
    end
  end
  return active, connected
end

local function buildChoices(active, connected)
  local choices = {}
  for _, dev in ipairs(devices) do
    local state = ""
    if dev.name == active then
      state = " — active"
    elseif connected and connected[dev.name] then
      state = " — connected"
    end
    table.insert(choices, {
      text = dev.icon .. "  " .. dev.label .. state,
      subText = dev.name == active and "Currently playing" or "Tap to switch",
      name = dev.name,
    })
  end
  return choices
end

-- =============================================================================
-- Chooser
-- =============================================================================

local function onChoice(choice)
  if not choice then return end
  local device = choice.name
  log.i("Swapping to " .. device)
  hs.alert.show("Switching to " .. device .. "...", nil, nil, 2)

  -- Run swap in background, show result
  local outFile = "/tmp/bose-swap-out.txt"
  local doneFile = "/tmp/bose-swap-done.txt"
  os.remove(outFile)
  os.remove(doneFile)

  local cmd = M.boseCtl .. " swap " .. device .. " > " .. outFile .. " 2>&1; echo $? >> " .. outFile .. "; touch " .. doneFile
  hs.task.new("/bin/sh", function() end, {"-c", cmd}):start()

  hs.timer.doEvery(0.3, function(timer)
    local f = io.open(doneFile, "r")
    if f then
      f:close()
      os.remove(doneFile)
      local of = io.open(outFile, "r")
      local content = of and of:read("*a") or ""
      if of then of:close() end
      os.remove(outFile)
      -- Last line is exit code
      local lines = {}
      for line in content:gmatch("[^\n]+") do table.insert(lines, line) end
      local exitCode = tonumber(lines[#lines]) or 1
      table.remove(lines)
      local output = table.concat(lines, "\n")
      timer:stop()
      if exitCode == 0 then
        hs.alert.show("Switched to " .. device, nil, nil, 2)
      else
        local err = output:match("Error: (.+)") or "failed"
        hs.alert.show("Bose: " .. err, nil, nil, 3)
      end
    end
  end)
end

local function showChooser()
  if chooser then
    chooser:delete()
    chooser = nil
  end

  chooser = hs.chooser.new(onChoice)
  chooser:placeholderText("Switch audio source")
  -- Show all devices immediately (no status yet — update when ready)
  chooser:choices(buildChoices(nil, nil))
  chooser:show()

  -- Query status in background, update choices when ready
  local outFile = "/tmp/bose-status-out.txt"
  local doneFile = "/tmp/bose-status-done.txt"
  os.remove(outFile)
  os.remove(doneFile)

  local cmd = M.boseCtl .. " status > " .. outFile .. " 2>&1; echo $? >> " .. outFile .. "; touch " .. doneFile
  hs.task.new("/bin/sh", function() end, {"-c", cmd}):start()

  hs.timer.doEvery(0.3, function(timer)
    local f = io.open(doneFile, "r")
    if f then
      f:close()
      os.remove(doneFile)
      local of = io.open(outFile, "r")
      local content = of and of:read("*a") or ""
      if of then of:close() end
      os.remove(outFile)
      timer:stop()

      -- Parse status
      local active = nil
      local connected = {}
      for line in content:gmatch("[^\r\n]+") do
        local a = line:match("^Active:%s+(%S+)")
        if a then active = a end
        local cl = line:match("^Connected:%s+(.+)")
        if cl then
          for name in cl:gmatch("(%w+)") do connected[name] = true end
        end
      end

      if chooser then
        chooser:placeholderText("Switch audio source")
        chooser:choices(buildChoices(active, connected))
      end
    end
  end)
end

-- =============================================================================
-- Public API
-- =============================================================================

function M.toggle()
  if chooser and chooser:isVisible() then
    chooser:hide()
  else
    showChooser()
  end
end

function M.start()
  M.hotkey = hs.hotkey.bind({ "alt" }, "b", function()
    M.toggle()
  end)
  log.i("Bose controller started (\xe2\x8c\xa5B)")
end

function M.stop()
  if chooser then
    chooser:delete()
    chooser = nil
  end
  if M.hotkey then
    M.hotkey:delete()
    M.hotkey = nil
  end
  log.i("Bose controller stopped")
end

return M
