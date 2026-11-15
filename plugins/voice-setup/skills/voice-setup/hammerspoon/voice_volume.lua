-- Voice-only volume for VoiceMode.
-- While a Claude session is speaking, the default output device is set to the
-- saved "voice volume"; when speech ends, the user's normal volume is restored.
-- ⌃⌥↑ / ⌃⌥↓ adjust the voice volume (persisted in hs.settings). Changing the
-- volume with the normal keys mid-speech is also kept as the new voice volume.

local M = {}

local KEY_VOICE  = "voiceVolume.voice"   -- 0..100, persisted
local KEY_NORMAL = "voiceVolume.normal"  -- saved normal level while speaking (crash recovery)
local STEP = 5

local speaking = false
local dndMuted = false -- we muted output for this utterance because of DND
local DND_FLAG = os.getenv("HOME") .. "/.voicemode/dnd"

function M.dnd() return hs.fs.attributes(DND_FLAG) ~= nil end

-- Quiet hours: DND switches on at QUIET_START and off at QUIET_END (local time).
-- Only acts when the window is entered/left, so a manual ⌃⌥D override holds
-- until the next scheduled switch. Checked every minute (survives Mac sleep).
-- Configure in ~/.voicemode/quiet-hours: one line "HH:MM HH:MM" (start end), or "off".
M.QUIET_START, M.QUIET_END = "00:30", "09:00"
local QUIET_FILE = os.getenv("HOME") .. "/.voicemode/quiet-hours"
local function loadQuiet()
  local fh = io.open(QUIET_FILE, "r")
  if not fh then return end
  local line = fh:read("l") or ""; fh:close()
  local a, b = line:match("(%d%d?:%d%d)%s+(%d%d?:%d%d)")
  if a then M.QUIET_START, M.QUIET_END = a, b
  elseif line:match("^%s*off") then M.QUIET_START, M.QUIET_END = "00:00", "00:00" end
end

local function minutes(hhmm) local h, m = hhmm:match("(%d+):(%d+)"); return h * 60 + m end
local function inQuiet()
  local t = os.date("*t"); local now = t.hour * 60 + t.min
  local a, b = minutes(M.QUIET_START), minutes(M.QUIET_END)
  if a <= b then return now >= a and now < b else return now >= a or now < b end
end
local function setDnd(on)
  if on then io.open(DND_FLAG, "w"):close() else os.remove(DND_FLAG) end
end
local lastQuiet = nil
local function quietTick()
  loadQuiet()
  local q = inQuiet()
  if q ~= lastQuiet then
    if lastQuiet ~= nil or q then setDnd(q) end -- at startup only force ON inside the window
    lastQuiet = q
  end
end

local function device() return hs.audiodevice.defaultOutputDevice() end

local function getVol()
  local d = device()
  return d and d:volume()
end

local function setVol(v)
  local d = device()
  if d and d:volume() ~= nil then d:setVolume(math.max(0, math.min(100, v))) end
end

local function voiceVol()
  return hs.settings.get(KEY_VOICE) or 50
end

function M.speakStart()
  if speaking then return end
  if M.dnd() then
    -- do-not-disturb: hard mute while Claude speaks, whatever the session does
    local d = device()
    if d and not d:muted() then d:setMuted(true); dndMuted = true end
    speaking = true
    return
  end
  local cur = getVol()
  if cur == nil then return end -- device has no software volume (e.g. some HDMI)
  speaking = true
  hs.settings.set(KEY_NORMAL, cur)
  setVol(voiceVol())
end

function M.speakEnd()
  if not speaking then return end
  speaking = false
  if dndMuted then
    local d = device()
    if d then d:setMuted(false) end
    dndMuted = false
    return
  end
  if hs.settings.get(KEY_NORMAL) == nil then return end
  local cur = getVol()
  -- user nudged volume with normal keys during speech: keep that as voice volume
  if cur and math.abs(cur - voiceVol()) >= 1 then
    hs.settings.set(KEY_VOICE, math.floor(cur + 0.5))
  end
  local normal = hs.settings.get(KEY_NORMAL)
  if normal then setVol(normal) end
  hs.settings.clear(KEY_NORMAL)
end

local function nudge(delta)
  local v = math.max(0, math.min(100, voiceVol() + delta))
  hs.settings.set(KEY_VOICE, v)
  if speaking then setVol(v) end
  hs.alert.closeAll(0)
  hs.alert.show(string.format("🔊 Claude voice volume  %d%%", v), 0.8)
end

function M.start()
  -- recover if Hammerspoon died/reloaded mid-speech
  local normal = hs.settings.get(KEY_NORMAL)
  if normal then setVol(normal); hs.settings.clear(KEY_NORMAL) end
  -- first run: start the voice at the current volume so nothing jumps
  if hs.settings.get(KEY_VOICE) == nil then
    local cur = getVol()
    if cur then hs.settings.set(KEY_VOICE, math.floor(cur + 0.5)) end
  end
  M.up   = hs.hotkey.bind({ "ctrl", "alt" }, "up",   function() nudge(STEP) end,  nil, function() nudge(STEP) end)
  quietTick()
  M.quietTimer = hs.timer.doEvery(60, quietTick)
  M.dndKey = hs.hotkey.bind({ "ctrl", "alt" }, "d", function()
    if M.dnd() then os.remove(DND_FLAG) else io.open(DND_FLAG, "w"):close() end
    hs.alert.closeAll(0)
    hs.alert.show(M.dnd() and "🌙 Claude voice: Do Not Disturb ON" or "🔔 Claude voice: Do Not Disturb OFF", 1.2)
  end)
  M.down = hs.hotkey.bind({ "ctrl", "alt" }, "down", function() nudge(-STEP) end, nil, function() nudge(-STEP) end)
end

function M.state()
  local d = device()
  return string.format("voice=%s speaking=%s current=%s savedNormal=%s dnd=%s muted=%s",
    tostring(voiceVol()), tostring(speaking), tostring(getVol()), tostring(hs.settings.get(KEY_NORMAL)),
    tostring(M.dnd()), tostring(d and d:muted())) .. " quiet=" .. M.QUIET_START .. "-" .. M.QUIET_END .. " inQuiet=" .. tostring(inQuiet())
end

return M
