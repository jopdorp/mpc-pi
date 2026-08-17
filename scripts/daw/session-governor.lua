-- The Lua side of daw-ctl: owns the session, drains region operations.
--
-- OSC covers the mixer, transport and plugin parameters, but not region
-- editing - splitting, moving, fades, trims, and laying loop repetitions
-- ahead of the playhead all need the Lua API. daw-ctl writes those as
-- one-line commands to a queue file; this script owns the session and
-- applies them.
--
-- A file queue rather than a socket because a file survives either side
-- restarting with no reconnect dance, which on stage is the only
-- property that matters. Each line is applied then dropped, so a crash
-- mid-queue loses at most the operations not yet applied, never repeats
-- one.
--
--   queue lines (whitespace separated):
--     split   <track> <region> <samples>
--     move    <track> <region> <samples>
--     fadein  <track> <region> <samples>
--     fadeout <track> <region> <samples>
--     trim    <track> <region> <start> <end>
--     gain    <track> <region> <factor>
--     repeat  <track> <region> <at> <times>
--     remove  <track> <region>
--     save
--
--   SESSION_DIR/SESSION_NAME select the session; QUEUE the queue file.

local queue_path = os.getenv("DAW_QUEUE") or "/dev/shm/daw-region-queue"
local dir = os.getenv("SESSION_DIR") or "/tmp/mpc-daw"
local name = os.getenv("SESSION_NAME") or "mpcpi"
local once = os.getenv("GOVERNOR_ONCE") == "1"

local function say(t) io.write(t .. "\n") io.flush() end

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
say("GOVERNOR_READY " .. dir .. "/" .. name)

local function route_by_name(track)
	local r = session:route_by_name(track)
	if r and not r:isnil() then return r end
	return nil
end

local function playlist_of(track)
	local r = route_by_name(track)
	if not r then return nil end
	local t = r:to_track()
	if not t or t:isnil() then return nil end
	return t:playlist()
end

-- Regions are addressed by name, which is what daw-ctl sees in the state
-- it renders; an index would break the moment anything is added.
local function region_by_name(track, want)
	local pl = playlist_of(track)
	if not pl then return nil, nil end
	for r in pl:region_list():iter() do
		if r:name() == want then return r, pl end
	end
	return nil, pl
end

-- Ardour's time getters return timecnt/timepos objects rather than
-- plain numbers, and which one varies by call, so normalise here.
local function samples_of(v)
	if type(v) == "number" then return v end
	if type(v) == "userdata" then
		local ok, n = pcall(function() return v:samples() end)
		if ok and type(n) == "number" then return n end
		local ok2, n2 = pcall(function() return v:val() end)
		if ok2 and type(n2) == "number" then return n2 end
	end
	return 0
end

local applied, failed = 0, 0

local ops = {}

function ops.split(track, region, pos)
	local r, pl = region_by_name(track, region)
	assert(r and pl, "no region " .. tostring(region))
	pl:split_region(r, Temporal.timepos_t(tonumber(pos)))
end

function ops.move(track, region, pos)
	local r = region_by_name(track, region)
	assert(r, "no region " .. tostring(region))
	r:set_position(Temporal.timepos_t(tonumber(pos)))
end

function ops.fadein(track, region, len)
	local r = region_by_name(track, region)
	assert(r, "no region")
	local ar = r:to_audioregion()
	assert(ar and not ar:isnil(), "not an audio region")
	ar:set_fade_in_length(tonumber(len))
	ar:set_fade_in_active(true)
end

function ops.fadeout(track, region, len)
	local r = region_by_name(track, region)
	assert(r, "no region")
	local ar = r:to_audioregion()
	assert(ar and not ar:isnil(), "not an audio region")
	ar:set_fade_out_length(tonumber(len))
	ar:set_fade_out_active(true)
end

function ops.trim(track, region, from, to)
	local r = region_by_name(track, region)
	assert(r, "no region")
	r:trim_to(Temporal.timepos_t(tonumber(from)),
	          Temporal.timecnt_t(tonumber(to) - tonumber(from)))
end

function ops.gain(track, region, factor)
	local r = region_by_name(track, region)
	assert(r, "no region")
	local ar = r:to_audioregion()
	assert(ar and not ar:isnil(), "not an audio region")
	ar:set_scale_amplitude(tonumber(factor))
end

-- The loop engine's top-up: lay N copies of a region starting at `at`.
--
-- Each repetition must be a CLONE. Adding the same region object
-- repeatedly does not copy it - it repositions the one region, so a
-- four-bar loop laid four times ends up as a single region at the last
-- position, which is exactly what the region feedback caught.
ops["repeat"] = function(track, region, at, times)
	local r, pl = region_by_name(track, region)
	assert(r and pl, "no region " .. tostring(region))
	local pos = tonumber(at)
	local len = samples_of(r:length())
	for _ = 1, tonumber(times) do
		local copy = ARDOUR.RegionFactory.clone_region(r, false, false)
		assert(copy and not copy:isnil(), "clone_region failed")
		pl:add_region(copy, Temporal.timepos_t(pos), 1, false)
		pos = pos + len
	end
end

function ops.remove(track, region)
	local r, pl = region_by_name(track, region)
	assert(r and pl, "no region " .. tostring(region))
	pl:remove_region(r)
end

function ops.save()
	session:save_state("", false, false, false, false, false)
end

local function apply(line)
	local parts = {}
	for w in line:gmatch("%S+") do parts[#parts + 1] = w end
	if #parts == 0 then return end
	local fn = ops[parts[1]]
	if not fn then
		say("GOVERNOR_UNKNOWN " .. parts[1])
		failed = failed + 1
		return
	end
	local ok, err = pcall(fn, parts[2], parts[3], parts[4], parts[5])
	if ok then
		applied = applied + 1
	else
		failed = failed + 1
		say("GOVERNOR_FAIL " .. line .. " -- " .. tostring(err))
	end
end

-- After every drain, publish the track's regions. Editing renames
-- things - a split turns one region into two with new names - so
-- daw-ctl cannot keep addressing what it saw last time. This file is
-- how it resyncs, and it is also what the EDIT page draws.
local state_path = os.getenv("DAW_REGIONS") or "/dev/shm/daw-regions"

local function publish()
	local f = io.open(state_path .. ".tmp", "w")
	if not f then return end
	for r in session:get_routes():iter() do
		local t = r:to_track()
		if t and not t:isnil() then
			local pl = t:playlist()
			if pl and not pl:isnil() then
				for reg in pl:region_list():iter() do
					local ar = reg:to_audioregion()
					local gain = 1.0
					local fi, fo = 0, 0
					if ar and not ar:isnil() then
						gain = ar:scale_amplitude()
						fi = samples_of(ar:fade_in_length())
						fo = samples_of(ar:fade_out_length())
					end
					f:write(string.format("%s\t%s\t%d\t%d\t%d\t%d\t%.4f\n",
						r:name(), reg:name(),
						samples_of(reg:position()),
						samples_of(reg:length()), fi, fo, gain))
				end
			end
		end
	end
	f:close()
	os.rename(state_path .. ".tmp", state_path)
end

local function drain()
	local f = io.open(queue_path, "r")
	if not f then return 0 end
	local lines = {}
	for line in f:lines() do lines[#lines + 1] = line end
	f:close()
	if #lines == 0 then return 0 end
	-- Truncate before applying: an operation that crashes must not be
	-- replayed on restart, which would double-apply a move or a split.
	local w = io.open(queue_path, "w")
	if w then w:close() end
	for _, line in ipairs(lines) do apply(line) end
	publish()
	return #lines
end

if once then
	local pok, perr = pcall(publish)
	if not pok then say("GOVERNOR_PUBLISH_ERR " .. tostring(perr)) end
	local n = drain()
	say(string.format("GOVERNOR_DONE drained=%d applied=%d failed=%d",
		n, applied, failed))
	close_session()
	return
end

while true do
	drain()
	ARDOUR.LuaAPI.usleep(20 * 1000)
end
