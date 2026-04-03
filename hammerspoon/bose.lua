-- Bose QC Ultra 2 Controller
-- ⌥B: Floating pill bar for device switching
-- 1-5 or click to switch, Escape to close
-- Requires: ~/bin/bose-ctl

local M = {}
local log = hs.logger.new("bose", "info")

M.boseCtl = os.getenv("HOME") .. "/bin/bose-ctl"
M.hotkey = nil

-- State
local pill = nil
local keyTap = nil
local clickTap = nil
local autoClose = nil
local busy = false

-- Devices
local devices = {
  { name = "mac",    label = "Mac"    },
  { name = "phone",  label = "Phone"  },
  { name = "ipad",   label = "iPad"   },
  { name = "iphone", label = "iPhone" },
  { name = "tv",     label = "TV"     },
}

-- Layout
local W, H = 420, 40
local R = 20

-- =============================================================================
-- Async bose-ctl
-- =============================================================================

local seq = 0

local function runBoseCtl(args, callback)
  seq = seq + 1
  local tag = tostring(seq)
  local outFile  = "/tmp/bose-r-" .. tag
  local doneFile = "/tmp/bose-d-" .. tag
  os.remove(outFile)
  os.remove(doneFile)

  local cmd = M.boseCtl .. " " .. table.concat(args, " ")
    .. " > " .. outFile .. " 2>&1; echo $? >> " .. outFile .. "; touch " .. doneFile
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
      local lines = {}
      for line in content:gmatch("[^\n]+") do table.insert(lines, line) end
      local rc = tonumber(lines[#lines]) or 1
      table.remove(lines)
      timer:stop()
      callback(rc, table.concat(lines, "\n") .. "\n")
    end
  end)
end

local function parseStatus(output)
  local active, battery, connected = nil, nil, {}
  for line in output:gmatch("[^\r\n]+") do
    local a = line:match("^Active:%s+(%S+)")
    if a then active = a end
    local b = line:match("^Battery:%s+(%d+)%%")
    if b then battery = tonumber(b) end
    local cl = line:match("^Connected:%s+(.+)")
    if cl then
      for name in cl:gmatch("(%w+)") do connected[name] = true end
    end
  end
  return active, battery, connected
end

-- =============================================================================
-- Pill rendering
-- =============================================================================

local function buildPill(active, battery, connected)
  local screen = hs.screen.mainScreen()
  local f = screen:frame()
  local x = f.x + (f.w - W) / 2
  local y = f.y + 60

  local c = hs.canvas.new({x = x, y = y, w = W, h = H})
  c:level(hs.canvas.windowLevels.screenSaver)
  c:behavior({"canJoinAllSpaces", "stationary"})

  -- Pill background
  c:appendElements({
    type = "rectangle",
    roundedRectRadii = {xRadius = R, yRadius = R},
    fillColor = {red = 0.1, green = 0.1, blue = 0.1, alpha = 0.95},
    strokeColor = {red = 0.25, green = 0.25, blue = 0.25, alpha = 0.4},
    strokeWidth = 0.5,
    frame = {x = 0, y = 0, w = W, h = H},
  })

  local tileW = W / #devices

  for i, dev in ipairs(devices) do
    local tx = (i - 1) * tileW
    local isActive = (dev.name == active)
    local isConn = connected and connected[dev.name]

    local color = {white = 0.25}
    if isActive then color = {white = 1} end
    if isConn and not isActive then color = {white = 0.55} end

    local display = dev.label
    if isActive then display = "▸ " .. dev.label end

    c:appendElements({
      type = "text",
      text = display,
      textFont = ".AppleSystemUIFont",
      textColor = color,
      textSize = 13,
      textAlignment = "center",
      frame = {x = tx, y = 11, w = tileW, h = 20},
    })
  end

  return c
end

-- =============================================================================
-- Input handling
-- =============================================================================

local function hidePill()
  if autoClose then autoClose:stop(); autoClose = nil end
  if pill then pill:delete(); pill = nil end
  if keyTap then keyTap:stop(); keyTap = nil end
  if clickTap then clickTap:stop(); clickTap = nil end
end

local function swapTo(device)
  if busy then return end
  busy = true
  hidePill()
  log.i("Swap → " .. device)

  runBoseCtl({"swap", device}, function(rc, output)
    busy = false
    if rc == 0 then
      hs.alert.show("▶ " .. device, nil, nil, 1.5)
    else
      local err = output:match("Error: (.+)") or "failed"
      hs.alert.show("✗ " .. err, nil, nil, 3)
    end
  end)
end

local function setupInput()
  keyTap = hs.eventtap.new({hs.eventtap.event.types.keyDown}, function(e)
    local code = e:getKeyCode()
    if code == 53 then hidePill(); return true end
    local numMap = {[18]=1, [19]=2, [20]=3, [21]=4, [23]=5}
    local idx = numMap[code]
    if idx and idx <= #devices then
      swapTo(devices[idx].name)
      return true
    end
    return false
  end)
  keyTap:start()

  clickTap = hs.eventtap.new({hs.eventtap.event.types.leftMouseDown}, function(e)
    if not pill then return false end
    local pos = e:location()
    local pf = pill:frame()
    if pos.x >= pf.x and pos.x <= pf.x + pf.w and pos.y >= pf.y and pos.y <= pf.y + pf.h then
      local relX = pos.x - pf.x
      local tileW = W / #devices
      local idx = math.floor(relX / tileW) + 1
      if idx >= 1 and idx <= #devices then
        swapTo(devices[idx].name)
      end
      return true
    else
      hidePill()
      return false
    end
  end)
  clickTap:start()
end

-- =============================================================================
-- Show
-- =============================================================================

local function showPill()
  local output, ok = hs.execute(M.boseCtl .. " status")
  local active, battery, connected = nil, nil, nil
  if ok then
    active, battery, connected = parseStatus(output or "")
  end

  pill = buildPill(active, battery, connected)
  pill:show()
  setupInput()

  autoClose = hs.timer.doAfter(8, hidePill)
end

-- =============================================================================
-- Public API
-- =============================================================================

function M.toggle()
  if pill then
    hidePill()
  else
    showPill()
  end
end

function M.start()
  M.hotkey = hs.hotkey.bind({"alt"}, "b", M.toggle)
  log.i("Bose controller started (⌥B)")
end

function M.stop()
  hidePill()
  if M.hotkey then M.hotkey:delete(); M.hotkey = nil end
end

return M
