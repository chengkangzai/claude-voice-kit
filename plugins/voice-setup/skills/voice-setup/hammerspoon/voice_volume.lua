-- Voice-only volume and Do Not Disturb for VoiceMode.
-- Claude's audio is scaled by a gain (per output device) written to ~/.voicemode/voice-gain;
-- ~/.voicemode/lib/voice_gain.py applies it inside every Claude player. The Mac's volume
-- and mute are never changed, so YouTube/music are unaffected. DND = gain 0 (applied live
-- by the players), not a device mute.
-- ⌃⌥] / ⌃⌥[ adjust it in 10% steps (not ⌃⌥↑/↓: Rectangle uses those). ⌃⌥D toggles DND.

local M = {}

local HOME = os.getenv("HOME")
local DND_FLAG = HOME .. "/.voicemode/dnd"
local GAIN_FILE = HOME .. "/.voicemode/voice-gain"
local KEY_GAIN = "voiceVolume.gain"            -- .<device uid> = 0.1..3.0
local KEY_QUIET = "voiceVolume.quietApplied"   -- last schedule state applied (survives restarts)
local KEY_ALERT = "voiceVolume.alertBeforeDnd"
local KEY_MUTED = "voiceVolume.dndMutedUID"    -- legacy: device muted by an older version
local STEP, MIN_GAIN, MAX_GAIN = 0.1, 0.1, 3.0

local speaking = false

function M.dnd() return hs.fs.attributes(DND_FLAG) ~= nil end

-- ---------------------------------------------------------------- quiet hours
-- DND switches on at QUIET_START and off at QUIET_END (local time). It acts only when the
-- window is entered/left, so a manual ⌃⌥D override holds until the next switch. The last
-- applied state is persisted, so a reload inside the window keeps a manual "off", and a
-- restart after the window ends still clears the night's DND.
-- Configure in ~/.voicemode/quiet-hours: one line "HH:MM HH:MM" (start end), or "off".
M.QUIET_START, M.QUIET_END = "00:30", "09:00"
local QUIET_FILE = HOME .. "/.voicemode/quiet-hours"
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
  if on then local fh = io.open(DND_FLAG, "w"); if fh then fh:close() end else os.remove(DND_FLAG) end
end

-- During DND also silence macOS alert sounds (the terminal bell Claude Code
-- rings when a session needs you). Previous level saved and restored after.
local function alertVolume()
  local ok, v = hs.osascript.applescript("alert volume of (get volume settings)")
  return ok and tonumber(v) or nil
end
function M.syncAlerts()
  local saved = hs.settings.get(KEY_ALERT)
  if M.dnd() and saved == nil then
    local v = alertVolume()
    if v then
      hs.settings.set(KEY_ALERT, v)
      hs.osascript.applescript("set volume alert volume 0")
    end
  elseif not M.dnd() and saved ~= nil then
    hs.osascript.applescript("set volume alert volume " .. math.floor(saved))
    hs.settings.clear(KEY_ALERT)
  end
end

local function quietTick()
  loadQuiet()
  local q = inQuiet()
  local last = hs.settings.get(KEY_QUIET)
  if q ~= last then
    if last ~= nil or q then setDnd(q) end -- very first run: only force ON inside the window
    hs.settings.set(KEY_QUIET, q)
    M.syncAlerts()
  end
end

-- ---------------------------------------------------------------- voice gain
local function device() return hs.audiodevice.defaultOutputDevice() end

local function gainKey()
  local d = device()
  return KEY_GAIN .. "." .. ((d and d:uid()) or "default")
end
local function gain()
  local g = tonumber(hs.settings.get(gainKey()))
  if g == nil or g ~= g then g = 1.0; hs.settings.set(gainKey(), g) end
  return math.max(MIN_GAIN, math.min(MAX_GAIN, g))
end

-- Write atomically (temp file + rename) so a player never reads a half-written file, and
-- re-check the file every call instead of trusting a cache, so it repairs itself if
-- something deletes or changes it.
local function writeGain()
  local want = string.format("%.2f", gain())
  local fh = io.open(GAIN_FILE, "r")
  local have = fh and fh:read("l"); if fh then fh:close() end
  if have == want then return true end
  local tmp = GAIN_FILE .. ".tmp"
  fh = io.open(tmp, "w")
  if not fh then return false end
  local ok = fh:write(want .. "\n")
  ok = fh:close() and ok
  if not ok then os.remove(tmp); return false end
  local renamed, err = os.rename(tmp, GAIN_FILE)
  if not renamed then print("voice_volume: " .. tostring(err)); os.remove(tmp); return false end
  return true
end
M.writeGain = writeGain

-- The players apply the gain and DND themselves; nothing to change on the Mac.
function M.speakStart() speaking = true; writeGain() end
function M.speakEnd() speaking = false end

local function nudge(delta)
  local g = math.floor((gain() + delta) * 10 + 0.5) / 10
  g = math.max(MIN_GAIN, math.min(MAX_GAIN, g))
  hs.settings.set(gainKey(), g)
  writeGain()
  hs.alert.closeAll(0)
  hs.alert.show(string.format("🔊 Claude voice  %d%%  (Mac volume untouched)", math.floor(g * 100 + 0.5)), 0.8)
end

-- Older versions muted the output device during DND speech. Unmute only that exact
-- device; if it isn't connected right now, keep the note and try again later.
local function recoverLegacyMute()
  local uid = hs.settings.get(KEY_MUTED)
  if not uid then return end
  local d = hs.audiodevice.findDeviceByUID(uid)
  if d then
    d:setMuted(false)
    hs.settings.clear(KEY_MUTED)
  end
end

function M.start()
  hs.settings.clear("voiceVolume.normal")   -- legacy: Mac volume saved mid-speech; no longer used
  recoverLegacyMute()
  writeGain()
  -- headphones / AirPods connected or default output changed: switch to that device's gain now
  hs.audiodevice.watcher.setCallback(function(ev)
    if ev == "dOut" then writeGain() end
  end)
  hs.audiodevice.watcher.start()
  -- slow reconcile: repairs the file, catches missed events, retries a pending unmute
  M.devTimer = hs.timer.doEvery(2, function() writeGain(); recoverLegacyMute() end)

  quietTick()
  M.syncAlerts()
  M.quietTimer = hs.timer.doEvery(60, quietTick)
  -- 5 s so `dnd on/off` from the terminal mutes/unmutes alerts promptly
  M.alertTimer = hs.timer.doEvery(5, M.syncAlerts)
  M.up   = hs.hotkey.bind({ "ctrl", "alt" }, "]", function() nudge(STEP) end,  nil, function() nudge(STEP) end)
  M.down = hs.hotkey.bind({ "ctrl", "alt" }, "[", function() nudge(-STEP) end, nil, function() nudge(-STEP) end)
  M.dndKey = hs.hotkey.bind({ "ctrl", "alt" }, "d", function()
    setDnd(not M.dnd())
    M.syncAlerts()
    hs.alert.closeAll(0)
    hs.alert.show(M.dnd() and "🌙 Claude voice: Do Not Disturb ON" or "🔔 Claude voice: Do Not Disturb OFF", 1.2)
  end)
end

function M.state()
  local d = device()
  local fh = io.open(GAIN_FILE, "r"); local file = fh and fh:read("l"); if fh then fh:close() end
  return string.format("gain=%s file=%s speaking=%s device=%s macVolume=%s dnd=%s pendingUnmute=%s",
    tostring(gain()), tostring(file), tostring(speaking), tostring(d and d:name()), tostring(d and d:volume()),
    tostring(M.dnd()), tostring(hs.settings.get(KEY_MUTED)))
    .. " alertVol=" .. tostring(alertVolume()) .. " alertSaved=" .. tostring(hs.settings.get(KEY_ALERT))
    .. " quiet=" .. M.QUIET_START .. "-" .. M.QUIET_END .. " inQuiet=" .. tostring(inQuiet())
    .. " quietApplied=" .. tostring(hs.settings.get(KEY_QUIET))
end

return M
