-- Presence for Claude Code voice: present / away / dnd.
--  * Auto-away after IDLE_LIMIT with no keyboard/mouse AND no voice reply from you.
--  * ⌃⌥A toggles away by hand (or say "brb" to a session; it runs `away on`).
--  * Back = any keyboard/mouse input after away began (15 s grace, so the key
--    press that set away doesn't count). Then the inbox digest is read out.
--  * The digest also plays on your first input after DND ends.
-- State lives in flag files (~/.voicemode/away, ~/.voicemode/dnd) shared with
-- the guard, the CLI (`away`, `dnd`, `presence`) and the sessions.

local M = {}

local HOME = os.getenv("HOME")
local AWAY = HOME .. "/.voicemode/away"
local DND = HOME .. "/.voicemode/dnd"
local INBOX = HOME .. "/.voicemode/inbox"
local SPEAK = HOME .. "/.voicemode/bin/inbox-speak"
M.IDLE_LIMIT = 60 * 60   -- s without keyboard/mouse/voice before auto-away
local GRACE = 15         -- s after away starts during which input doesn't count
local ACTIVE = 5         -- s: input this recent = you're at the Mac

local lastUserVoice = hs.timer.secondsSinceEpoch()
local lastDigestTry = 0
local digestTask = nil

local function exists(p) return hs.fs.attributes(p) ~= nil end
function M.away() return exists(AWAY) end
function M.dnd() return exists(DND) end

function M.pending()
  local n = 0
  if exists(INBOX) then
    for f in hs.fs.dir(INBOX) do if f:match("%.json$") then n = n + 1 end end
  end
  return n
end

local function setAway(on, reason)
  if on then
    local fh = io.open(AWAY, "w"); fh:write((reason or "manual") .. "\n"); fh:close()
  else
    os.remove(AWAY)
  end
  if M.onChange then pcall(M.onChange) end
end

-- called by the overlay when you answer a session by voice
function M.userSpoke() lastUserVoice = hs.timer.secondsSinceEpoch() end

local function runDigest()
  if digestTask and digestTask:isRunning() then return end
  lastDigestTry = hs.timer.secondsSinceEpoch()
  if M.onSpeakStart then pcall(M.onSpeakStart) end
  digestTask = hs.task.new(SPEAK, function()
    if M.onSpeakEnd then pcall(M.onSpeakEnd) end
    if M.onChange then pcall(M.onChange) end
  end)
  digestTask:start()
end

local function tick()
  local now = hs.timer.secondsSinceEpoch()
  local idle = hs.host.idleTime()
  local away, dnd = M.away(), M.dnd()

  if away then
    local since = hs.fs.attributes(AWAY, "modification") or now
    -- input that happened after away began (+grace) = you're back
    if idle < ACTIVE and now - since > GRACE and (now - idle) > since + GRACE then
      setAway(false)
      hs.alert.show("👋 Welcome back" .. (M.pending() > 0 and string.format(" · %d waiting", M.pending()) or ""), 1.5)
      away = false
    end
  elseif not dnd then
    local quietFor = math.min(idle, now - lastUserVoice)
    if quietFor >= M.IDLE_LIMIT then setAway(true, "auto") return end
  end

  -- read the inbox once you're present and actually at the Mac
  if not away and not dnd and idle < ACTIVE and M.pending() > 0 and now - lastDigestTry > 60 then
    runDigest()
  end
end

function M.start()
  M.timer = hs.timer.doEvery(2, function() local ok, e = pcall(tick); if not ok then print("voice_presence: " .. tostring(e)) end end)
  M.key = hs.hotkey.bind({ "ctrl", "alt" }, "a", function()
    local on = not M.away()
    setAway(on, "manual")
    hs.alert.closeAll(0)
    hs.alert.show(on and "💤 Away: Claude will queue messages" or "👋 Back", 1.2)
  end)
end

function M.status()
  if M.dnd() then return "dnd" elseif M.away() then return "away" else return "present" end
end

function M.state()
  return string.format("status=%s pending=%d idle=%.0fs sinceVoice=%.0fs limit=%ds",
    M.status(), M.pending(), hs.host.idleTime(), hs.timer.secondsSinceEpoch() - lastUserVoice, M.IDLE_LIMIT)
end

return M
