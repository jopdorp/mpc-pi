-- Measure what the appliance's own signal chain costs, at a real quantum.
--
-- The scheduling number (cyclictest) says the kernel can wake us in
-- time. It says nothing about whether the work fits in the period, and
-- that is the number that decides whether the instrument crackles: 29
-- plugins across sixteen tracks and two buses have to finish inside
-- 32 samples at 48kHz, which is 667 microseconds.
--
-- Reports the engine's own DSP load rather than CPU percentage, because
-- that is the ratio the audio thread actually lives by: 1.0 means the
-- callback took the whole period and the next one is already late.
--
--   luasession measure-dsp.lua       (env SESSION_DIR, SESSION_NAME, SECONDS)

local dir = os.getenv("SESSION_DIR") or "/tmp/mpc-daw"
local name = os.getenv("SESSION_NAME") or "mpcpi"
local secs = tonumber(os.getenv("SECONDS") or "20")
-- Line-buffer stdout. Lua block-buffers when redirected to a
-- file, so a long run shows nothing at all until it exits and
-- an interrupted one loses every measurement it had already
-- taken - which reads as a hang rather than a slow benchmark.
io.stdout:setvbuf("line")

local compat = dofile(os.getenv("MPCPI_COMPAT")
	or "scripts/daw/ardour-compat.lua")

local backend = compat.use_backend()
print("backend: " .. backend)

local session = load_session(dir, name)
assert(session, "could not load session at " .. dir .. "/" .. name)

local ok = pcall(function() AudioEngine:start() end)
print("engine start: " .. tostring(ok) ..
	"  running=" .. tostring(AudioEngine:running()))

-- STRESS=1 activates every processor on every route, including the
-- slots the session ships bypassed (alternate amp engine, chopper,
-- tuner). The player never runs all of these at once; the point is the
-- other direction - if the worst case fits the period, every real case
-- does.
if os.getenv("STRESS") == "1" then
	local n = 0
	local routes = session:get_routes()
	for r in routes:iter() do
		local i = 0
		while true do
			local proc = r:nth_processor(i)
			if proc:isnil() then break end
			if not proc:to_insert():isnil() then
				proc:activate()
				n = n + 1
			end
			i = i + 1
		end
	end
	print("stress: activated " .. n .. " plugin inserts")
end

-- ACTIVE selects which inserts run, so cost can be found by bisection
-- rather than by guessing. The first guess here was the seven 16-band
-- EQs; switching all of them off bought about 10%, which is exactly the
-- kind of confident wrong answer that a halving search does not let you
-- keep.
--
--   ACTIVE=none     every insert off - the floor: routing, track and
--                   graph overhead with no DSP at all
--   ACTIVE=all      every insert on
--   ACTIVE=3-14     inclusive 1-based range of the printed index
--
-- Indices are stable: route order, then processor order within a route,
-- which is the order the audio actually flows.
local function enumerate_inserts()
	local list = {}
	for r in session:get_routes():iter() do
		local i = 0
		while true do
			local proc = r:nth_processor(i)
			if proc:isnil() then break end
			if not proc:to_insert():isnil() then
				list[#list + 1] = {
					proc = proc,
					name = r:name() .. "/" .. proc:display_name(),
				}
			end
			i = i + 1
		end
	end
	return list
end

local want = os.getenv("ACTIVE")
if want and want ~= "" then
	local inserts = enumerate_inserts()
	-- A set, not a range: "4,5,13,14" measures every amp and cab in the
	-- desk at once, which is the question actually being asked. Ranges
	-- alone could only ever answer "is the cost in this contiguous
	-- block", and the answer to that turned out to be "no, it is
	-- spread" - two different halves each blew the budget on their own.
	local on = {}
	if want == "all" then
		for i = 1, #inserts do on[i] = true end
	elseif want ~= "none" then
		for part in (want .. ","):gmatch("([^,]+),") do
			local lo, hi = part:match("^(%d+)%-(%d+)$")
			if lo then
				for i = tonumber(lo), tonumber(hi) do on[i] = true end
			elseif part:match("^%d+$") then
				on[tonumber(part)] = true
			end
		end
	end
	local count = 0
	for i, ins in ipairs(inserts) do
		if on[i] then
			ins.proc:activate()
			count = count + 1
		else
			ins.proc:deactivate()
		end
		if os.getenv("LIST_INSERTS") == "1" then
			-- Reported latency too. On this instrument the master chain
			-- is in the live monitor path, so a lookahead limiter's
			-- latency is delay the player hears while playing - and it
			-- costs no CPU, so it never shows up in a DSP measurement.
			local lat = 0
			local ok = pcall(function()
				lat = ins.proc:signal_latency()
			end)
			print(string.format("INSERT %2d %s lat=%-6s %s", i,
				on[i] and "ON " or "off",
				ok and tostring(lat) or "?", ins.name))
		end
	end
	print(string.format("ACTIVE %s -> %d of %d inserts on",
		want, count, #inserts))
end

-- Linked into the driver's graph, or PipeWire never calls us.
print("master connected to " .. compat.connect_master(session) ..
	" playback ports")

-- Roll the transport so the graph is actually processing, not idling.
session:request_roll(ARDOUR.TransportRequestSource.TRS_UI)

-- A real sleep, never a spin. The first version busy-waited on
-- os.clock, and taskset had pinned this script to the audio cores: the
-- measurement loop itself then competed with the graph's client threads
-- for 25 straight seconds, so the tool was manufacturing a share of the
-- xruns it reported. ARDOUR.LuaAPI.usleep yields the core like any
-- blocked process.
local function sleep(s)
	if ARDOUR.LuaAPI and ARDOUR.LuaAPI.usleep then
		ARDOUR.LuaAPI.usleep(math.floor(s * 1e6))
	else
		os.execute("sleep " .. s)
	end
end

-- Settle before counting. Loading 29 plugins into a running graph
-- xruns freely, and those load-time overruns were being billed to
-- steady state: a 3-second run "measured" 18 of them. What matters to
-- a player is the count while playing, so baseline after two settled
-- seconds and report the delta.
sleep(2)
local xrun_base = session:get_xrun_count()

local max_load, sum, n = 0, 0, 0
for _ = 1, secs do
	sleep(1)
	local load = AudioEngine:get_dsp_load()
	if load > max_load then max_load = load end
	sum = sum + load
	n = n + 1
end
session:request_stop(false, false, ARDOUR.TransportRequestSource.TRS_UI)

print(string.format("DSP-LOAD max=%.1f%% avg=%.1f%% samples=%d",
	max_load, sum / math.max(n, 1), n))
print(string.format("XRUNS %d (plus %d during load)",
	session:get_xrun_count() - xrun_base, xrun_base))
session:save_state("", false, false, false, false, false)
close_session()
