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

-- Roll the transport so the graph is actually processing, not idling.
session:request_roll(ARDOUR.TransportRequestSource.TRS_UI)

local function sleep(s)
	local t = os.clock() + s
	while os.clock() < t do end
end

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
print(string.format("XRUNS %d", session:get_xrun_count()))
session:save_state("", false, false, false, false, false)
close_session()
