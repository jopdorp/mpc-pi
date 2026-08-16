-- What does each plugin in the manifest actually cost?
--
-- The sweep says the whole desk does not fit at quantum 32. It does not
-- say which plugin to blame, and without that the choices are a blind
-- recompile or a blind trim. Seven of the twenty-nine slots are
-- para_equalizer_x16 - sixteen bands each, for a design that uses about
-- three - so the ranking matters more than any compiler flag.
--
-- Method: one track, plugins added one at a time, DSP load sampled after
-- each. The delta is that plugin's cost in the same graph the appliance
-- runs, which is the only place the number means anything. Costs are
-- reported per instance and multiplied by the manifest's own count, so
-- the ranking answers "what should change" rather than "what is slow".
--
--   luasession bench-plugins.lua      (env SESSION_DIR, QUANTUM already set)

-- Line-buffer stdout. Lua block-buffers when redirected to a
-- file, so a long run shows nothing at all until it exits and
-- an interrupted one loses every measurement it had already
-- taken - which reads as a hang rather than a slow benchmark.
io.stdout:setvbuf("line")

local compat = dofile(os.getenv("MPCPI_COMPAT")
	or "scripts/daw/ardour-compat.lua")
local dir = os.getenv("SESSION_DIR") or "/home/mpc/bench"
local name = os.getenv("SESSION_NAME") or "b"
local settle = tonumber(os.getenv("SETTLE") or "8")
-- Instances per measurement. One plugin's cost at a small quantum is
-- below the noise floor of a /proc sample - the first run produced
-- +0.25% and -0.25% for plugins that obviously do not have negative
-- cost. Adding several copies multiplies the signal while the noise
-- stays put, and the per-instance figure is the delta divided by this.
local copies = tonumber(os.getenv("COPIES") or "4")

local function sleep(s)
	if ARDOUR.LuaAPI and ARDOUR.LuaAPI.usleep then
		ARDOUR.LuaAPI.usleep(math.floor(s * 1e6))
	else
		os.execute("sleep " .. s)
	end
end

compat.use_backend()
local session = create_session(dir, name, 44100)
assert(session, "no session")
pcall(function() AudioEngine:start() end)

local tl = session:new_audio_track(2, 2, compat.route_group(), 1, "BENCH",
	ARDOUR.PresentationInfo.max_order, ARDOUR.TrackMode.Normal, true, true)
local route = tl:front()
-- A generator at the head of the chain, because silence is not a
-- workload. Most DSP short-circuits on digital silence - LSP's EQs
-- certainly do - so benchmarking an idle track measures the early-out
-- path and reports a 16-band parametric EQ at 0.03% of a core, roughly
-- a hundredfold too cheap. With noise flowing, every plugin downstream
-- does the work it would do under a player's hands.
local GEN = os.getenv("BENCH_GENERATOR")
	or "http://lsp-plug.in/plugins/lv2/noise_generator_x2"
local gen = ARDOUR.LuaAPI.new_plugin(session, GEN, ARDOUR.PluginType.LV2, "")
if gen and not gen:isnil() then
	route:add_processor_by_index(gen, 0, nil, true)
	print("generator: " .. GEN)
else
	print("WARNING: no generator (" .. GEN .. ") - costs will read low")
end

local linked = compat.connect_master(session)
print("master connected to " .. linked .. " playback ports")
session:request_roll(ARDOUR.TransportRequestSource.TRS_UI)

-- Read the manifest the appliance actually uses, so the list cannot
-- drift from what is measured.
local uris, counts, order = {}, {}, {}
local f = io.open(os.getenv("CHAINS_JSON") or "scripts/daw/chains.json", "r")
local text = f:read("*a")
f:close()
for uri in text:gmatch('"uri":%s*"([^"]+)"') do
	if uri ~= "" then
		if not counts[uri] then
			counts[uri] = 0
			order[#order + 1] = uri
		end
		counts[uri] = counts[uri] + 1
	end
end

-- CPU seconds burned per wall second, read from /proc, not
-- AudioEngine:get_dsp_load(). The engine's own figure reported a
-- perfectly steady 0.00% while the process sat at 70% CPU visibly
-- processing audio - it is only meaningful when Ardour owns the
-- backend, and here PipeWire drives the graph. utime+stime cannot be
-- wrong about work that was done.
local CLK = 100        -- USER_HZ; getconf CLK_TCK is 100 on aarch64

local function cpu_seconds()
	local f = io.open("/proc/self/stat", "r")
	local line = f:read("*l")
	f:close()
	-- Fields after the comm field, which may itself contain spaces.
	local rest = line:match("%)%s+(.*)$")
	local n, utime, stime = 0, 0, 0
	for tok in rest:gmatch("%S+") do
		n = n + 1
		if n == 12 then utime = tonumber(tok) end
		if n == 13 then stime = tonumber(tok) end
	end
	return (utime + stime) / CLK
end

local function load_now()
	local c0, t0 = cpu_seconds(), os.time()
	sleep(settle)
	local dt = math.max(1, os.time() - t0)
	-- Percent of one core, which is the unit that matters: the audio
	-- callback runs on one thread and must finish inside its period.
	return (cpu_seconds() - c0) / dt * 100.0
end

local base = load_now()
print(string.format("BASE %.2f%%", base))

local results = {}
local prev = base
for _, uri in ipairs(order) do
	local added = 0
	for _ = 1, copies do
		local p = ARDOUR.LuaAPI.new_plugin(session, uri,
			ARDOUR.PluginType.LV2, "")
		if p and not p:isnil() then
			route:add_processor_by_index(p, -1, nil, true)
			added = added + 1
		end
	end
	if added > 0 then
		local now = load_now()
		local cost = (now - prev) / added
		prev = now
		results[#results + 1] = {
			uri = uri, each = cost, total = cost * counts[uri],
			n = counts[uri],
		}
		print(string.format("PLUGIN %6.2f each  x%d = %6.2f  %s",
			cost, counts[uri], cost * counts[uri], uri))
	else
		print("MISSING " .. uri)
	end
end

table.sort(results, function(a, b) return a.total > b.total end)
print("RANKED-BY-TOTAL-COST")
for i, r in ipairs(results) do
	print(string.format("%2d. %6.2f%%  (%.2f x%d)  %s",
		i, r.total, r.each, r.n, r.uri))
	if i >= 12 then break end
end
print(string.format("TOTAL %.2f%% with all %d inserts on one track",
	prev, #results))
session:request_stop(false, false, ARDOUR.TransportRequestSource.TRS_UI)
print("BENCH-DONE")
