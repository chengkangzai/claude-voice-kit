-- Pause Claude's voice while you dictate (Claude Code /voice, or a Zoom/Teams call).
-- macOS reports when any app is using the microphone. If the mic is busy and it
-- isn't VoiceMode listening for a reply, you're talking to something else, so:
--   * a session that is speaking right now is muted until you stop
--   * ~/.voicemode/dictating is created; the guard then holds the mic lock so no
--     new voice turn starts ("the user is dictating, try again shortly")
-- Everything is released ~1 s after the mic is free again.

local M = {}

local HOME = os.getenv("HOME")
local FLAG = HOME .. "/.voicemode/dictating"
local START_AFTER = 0.8   -- s of outside mic use before we react (debounce)
local STOP_AFTER = 1.0    -- s of free mic before we release

local extSince, freeSince = nil, nil
local active, mutedByUs = false, false

local function voiceModeListening()
  local o = M.overlay
  local st = o and o.holderState and o.holderState()
  return st == "listening"
end

local function voiceModeSpeaking()
  local o = M.overlay
  return o and o.holderState and o.holderState() == "speaking"
end

local function release()
  active = false
  os.remove(FLAG)
  if mutedByUs then
    local out = hs.audiodevice.defaultOutputDevice()
    if out then out:setMuted(false) end
    mutedByUs = false
  end
  if M.onChange then pcall(M.onChange) end
end

local function tick()
  local now = hs.timer.secondsSinceEpoch()
  local mic = hs.audiodevice.defaultInputDevice()
  local outside = mic and mic:inUse() and not voiceModeListening()

  if outside then
    freeSince = nil
    extSince = extSince or now
    if not active and now - extSince >= START_AFTER then
      active = true
      local fh = io.open(FLAG, "w"); if fh then fh:write("dictating\n"); fh:close() end
      if M.onChange then pcall(M.onChange) end
    end
  else
    extSince = nil
    if active then
      freeSince = freeSince or now
      if now - freeSince >= STOP_AFTER then release() end
    end
  end

  -- a session talking over you: silence it until you're done
  if active and not mutedByUs and voiceModeSpeaking() then
    local out = hs.audiodevice.defaultOutputDevice()
    if out and not out:muted() then out:setMuted(true); mutedByUs = true end
  end
end

function M.active() return active end

function M.start()
  os.remove(FLAG) -- never start with a stale flag
  M.timer = hs.timer.doEvery(0.25, function()
    local ok, e = pcall(tick); if not ok then print("voice_mic: " .. tostring(e)) end
  end)
end

function M.state()
  local mic = hs.audiodevice.defaultInputDevice()
  return string.format("dictating=%s micInUse=%s mutedByUs=%s voiceListening=%s",
    tostring(active), tostring(mic and mic:inUse()), tostring(mutedByUs), tostring(voiceModeListening()))
end

return M
