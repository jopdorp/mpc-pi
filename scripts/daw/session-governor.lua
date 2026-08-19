-- The Lua side of daw-ctl: owns the session, drains region operations.
--
-- OSC covers the mixer, transport and plugin parameters, but not region
-- editing - splitting, moving, fades, trims, closing a take and laying
-- loop repetitions ahead of the playhead all need the Lua API. daw-ctl
-- writes those as one-line commands to a queue file; this script owns the
-- session and applies them.
--
-- A file queue rather than a socket because a file survives either side
-- restarting with no reconnect dance, which on stage is the only
-- property that matters. Each line is applied then dropped, so a crash
-- mid-queue loses at most the operations not yet applied, never repeats
-- one.
--
--   queue lines (whitespace separated):
--     finalize  <track> length <samples>        close a take into a loop
--     repeat    <track> at <samples> times <n>  keep the lane sounding
--     clear     <track>                         discard the lane's loop
--     split     <track> <region> <samples>
--     move      <track> <region> <samples>
--     duplicate <track> <region> <samples>
--     fadein    <track> <region> <samples>
--     fadeout   <track> <region> <samples>
--     trim      <track> <region> <start> <end>
--     gain      <track> <region> <factor>
--     normalize <track> <region> [target dB]
--     remove    <track> <region>
--     undo
--     save
--
-- The first three are daw-ctl's loop-engine action strings VERBATIM (see
-- loop-ops.lua): one vocabulary, so there is no translation layer between
-- the two halves to drift apart. What each does, and what a punch-out
-- costs, is documented in loop-ops.lua - this file is only the host.
--
-- AND ONE FILE THE OTHER WAY: $DAW_REGIONS, the region list. The queue
-- carries edits down; that file carries the playlist back up, and it is
-- the only thing daw-ctl can see of the audio it is editing. Its format
-- and why it exists are at publish() below.
--
--   SESSION_DIR/SESSION_NAME select the session; DAW_QUEUE the queue file.

local queue_path = os.getenv("DAW_QUEUE") or "/dev/shm/daw-region-queue"
local dir = os.getenv("SESSION_DIR") or "/tmp/mpc-daw"
local name = os.getenv("SESSION_NAME") or "mpcpi"
local once = os.getenv("GOVERNOR_ONCE") == "1"

local function say(t) io.write(t .. "\n") io.flush() end

-- Find our siblings next to this script rather than from the cwd. A
-- service has no useful cwd, and the failure when a relative dofile misses
-- is "Permission denied" rather than "not found", which sends you looking
-- at file modes instead of at the path.
local here = (debug.getinfo(1, "S").source or ""):match("^@(.*)[/\\]") or "."
local compat = dofile(os.getenv("MPCPI_COMPAT") or (here .. "/ardour-compat.lua"))
local loop = dofile(os.getenv("MPCPI_LOOP_OPS") or (here .. "/loop-ops.lua"))
loop.compat = compat
loop.say = say

AudioEngine:set_backend("JACK/Pipewire", "", "")
-- 44100, not 48000. The whole appliance runs at 44.1k - the graph clock, the
-- emulator, and the USB gadget - and a 48k session on a 44.1k graph resamples
-- everything for no reason. This said 48000, which is Ardour's own default and
-- nobody's decision.
local rate = tonumber(os.getenv("MPCPI_RATE") or "44100")

local session = load_session(dir, name)
if not session then
	-- A half-written session file blocks its own recreation: load_session
	-- fails with "Cannot get samplerate from session", create_session refuses
	-- with "Session already exists", and the assert below fires. That loop
	-- restarted this service twelve times in a row. Move the wreckage aside
	-- rather than deleting it - it is the only record of whatever went wrong.
	local broken = dir .. "/" .. name .. ".ardour"
	local f = io.open(broken, "r")
	if f then
		f:close()
		local stamp = os.date("%Y%m%d-%H%M%S")
		os.rename(broken, broken .. ".broken-" .. stamp)
		say("moved an unloadable session aside: " .. broken ..
		    ".broken-" .. stamp)
	end
	session = create_session(dir, name, rate)
end
assert(session, "no session at " .. dir .. "/" .. name ..
       " (rate " .. rate .. ")")
say("GOVERNOR_READY " .. dir .. "/" .. name ..
    " claimed=" .. loop.attach(session))

local applied, failed = 0, 0

local function apply(line)
	if line:match("^%s*$") then return end
	local ok, err = loop.apply(line)
	if ok then
		applied = applied + 1
	else
		failed = failed + 1
		say("GOVERNOR_FAIL " .. line .. " -- " .. tostring(err))
	end
end

-- THE CHANNEL BACK: the region list, as a file. Written by loop-ops.lua,
-- which owns the playlist; this file is only the host, and the format and
-- the reasoning are documented next to the code, at M.publish.
local state_path = os.getenv("DAW_REGIONS") or "/dev/shm/daw-regions"

-- Publishing must never take the session host down. A screen that misses a
-- frame is a screen that misses a frame; a governor that exits stops
-- draining the queue, and with it every loop the player has recorded.
local function publish_safely()
	local ok, err = pcall(loop.publish, state_path)
	if not ok then say("GOVERNOR_PUBLISH_ERR " .. tostring(err)) end
end

local function drain()
	-- TAKE the queue, do not read-then-truncate it. daw-ctl appends whenever
	-- a take closes, and anything it wrote between the read and the truncate
	-- used to vanish - which for one line in particular means a take that was
	-- captured and never became a loop, the exact failure this whole path
	-- exists to fix. A rename is atomic and the writer opens the path fresh
	-- for every line, so after this it appends to a new file.
	local taken = queue_path .. ".taken"
	if not os.rename(queue_path, taken) then return 0 end
	local f = io.open(taken, "r")
	if not f then return 0 end
	local lines = {}
	for line in f:lines() do lines[#lines + 1] = line end
	f:close()
	os.remove(taken)
	if #lines == 0 then return 0 end
	for _, line in ipairs(lines) do apply(line) end
	publish_safely()
	return #lines
end

if once then
	publish_safely()
	local n = drain()
	say(string.format("GOVERNOR_DONE drained=%d applied=%d failed=%d",
		n, applied, failed))
	close_session()
	return
end

-- Publish ONCE BEFORE THE LOOP, not only after a drain. Nothing had ever
-- written the file on a running appliance: /dev/shm/daw-regions did not
-- exist until the first take closed, so daw-ctl came up with no idea
-- whether the session was empty or unreadable, and a governor that
-- restarted under a session full of audio published nothing until the
-- player recorded something new.
publish_safely()

-- ...and on a slow timer after that, because the header carries the
-- TRANSPORT POSITION as well as the regions and that is the EDIT page's
-- playhead. Twice a second is far below the rate a moving playhead is
-- drawn at, and it is also the resync a daw-ctl that restarted needs;
-- region changes themselves still publish immediately, from the drain.
local PUBLISH_TICKS = 25                  -- 25 * 20 ms = 500 ms
local ticks = 0
while true do
	if drain() > 0 then
		ticks = 0
	else
		ticks = ticks + 1
		if ticks >= PUBLISH_TICKS then
			ticks = 0
			publish_safely()
		end
	end
	ARDOUR.LuaAPI.usleep(20 * 1000)
end
