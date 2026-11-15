-- VoiceMode overlay: which Claude Code sessions are using voice, stacked.
-- Tails ~/.voicemode/logs/events/*.jsonl (every voice-mode MCP process writes
-- there). The conch (mic lock) is held by one pid at a time; events without a
-- pid belong to the current holder. Other sessions show as small rows:
--   waiting  - queued for the mic (CONCH_WAIT_START / CONCH_BLOCKED)
--   working  - you answered, Claude is working and will speak again
-- pid -> session name + voice via ~/.voicemode/bin/voice-identity.

local M = {}

local HOME = os.getenv("HOME")
local EVENTS_DIR = HOME .. "/.voicemode/logs/events/"
local IDENTITY = HOME .. "/.voicemode/bin/voice-identity"
local DONE_LINGER = 3          -- s the main pill stays after a turn ends
local WORKING_TTL = 3 * 60     -- s max a "working" row stays, even if still busy
local BLOCKED_TTL = 20         -- s a "busy, will retry" row stays

local offsets = {}   -- log path -> bytes read
local identity = {}  -- pid -> {label, voice}
local holder = nil   -- pid holding the mic
local holderState = nil
local doneAt = nil   -- when holder's turn ended (for linger)
local lastDone = nil -- pid of the session whose turn just ended
local others = {}    -- pid -> {state=, since=, ttl=}
local canvas = nil

local STATES = {
  speaking     = { icon = "🔊", text = "speaking…",          color = { red = 0.20, green = 0.55, blue = 0.95 } },
  listening    = { icon = "🎙", text = "listening…",         color = { red = 0.90, green = 0.30, blue = 0.30 } },
  transcribing = { icon = "✍️", text = "transcribing…",      color = { red = 0.85, green = 0.60, blue = 0.15 } },
  done         = { icon = "✓",  text = "done",               color = { red = 0.30, green = 0.65, blue = 0.40 } },
  waiting      = { icon = "⏳", text = "waiting for mic",    color = { red = 0.60, green = 0.60, blue = 0.60 } },
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

-- Claude Code keeps ~/.claude/sessions/<pid>.json with status idle|busy|shell
local function sessionBusy(pid)
  local cpid = lookup(pid).cpid
  if not cpid then return false end
  local ok, d = pcall(hs.json.read, HOME .. "/.claude/sessions/" .. cpid .. ".json")
  -- only "busy" = actively working on your reply ("shell" = just waiting on background shells)
  return ok and type(d) == "table" and d.status == "busy"
end

local function title(pid, n)
  local id = lookup(pid)
  local t = shorten(id.label, n)
  if id.voice then t = t .. "  ·  " .. id.voice end
  return t
end

---------------------------------------------------------------- rendering
local W, MAIN_H, ROW_H, GAP, MARGIN = 360, 64, 30, 6, 24

local function render()
  local now = hs.timer.secondsSinceEpoch()
  -- expire stale rows
  for pid, o in pairs(others) do
    if now - o.since > o.ttl then others[pid] = nil
    elseif o.state == "working" and now - o.since > 5 and not sessionBusy(pid) then
      others[pid] = nil -- session finished its turn (e.g. replied in text)
    end
  end
  local mainPid, mainState = holder, holderState
  if not mainPid and lastDone and doneAt and now - doneAt < DONE_LINGER then
    mainPid, mainState = lastDone, "done"
  end
  local rows = {}
  for pid, o in pairs(others) do
    if pid ~= mainPid then rows[#rows + 1] = { pid = pid, state = o.state, since = o.since } end
  end
  table.sort(rows, function(a, b) return a.since < b.since end)

  if not mainPid and #rows == 0 then
    if canvas then canvas:hide(0.5) end
    return
  end

  local h = (mainPid and MAIN_H or 0) + #rows * (ROW_H + GAP)
  local f = hs.screen.mainScreen():frame()
  local frame = { x = f.x + f.w - W - MARGIN, y = f.y + f.h - h - MARGIN, w = W, h = h }
  if canvas then canvas:delete() end
  canvas = hs.canvas.new(frame)
  canvas:level(hs.canvas.windowLevels.overlay)
  canvas:behavior({ "canJoinAllSpaces", "stationary" })
  canvas:clickActivating(false)

  local y = 0
  for _, r in ipairs(rows) do -- small rows on top, main pill at the bottom
    local st = STATES[r.state]
    canvas:appendElements(
      { type = "rectangle", action = "fill", frame = { x = 40, y = y, w = W - 40, h = ROW_H },
        roundedRectRadii = { xRadius = 9, yRadius = 9 }, fillColor = { white = 0.08, alpha = 0.80 } },
      { type = "rectangle", action = "fill", frame = { x = 40, y = y, w = 4, h = ROW_H }, fillColor = st.color },
      { type = "text", frame = { x = 52, y = y + 6, w = W - 60, h = 20 }, textSize = 12,
        textColor = { white = 0.85 }, text = st.icon .. "  " .. title(r.pid, 20) .. "   — " .. st.text })
    y = y + ROW_H + GAP
  end
  if mainPid then
    local st = STATES[mainState]
    canvas:appendElements(
      { type = "rectangle", action = "fill", frame = { x = 0, y = y, w = W, h = MAIN_H },
        roundedRectRadii = { xRadius = 14, yRadius = 14 }, fillColor = { white = 0.08, alpha = 0.88 } },
      { type = "rectangle", action = "fill", frame = { x = 0, y = y, w = 6, h = MAIN_H }, fillColor = st.color },
      { type = "text", frame = { x = 18, y = y + 9, w = W - 26, h = 26 }, textSize = 17,
        textColor = { white = 1 }, text = st.icon .. "  " .. title(mainPid, 26) },
      { type = "text", frame = { x = 18, y = y + 35, w = W - 26, h = 22 }, textSize = 13,
        textColor = { white = 0.75 },
        text = st.text .. (hs.fs.attributes(HOME .. "/.voicemode/dnd") and "   ·   🌙 muted (DND)" or "") })
  end
  canvas:show(0.1)
end

---------------------------------------------------------------- events
local function handle(ev)
  local t, data = ev.event_type, ev.data or {}
  local now = hs.timer.secondsSinceEpoch()

  if M.onSpeakStart and t == "TTS_PLAYBACK_START" then pcall(M.onSpeakStart) end
  if M.onSpeakEnd and (t == "TTS_PLAYBACK_END" or t == "SESSION_END" or t == "CONCH_RELEASE") then
    pcall(M.onSpeakEnd)
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
    -- you answered: this session will be working and speak again
    if not (data.text or ""):match("^%s*$") then
      others[holder] = { state = "working", since = now, ttl = WORKING_TTL }
    end
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

function M.start()
  for file in hs.fs.dir(EVENTS_DIR) do
    if file:match("%.jsonl$") then
      local p = EVENTS_DIR .. file
      offsets[p] = hs.fs.attributes(p, "size") or 0
    end
  end
  M.watcher = hs.pathwatcher.new(EVENTS_DIR, function(paths)
    for _, p in ipairs(paths) do readNew(p) end
  end):start()
  M.poll = hs.timer.doEvery(1, function()
    for file in hs.fs.dir(EVENTS_DIR) do
      if file:match("%.jsonl$") then readNew(EVENTS_DIR .. file) end
    end
  end)
  M.expire = hs.timer.doEvery(5, render) -- drop stale rows
  M.flush = hs.timer.doEvery(60, function() identity = {} end)
end

function M.state()
  local parts = { "holder=" .. tostring(holder and lookup(holder).label) .. "/" .. tostring(holderState) }
  for pid, o in pairs(others) do parts[#parts + 1] = lookup(pid).label .. "=" .. o.state end
  parts[#parts + 1] = "visible=" .. tostring(canvas and canvas:isShowing())
  return table.concat(parts, " | ")
end

return M
