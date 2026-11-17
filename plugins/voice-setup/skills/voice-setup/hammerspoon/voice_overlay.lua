-- VoiceMode overlay: which Claude Code sessions are using voice, stacked.
-- Tails ~/.voicemode/logs/events/*.jsonl (every voice-mode MCP process writes
-- there). The conch (mic lock) is held by one pid at a time; events without a
-- pid belong to the current holder. Other sessions show as small rows:
--   waiting  - queued for the mic (CONCH_WAIT_START / CONCH_BLOCKED)
--   working  - EVERY live Claude Code session that is busy (voice or not),
--              from ~/.voicemode/bin/claude-activity, refreshed every 5 s
-- pid -> session name + voice via ~/.voicemode/bin/voice-identity.

local M = {}

local HOME = os.getenv("HOME")
local EVENTS_DIR = HOME .. "/.voicemode/logs/events/"
local IDENTITY = HOME .. "/.voicemode/bin/voice-identity"
local ACTIVITY = HOME .. "/.voicemode/bin/claude-activity"
local MAX_ROWS = 6
local DONE_LINGER = 3          -- s the main pill stays after a turn ends
local BLOCKED_TTL = 20         -- s a "busy, will retry" row stays

local offsets = {}   -- log path -> bytes read
local identity = {}  -- pid -> {label, voice}
local holder = nil   -- pid holding the mic
local holderState = nil
local doneAt = nil   -- when holder's turn ended (for linger)
local lastDone = nil -- pid of the session whose turn just ended
local others = {}    -- voice pid -> {state="waiting", since=, ttl=}
local busy = {}      -- list of {cpid=, label=, voice=} from claude-activity
local render
local canvas = nil

local STATES = {
  speaking     = { icon = "🔊", text = "speaking…",          color = { red = 0.20, green = 0.55, blue = 0.95 } },
  listening    = { icon = "🎙", text = "listening…",         color = { red = 0.90, green = 0.30, blue = 0.30 } },
  transcribing = { icon = "✍️", text = "transcribing…",      color = { red = 0.85, green = 0.60, blue = 0.15 } },
  done         = { icon = "✓",  text = "done",               color = { red = 0.30, green = 0.65, blue = 0.40 } },
  waiting      = { icon = "⏳", text = "waiting",    color = { red = 0.60, green = 0.60, blue = 0.60 } },
  away         = { icon = "💤", text = "",                 color = { red = 0.45, green = 0.45, blue = 0.55 } },
  dictating    = { icon = "🎙", text = "",                 color = { red = 0.85, green = 0.35, blue = 0.55 } },
  dnd          = { icon = "🌙", text = "",                 color = { red = 0.35, green = 0.35, blue = 0.65 } },
  working      = { icon = "⚙️", text = "working…", color = { red = 0.55, green = 0.45, blue = 0.85 } },
}

local function prettyVoice(v)
  if not v or v == "" then return nil end
  local name = v:match("^%a%a_(.+)$") or v
  return name:sub(1, 1):upper() .. name:sub(2)
end

local function shorten(s, n)
  if utf8.len(s) and utf8.len(s) > n then return s:sub(1, utf8.offset(s, n) - 1) .. "…" end
  return s
end

local function lookup(pid)
  if not pid then return { label = "Claude", voice = nil } end
  if identity[pid] then return identity[pid] end
  local out = hs.execute(string.format("%q %d", IDENTITY, pid)) or ""
  local label, voice, cpid = out:match("^([^\t]*)\t([^\t\n]*)\t?([^\n]*)")
  label = (label and label ~= "") and label or "Claude"
  local id = { label = label, voice = prettyVoice(voice), cpid = tonumber(cpid) }
  identity[pid] = id
  return id
end

-- Busy sessions, fetched asynchronously so the overlay never blocks.
local activityTask = nil
local function refreshActivity()
  if activityTask and activityTask:isRunning() then return end
  activityTask = hs.task.new(ACTIVITY, function(code, out)
    if code ~= 0 then return end
    local list = {}
    for line in (out or ""):gmatch("[^\n]+") do
      local cp, clive = line:match("^CONCH\t(%d+)\t(%d)")
      if cp then
        -- mic lock freed without a release event (turn interrupted, process
        -- died, or lock went stale): drop the pill like VoiceMode drops the lock
        if holder and (tonumber(cp) ~= holder or clive == "0") then
          holder, holderState = nil, nil
          if M.onSpeakEnd then pcall(M.onSpeakEnd) end -- restore normal volume / unmute
        elseif not holder and clive == "0" and M.onSpeakEnd then
          pcall(M.onSpeakEnd) -- no-op unless a turn was cut off mid-speech
        end
      else
        local cpid, label, voice = line:match("^(%d+)\t([^\t]*)\t?(.*)$")
        if cpid then list[#list + 1] = { cpid = tonumber(cpid), label = label, voice = prettyVoice(voice) } end
      end
    end
    table.sort(list, function(a, b) return a.label < b.label end)
    busy = list
    render()
  end)
  activityTask:start()
end

local function title(pid, n)
  local id = lookup(pid)
  local t = shorten(id.label, n)
  if id.voice then t = t .. "  ·  " .. id.voice end
  return t
end

---------------------------------------------------------------- rendering
local W, MAIN_H, ROW_H, GAP, MARGIN = 360, 64, 30, 6, 24

-- placement (persisted): drag the overlay anywhere, ⌃⌥O cycles corners, ⌃⌥H hides it
local KEY_ANCHOR, KEY_CORNER, KEY_HIDDEN = "voiceOverlay.anchor", "voiceOverlay.corner", "voiceOverlay.hidden"
local CORNERS = { "br", "bl", "tl", "tr" }
local CORNER_NAMES = { br = "bottom right", bl = "bottom left", tl = "top left", tr = "top right" }
local dragging = false
local ROW_ALPHA, MAIN_ALPHA, HOVER_ALPHA = 0.80, 0.88, 0.98   -- background opacity; solid while hovered
local hovered = false

-- make the backgrounds (elements named "bg") solid while the mouse is over the overlay
local function setHover(c, on)
  hovered = on
  for i = 1, #c do
    local e = c[i]
    if e.id == "bg" then
      local rest = (e.frame.h or 0) > 40 and MAIN_ALPHA or ROW_ALPHA
      e.fillColor = { white = 0.08, alpha = on and HOVER_ALPHA or rest }
    end
  end
end

-- where the stack goes for height h. A dragged position is stored as its left x and
-- bottom y (the stack grows upward from the main pill), kept on-screen.
local function placement(h)
  local a = hs.settings.get(KEY_ANCHOR)
  if type(a) == "table" and a.x and a.bottom then
    local pt = hs.geometry.point(a.x + 10, a.bottom - 10)
    for _, scr in ipairs(hs.screen.allScreens()) do
      local f = scr:frame()
      if pt:inside(f) then
        local x = math.max(f.x, math.min(a.x, f.x + f.w - W))
        local y = math.max(f.y, math.min(a.bottom - h, f.y + f.h - h))
        return { x = x, y = y, w = W, h = h }
      end
    end
  end
  local c = hs.settings.get(KEY_CORNER) or "br"
  local f = hs.screen.mainScreen():frame()
  local x = c:sub(2, 2) == "r" and (f.x + f.w - W - MARGIN) or (f.x + MARGIN)
  local y = c:sub(1, 1) == "b" and (f.y + f.h - h - MARGIN) or (f.y + MARGIN)
  return { x = x, y = y, w = W, h = h }
end

local function startDrag(c)
  -- follow the mouse while the left button is held. Polling, not an eventtap,
  -- so it works without granting Hammerspoon Accessibility access.
  local start = hs.mouse.absolutePosition()
  local tl = c:topLeft()
  local h = c:frame().h
  dragging = true
  local timer
  timer = hs.timer.doEvery(1 / 60, function()
    local p = hs.mouse.absolutePosition()
    local x, y = tl.x + p.x - start.x, tl.y + p.y - start.y
    if hs.eventtap.checkMouseButtons()["left"] then
      c:topLeft({ x = x, y = y })
    else
      timer:stop()
      dragging = false
      if math.abs(p.x - start.x) + math.abs(p.y - start.y) > 3 then
        hs.settings.set(KEY_ANCHOR, { x = x, bottom = y + h })
      end
      if render then render() end
    end
  end)
end

render = function()
  local now = hs.timer.secondsSinceEpoch()
  for pid, o in pairs(others) do -- expire stale "waiting" rows
    if now - o.since > o.ttl then others[pid] = nil end
  end
  local mainPid, mainState = holder, holderState
  if not mainPid and lastDone and doneAt and now - doneAt < DONE_LINGER then
    mainPid, mainState = lastDone, "done"
  end
  local rows, shown = {}, {}
  if M.mic and M.mic.active() then
    rows[#rows + 1] = { state = "dictating", text = "You're dictating  ·  Claude's voice paused" }
  end
  local p = M.presence
  if p and p.status() ~= "present" then
    local n = p.pending()
    rows[#rows + 1] = { state = p.status(),
      text = (p.status() == "dnd" and "Do not disturb" or "Away") ..
             (n > 0 and string.format("  ·  %d waiting", n) or "  ·  nothing waiting") }
  end
  if mainPid and lookup(mainPid).cpid then shown[lookup(mainPid).cpid] = true end
  local waiting = {}
  for pid, o in pairs(others) do
    if pid ~= mainPid then waiting[#waiting + 1] = { pid = pid, since = o.since } end
  end
  table.sort(waiting, function(a, b) return a.since < b.since end)
  for _, w in ipairs(waiting) do
    rows[#rows + 1] = { state = "waiting", text = title(w.pid, 20) }
    local c = lookup(w.pid).cpid
    if c then shown[c] = true end
  end
  for _, b in ipairs(busy) do
    if not shown[b.cpid] then
      local t = shorten(b.label, 20)
      if b.voice then t = t .. "  ·  " .. b.voice end
      rows[#rows + 1] = { state = "working", text = t }
    end
  end
  if #rows > MAX_ROWS then
    local extra = #rows - (MAX_ROWS - 1)
    for i = #rows, MAX_ROWS, -1 do rows[i] = nil end
    rows[#rows + 1] = { state = "working", text = string.format("+%d more busy", extra) }
  end

  if dragging then return end
  if (not mainPid and #rows == 0) or hs.settings.get(KEY_HIDDEN) then
    if canvas then canvas:hide(0.5) end
    return
  end

  local h = (mainPid and MAIN_H or 0) + #rows * (ROW_H + GAP)
  local frame = placement(h)
  if canvas then canvas:delete() end
  canvas = hs.canvas.new(frame)
  canvas:canvasMouseEvents(true, false, false, false)   -- grab it to move it (see "grab" layer)
  canvas:mouseCallback(function(c, msg)
    if msg == "mouseDown" then startDrag(c)
    elseif msg == "mouseEnter" then setHover(c, true)
    elseif msg == "mouseExit" then setHover(c, false) end
  end)
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior({ "canJoinAllSpaces", "stationary" })
  canvas:clickActivating(false)

  local y = 0
  for _, r in ipairs(rows) do -- small rows on top, main pill at the bottom
    local st = STATES[r.state]
    canvas:appendElements(
      { type = "rectangle", action = "fill", frame = { x = 40, y = y, w = W - 40, h = ROW_H },
        roundedRectRadii = { xRadius = 9, yRadius = 9 }, fillColor = { white = 0.08, alpha = ROW_ALPHA }, id = "bg" },
      { type = "rectangle", action = "fill", frame = { x = 40, y = y, w = 4, h = ROW_H }, fillColor = st.color },
      { type = "text", frame = { x = 52, y = y + 6, w = W - 60, h = 20 }, textSize = 12,
        textColor = { white = 0.85 }, text = st.icon .. "  " .. r.text .. (st.text ~= "" and ("   — " .. st.text) or "") })
    y = y + ROW_H + GAP
  end
  if mainPid then
    local st = STATES[mainState]
    canvas:appendElements(
      { type = "rectangle", action = "fill", frame = { x = 0, y = y, w = W, h = MAIN_H },
        roundedRectRadii = { xRadius = 14, yRadius = 14 }, fillColor = { white = 0.08, alpha = MAIN_ALPHA }, id = "bg" },
      { type = "rectangle", action = "fill", frame = { x = 0, y = y, w = 6, h = MAIN_H }, fillColor = st.color },
      { type = "text", frame = { x = 18, y = y + 9, w = W - 26, h = 26 }, textSize = 17,
        textColor = { white = 1 }, text = st.icon .. "  " .. title(mainPid, 26) },
      { type = "text", frame = { x = 18, y = y + 35, w = W - 26, h = 22 }, textSize = 13,
        textColor = { white = 0.75 },
        text = st.text .. (hs.fs.attributes(HOME .. "/.voicemode/dnd") and "   ·   🌙 muted (DND)" or "") })
  end
  -- invisible layer on top that catches the mouse (only elements that track clicks get them)
  canvas:appendElements({ id = "grab", type = "rectangle", action = "fill",
    frame = { x = 0, y = 0, w = W, h = h }, fillColor = { white = 0, alpha = 0.01 },
    trackMouseDown = true, trackMouseEnterExit = true })
  -- redrawn while the mouse is already over it: no enter event comes, so check directly
  if hs.geometry.point(hs.mouse.absolutePosition()):inside(hs.geometry.rect(frame)) then
    setHover(canvas, true)
  else
    hovered = false
  end
  canvas:show(0.1)
end

---------------------------------------------------------------- events
local replaying = false   -- rebuilding state from the log at startup: no side effects

-- the session holding VoiceMode's mic lock, read from the lock file
local function conchPid()
  local ok, d = pcall(hs.json.read, HOME .. "/.voicemode/conch")
  return ok and type(d) == "table" and tonumber(d.pid) or nil
end

local function handle(ev)
  local t, data = ev.event_type, ev.data or {}
  local now = hs.timer.secondsSinceEpoch()

  if not replaying then
    if M.onSpeakStart and t == "TTS_PLAYBACK_START" then pcall(M.onSpeakStart) end
    if M.onSpeakEnd and (t == "TTS_PLAYBACK_END" or t == "SESSION_END" or t == "CONCH_RELEASE") then
      pcall(M.onSpeakEnd)
    end
  end
  -- a turn already in progress when we started: find its owner from the lock file
  if not holder and not replaying and (t == "TTS_START" or t == "TTS_PLAYBACK_START" or t == "RECORDING_START"
      or t == "RECORDING_END" or t == "STT_START") then
    holder = conchPid()
  end

  if t == "CONCH_ACQUIRE" and data.pid then
    holder, holderState, doneAt = data.pid, "speaking", nil
    others[data.pid] = nil
  elseif t == "CONCH_WAIT_START" and data.pid then
    others[data.pid] = { state = "waiting", since = now, ttl = (data.timeout or 60) + 5 }
  elseif t == "CONCH_BLOCKED" and data.pid then
    if not others[data.pid] then others[data.pid] = { state = "waiting", since = now, ttl = BLOCKED_TTL } end
  elseif t == "CONCH_WAIT_END" and data.pid then
    if data.result ~= "acquired" then others[data.pid] = nil end
  elseif holder and (t == "TTS_START" or t == "TTS_PLAYBACK_START") then
    holderState = "speaking"
  elseif holder and t == "RECORDING_START" then
    holderState = "listening"
  elseif holder and (t == "RECORDING_END" or t == "STT_START") then
    holderState = "transcribing"
  elseif holder and t == "STT_COMPLETE" then
    if M.presence and not (data.text or ""):match("^%s*$") then M.presence.userSpoke() end
    refreshActivity() -- you answered: that session turns busy shortly
  elseif t == "CONCH_RELEASE" then
    local pid = data.pid or holder
    if pid == holder then
      lastDone, doneAt, holder, holderState = pid, now, nil, nil
      hs.timer.doAfter(DONE_LINGER + 0.1, render)
    end
  else
    return
  end
  render()
end

local function readNew(path)
  if not path:match("%.jsonl$") then return end
  local fh = io.open(path, "r")
  if not fh then return end
  local size = fh:seek("end")
  local from = offsets[path] or 0
  if size < from then from = 0 end
  fh:seek("set", from)
  local chunk = fh:read("a") or ""
  fh:close()
  local lastNl = chunk:match(".*()\n")
  if not lastNl then return end
  offsets[path] = from + lastNl
  for line in chunk:sub(1, lastNl):gmatch("[^\n]+") do
    local ok, ev = pcall(hs.json.decode, line)
    if ok and type(ev) == "table" then
      local ok2, err = pcall(handle, ev)
      if not ok2 then print("voice_overlay: " .. tostring(err)) end
    end
  end
end

function M.refresh() refreshActivity() end
function M.holderState() return holder and holderState or nil end

function M.start()
  -- rebuild "who holds the mic and what are they doing" from the recent log,
  -- so a reload mid-turn doesn't lose track (no volume/mute side effects)
  local newest, newestT = nil, 0
  for file in hs.fs.dir(EVENTS_DIR) do
    if file:match("%.jsonl$") then
      local p = EVENTS_DIR .. file
      local size = hs.fs.attributes(p, "size") or 0
      offsets[p] = size
      local m = hs.fs.attributes(p, "modification") or 0
      if m > newestT then newest, newestT = p, m end
    end
  end
  if newest then
    local size = offsets[newest]
    offsets[newest] = math.max(0, size - 30000)
    replaying = true
    pcall(readNew, newest)
    replaying = false
    local live = conchPid()
    if holder and (not live or live ~= holder) then holder, holderState = nil, nil end
    lastDone, doneAt = nil, nil
    for pid, o in pairs(others) do others[pid] = nil end
  end
  M.watcher = hs.pathwatcher.new(EVENTS_DIR, function(paths)
    for _, p in ipairs(paths) do readNew(p) end
  end):start()
  M.poll = hs.timer.doEvery(1, function()
    for file in hs.fs.dir(EVENTS_DIR) do
      if file:match("%.jsonl$") then readNew(EVENTS_DIR .. file) end
    end
  end)
  M.expire = hs.timer.doEvery(5, refreshActivity) -- busy sessions + stale rows
  refreshActivity()
  M.flush = hs.timer.doEvery(60, function() identity = {} end)

  M.cornerKey = hs.hotkey.bind({ "ctrl", "alt" }, "o", function()
    local cur = hs.settings.get(KEY_CORNER) or "br"
    local nxt = "br"
    if hs.settings.get(KEY_ANCHOR) == nil then   -- after a drag, ⌃⌥O first snaps back to the current corner
      for i, c in ipairs(CORNERS) do if c == cur then nxt = CORNERS[i % #CORNERS + 1] end end
    else
      nxt = cur
    end
    hs.settings.clear(KEY_ANCHOR)
    hs.settings.set(KEY_CORNER, nxt)
    hs.alert.closeAll(0)
    hs.alert.show("🎙 Voice overlay: " .. CORNER_NAMES[nxt], 0.8)
    render()
  end)
  M.hideKey = hs.hotkey.bind({ "ctrl", "alt" }, "h", function()
    local hide = not hs.settings.get(KEY_HIDDEN)
    if hide then hs.settings.set(KEY_HIDDEN, true) else hs.settings.clear(KEY_HIDDEN) end
    hs.alert.closeAll(0)
    hs.alert.show(hide and "🙈 Voice overlay hidden  (⌃⌥H to show)" or "🎙 Voice overlay shown", 1)
    render()
  end)
end

function M.state()
  local parts = { "holder=" .. tostring(holder and lookup(holder).label) .. "/" .. tostring(holderState) }
  for pid, o in pairs(others) do parts[#parts + 1] = lookup(pid).label .. "=" .. o.state end
  for _, b in ipairs(busy) do parts[#parts + 1] = b.label .. "=busy" end
  parts[#parts + 1] = "visible=" .. tostring(canvas and canvas:isShowing())
  if canvas then local f = canvas:frame(); parts[#parts + 1] = string.format("at=%d,%d", f.x, f.y) end
  return table.concat(parts, " | ")
end

return M
