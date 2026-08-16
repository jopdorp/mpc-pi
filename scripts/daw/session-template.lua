-- Build the appliance's Ardour session from nothing.
--
-- Creates the whole desk the panel expects, so daw-ctl and the Maschine
-- UI find a session whose strip order matches the columns they draw:
--
--   1 MPC        the emulator's stereo out
--   2 GTR1  3 GTR2  4 MIC          input channels, each with its chain
--   5 GTR1+ 6 GTR2+ 7 MIC+         overdub partners for the layer pairs
--   8 AUX                          spare input / returns
--   + MPC1..MPC8                   the emulator's individual outs
--   + FX A (reverb), FX B (delay)  send buses
--
-- Strip order is load-bearing: OSC addresses strips by position, and the
-- panel draws column N as strip N. Creating them in this order is what
-- makes "one number means the same thing everywhere" true.
--
--   luasession session-template.lua      (env SESSION_DIR, SESSION_NAME)

local dir = os.getenv("SESSION_DIR") or "/tmp/mpc-daw"
local name = os.getenv("SESSION_NAME") or "mpcpi"
local rate = tonumber(os.getenv("SESSION_RATE") or "44100")
local results = {}

local function say(t) io.write(t .. "\n") io.flush() end
local function step(label, fn)
	local ok, err = pcall(fn)
	results[#results + 1] = string.format("%s: %s%s",
		ok and "PASS" or "FAIL", label, ok and "" or (" -- " .. tostring(err)))
	say(results[#results])
	return ok
end

local session
-- Try backends in order of how much they prove. On the appliance
-- PipeWire is up and JACK is the real path; over an ssh session on the
-- board there is no user sound server at all, and insisting on JACK made
-- create_session return nil - which reads as a broken template rather
-- than a missing daemon. Dummy still builds the whole desk and still
-- instantiates every plugin, which is what this template is asserting.
-- Backend selection and the route-group argument both differ by version
-- and by host; they live in one module so the plugin probe cannot drift
-- from this file. See scripts/daw/ardour-compat.lua for why each choice
-- is made the way it is.
local compat = dofile(os.getenv("MPCPI_COMPAT")
	or "scripts/daw/ardour-compat.lua")
local backend_used

step("select backend and create session", function()
	backend_used = compat.use_backend()
	session = create_session(dir, name, rate)
	assert(session, "create_session returned nil on " .. backend_used ..
		" (is the sound server running?)")
end)
say("backend: " .. tostring(backend_used))
assert(session, "cannot continue without a session")

-- Track creation: the 9-argument form (Ardour 9 added trigger_visibility).
local ROUTE_GROUP = compat.route_group()

local function add_audio(nm, ins)
	local tl = session:new_audio_track(ins, 2, ROUTE_GROUP, 1, nm,
		ARDOUR.PresentationInfo.max_order, ARDOUR.TrackMode.Normal, true, true)
	assert(tl:size() > 0, "no track created for " .. nm)
	return tl:front()
end

local tracks = {}
step("create channel strips", function()
	for _, nm in ipairs({ "MPC", "GTR1", "GTR2", "MIC",
	                      "GTR1+", "GTR2+", "MIC+", "AUX" }) do
		tracks[nm] = add_audio(nm, 2)
	end
end)

-- The eight individual-out tracks exist to record the emulator's
-- separate voices, which is a deliberate act, not the normal state of
-- the instrument. Left active they are charged every callback whether
-- anything is recording or not: the graph's fixed cost measured 334us
-- at quantum 32 and 339us at 48 - near-constant, because it is
-- per-callback overhead rather than per-sample work, so a smaller
-- buffer does not shrink it, it just eats a larger share of a shorter
-- period. At quantum 32 that floor is 46% of the whole budget before a
-- single effect runs.
--
-- So they are created and then deactivated. Arming one for recording
-- reactivates it; the panel's LOOP page is where that happens.
-- MPC_INDIVIDUAL_ACTIVE=1 keeps the old behaviour for comparison.
-- Deactivating is not the same as not existing, and the difference is
-- the point of MPC_INDIVIDUAL_TRACKS=0. set_active(false) stops a route
-- processing, but its ports stay registered, and the graph is scheduled
-- per PORT, not per active route: PipeWire still prepares a buffer for
-- every one of them on every callback. Sixteen mono inputs and sixteen
-- outputs that are never read still cost their share of the fixed
-- per-callback price.
--
-- Set to 0 to leave them uncreated entirely. Strip order survives it:
-- the eight channel strips are created first and the panel addresses
-- only those by position.
local individual_active = os.getenv("MPC_INDIVIDUAL_ACTIVE") == "1"
local individual_tracks = os.getenv("MPC_INDIVIDUAL_TRACKS") ~= "0"

step("create individual-out tracks", function()
	if not individual_tracks then
		say("  skipped: MPC_INDIVIDUAL_TRACKS=0 (no ports created)")
		return
	end
	-- The emulator exposes its eight individual outs as a separate node
	-- (MPC_OUTPUT_MODE=all); one mono track each so the MPC's drums can
	-- be mixed per voice group.
	for i = 1, 8 do
		tracks["MPC" .. i] = add_audio("MPC" .. i, 1)
	end
	if not individual_active then
		local off = 0
		for i = 1, 8 do
			-- Two arguments, always: set_active(false) with one
			-- argument segfaults luasession outright.
			local ok = pcall(function()
				tracks["MPC" .. i]:set_active(false, nil)
			end)
			if ok then off = off + 1 end
		end
		say(string.format("  %d individual-out tracks deactivated "
			.. "(arm one to record it)", off))
	end
end)

step("create send buses", function()
	for _, nm in ipairs({ "FX A", "FX B" }) do
		local bl = session:new_audio_route(2, 2, ROUTE_GROUP, 1, nm,
			ARDOUR.PresentationInfo.Flag.AudioBus,
			ARDOUR.PresentationInfo.max_order)
		assert(bl:size() > 0, "no bus for " .. nm)
		tracks[nm] = bl:front()
	end
end)

-- Apply named parameters after instantiation.
--
-- Matched by LABEL, not index: LSP's limiter has 43 parameters and its
-- lookahead is number 15 today, which is exactly the kind of fact that
-- changes in a plugin release and then silently sets the wrong control
-- forever. A label that stops matching sets nothing and says so.
local function apply_params(proc, params)
	if not params then return end
	local ins = proc:to_insert()
	if ins:isnil() then return end
	local pi = ins:plugin(0)
	local want = {}
	for label, value in pairs(params) do
		want[label:lower()] = value
	end
	for n = 0, pi:parameter_count() - 1 do
		if pi:parameter_is_control(n) and pi:parameter_is_input(n) then
			local label = pi:parameter_label(n):lower()
			local v = want[label]
			if v ~= nil then
				-- Via the automation control, not
				-- LuaAPI.set_processor_param: that call returned without
				-- complaint and without effect - the session saved with
				-- the limiter's lookahead still at 5ms and still
				-- reporting 220 samples of latency. Setting the control
				-- is what actually moves the plugin AND makes Ardour
				-- recompute the latency.
				local ok = pcall(function()
					local ac = proc:to_automatable():automation_control(
						Evoral.Parameter(ARDOUR.AutomationType.PluginAutomation,
							0, n), false)
					assert(ac and not ac:isnil(), "no control")
					ac:set_value(v, PBD.GroupControlDisposition.NoGroup)
				end)
				if not ok then
					ARDOUR.LuaAPI.set_processor_param(proc, n, v)
				end
				say(string.format("  set %s = %s%s", label, tostring(v),
					ok and "" or " (fallback)"))
				want[label] = nil
			end
		end
	end
	for label in pairs(want) do
		say("  WARNING: no parameter labelled '" .. label .. "'")
	end
end

local function add_plugin(route, uri, position, params)
	local p = ARDOUR.LuaAPI.new_plugin(session, uri, ARDOUR.PluginType.LV2, "")
	if not p or p:isnil() then
		return nil
	end
	route:add_processor_by_index(p, position or -1, nil, true)
	apply_params(p, params)
	return p
end

-- Chains come from scripts/daw/chains.json, generated by chains.py, so
-- the Lua builder and the panel's FX page read the same definition and
-- cannot drift: the chips drawn on screen are literally this list.
-- A real scanner, not a pattern.
--
-- The first version matched slot objects with "{(.-)}", which stops at
-- the first closing brace. That worked until a slot gained a nested
-- "params" object, at which point the match ended inside it: the slot
-- was truncated, its uri never seen, and the desk built with 28 plugins
-- instead of 29 while reporting "0 unavailable". Nesting is exactly
-- what a pattern cannot do, so this walks the text.
local function read_chains(path)
	local f = io.open(path, "r")
	if not f then return nil end
	local text = f:read("*a")
	f:close()

	local pos = 1
	local function skip_ws()
		local _, e = text:find("^[ \t\r\n]*", pos)
		pos = e + 1
	end
	local parse_value

	local function parse_string()
		pos = pos + 1                       -- opening quote
		local out = {}
		while true do
			local c = text:sub(pos, pos)
			if c == "" or c == '"' then break end
			if c == "\\" then
				pos = pos + 1
				out[#out + 1] = text:sub(pos, pos)
			else
				out[#out + 1] = c
			end
			pos = pos + 1
		end
		pos = pos + 1                       -- closing quote
		return table.concat(out)
	end

	local function parse_object()
		pos = pos + 1
		local obj = {}
		skip_ws()
		if text:sub(pos, pos) == "}" then pos = pos + 1 return obj end
		while true do
			skip_ws()
			local key = parse_string()
			skip_ws()
			pos = pos + 1                   -- colon
			obj[key] = parse_value()
			skip_ws()
			local c = text:sub(pos, pos)
			pos = pos + 1
			if c ~= "," then break end      -- "}" or malformed
		end
		return obj
	end

	local function parse_array()
		pos = pos + 1
		local arr = {}
		skip_ws()
		if text:sub(pos, pos) == "]" then pos = pos + 1 return arr end
		while true do
			arr[#arr + 1] = parse_value()
			skip_ws()
			local c = text:sub(pos, pos)
			pos = pos + 1
			if c ~= "," then break end      -- "]" or malformed
		end
		return arr
	end

	parse_value = function()
		skip_ws()
		local c = text:sub(pos, pos)
		if c == '"' then return parse_string() end
		if c == "{" then return parse_object() end
		if c == "[" then return parse_array() end
		if text:find("^true", pos) then pos = pos + 4 return true end
		if text:find("^false", pos) then pos = pos + 5 return false end
		if text:find("^null", pos) then pos = pos + 4 return nil end
		local s2, e2 = text:find("^%-?%d+%.?%d*[eE]?[%-+]?%d*", pos)
		if s2 then
			local n = tonumber(text:sub(s2, e2))
			pos = e2 + 1
			return n
		end
		pos = pos + 1
		return nil
	end

	local root = parse_value()
	if type(root) ~= "table" then return nil end

	local out = {}
	for track, slots in pairs(root) do
		local list = {}
		for _, slot in ipairs(slots) do
			if slot.uri and slot.uri ~= "" then
				list[#list + 1] = slot
			end
		end
		out[track] = list
	end
	return out
end

local chain_path = os.getenv("CHAINS_JSON") or "scripts/daw/chains.json"
local chains = read_chains(chain_path)

step("insert chains from the manifest", function()
	assert(chains, "could not read " .. chain_path)
	local placed, skipped = 0, 0
	for track_name, slots in pairs(chains) do
		local route = tracks[track_name]
		if track_name == "MASTER" then
			route = session:master_out()
		end
		if route and not route:isnil() then
			for _, slot in ipairs(slots) do
				local p = add_plugin(route, slot.uri, nil, slot.params)
				if p then
					placed = placed + 1
					-- Bypassed slots are present but inactive: the
					-- player switches them in from the panel rather
					-- than waiting for a plugin to load mid-song.
					if slot.bypass then p:deactivate() end
				else
					skipped = skipped + 1
					say(string.format("  missing %s on %s", slot.uri,
						track_name))
				end
			end
		end
	end
	say(string.format("  placed %d plugins, %d unavailable", placed, skipped))
	assert(placed > 0, "no plugins placed at all")
end)

step("connect the emulator", function()
	-- MAME's native PipeWire node is named after the device tag, so the
	-- stereo out is ":speaker" and the individual outs ":outputs".
	local all = C.StringVector()
	AudioEngine:get_backend_ports("", ARDOUR.DataType("audio"),
		ARDOUR.PortFlags.IsOutput, all)
	local speaker, outs = {}, {}
	for i = 1, all:size() do
		local n = all:at(i - 1)
		if n:find("speaker") then speaker[#speaker + 1] = n end
		if n:find("outputs") then outs[#outs + 1] = n end
	end
	if #speaker >= 2 then
		for ch = 0, 1 do
			tracks["MPC"]:input():audio(ch):connect(speaker[ch + 1])
		end
	else
		say("  note: emulator not running, MPC input left unconnected")
	end
	if individual_tracks then
		for i = 1, math.min(8, #outs) do
			tracks["MPC" .. i]:input():audio(0):connect(outs[i])
		end
	end
end)

step("save session", function()
	session:save_state("", false, false, false, false, false)
end)

-- The live path's worst-case plugin latency, AFTER parameters are
-- applied. Two plugins have already got into this desk carrying large
-- latency while costing almost no CPU - a lookahead limiter at 220
-- samples and a linear-phase multiband clipper at 5745 - so the number
-- is reported on every build rather than discovered by someone playing
-- through it.
local worst, worst_name = 0, "-"
for r in session:get_routes():iter() do
	local i = 0
	while true do
		local proc = r:nth_processor(i)
		if proc:isnil() then break end
		if not proc:to_insert():isnil() and proc:active() then
			local lat = 0
			pcall(function() lat = proc:signal_latency() end)
			if lat > worst then
				worst, worst_name = lat, r:name() .. "/" .. proc:display_name()
			end
		end
		i = i + 1
	end
end
say(string.format("MAX-LATENCY %d samples (%s)", worst, worst_name))

print("TEMPLATE-SUMMARY-BEGIN")
for _, line in ipairs(results) do print(line) end
print("TEMPLATE-SUMMARY-END")

pcall(function()
	session:request_stop(false, false, ARDOUR.TransportRequestSource.TRS_UI)
end)
close_session()
