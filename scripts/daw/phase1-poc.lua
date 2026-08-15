-- Phase 1 proof of concept for docs/maschine-daw-design.md
--
-- Runs under Ardour's headless `luasession`. Exercises the exact operations
-- the design depends on and prints PASS/FAIL per step so the runner can gate
-- on them:
--   create session -> audio track -> connect input -> insert a-EQ ->
--   set parameter -> record -> stop -> play back -> save.
--
-- Everything is wrapped so one failing step reports and continues; the point
-- is to learn which bindings differ from the design's assumptions.

local out_dir = os.getenv("PHASE1_DIR") or "/tmp/daw-phase1"
local results = {}
-- stdout is block-buffered under luasession; without an explicit flush a
-- crash eats every line still in the buffer and the log lies about where
-- the failure happened.
local function say(text)
	io.write(text .. "\n")
	io.flush()
end
local function step(name, fn)
	local ok, err = pcall(fn)
	results[#results + 1] = string.format("%s: %s%s",
		ok and "PASS" or "FAIL", name, ok and "" or (" -- " .. tostring(err)))
	say(results[#results])
	return ok
end

local session = nil

local engine_ok = step("select audio backend", function()
	-- Set the backend but do NOT call AudioEngine:start(): create_session
	-- restarts the engine itself, and under pipewire-jack the first client's
	-- transport-master ports linger long enough that the restarted client's
	-- "MTC in" re-registration collides globally and manager init dies.
	-- Letting create_session own the engine lifecycle avoids the second
	-- client entirely. (Diagnosed with PIPEWIRE_DEBUG=3, 2026-08-15.)
	local want = os.getenv("PHASE1_BACKEND")
	local candidates = want and { want }
		or { "JACK/Pipewire", "PulseAudio", "Dummy" }
	local backend = nil
	for _, name in ipairs(candidates) do
		backend = AudioEngine:set_backend(name, "", "")
		if backend and not backend:isnil() then
			say("  backend: " .. name)
			break
		end
		backend = nil
	end
	assert(backend, "no usable audio backend among candidates")
end)

if not engine_ok then
	print("PHASE1-SUMMARY-BEGIN")
	for _, line in ipairs(results) do print(line) end
	print("PHASE1-SUMMARY-END")
	error("engine unavailable; aborting before session work")
end

step("create session", function()
	session = create_session(out_dir, "phase1", 48000)
	assert(session, "create_session returned nil")
end)

if not session then
	-- some builds expose new_session instead
	step("create session (new_session)", function()
		session = new_session(out_dir, "phase1")
		assert(session, "new_session returned nil")
	end)
end
assert(session, "no session; cannot continue")

local track = nil
step("create audio track", function()
	local tl = session:new_audio_track(1, 2, ARDOUR.RouteGroup(), 1, "GTR1",
		ARDOUR.PresentationInfo.max_order, ARDOUR.TrackMode.Normal, true)
	assert(tl:size() > 0, "no track returned")
	track = tl:front()
end)

step("connect physical input", function()
	local input = track:input()
	assert(input:n_ports():n_audio() > 0, "track has no audio input port")
	local port = input:audio(0)
	-- first physical capture port, whatever the backend calls it
	local phys = C.StringVector()
	AudioEngine:get_physical_inputs(ARDOUR.DataType("audio"), phys, 0, 0)
	assert(phys:size() > 0, "no physical capture ports")
	local target = phys:at(0)
	assert(port:connect(target) == 0, "connect failed: " .. target)
	say("  connected to " .. target)
end)

local eq = nil
step("insert a-EQ", function()
	eq = ARDOUR.LuaAPI.new_plugin(session, "urn:ardour:a-eq",
		ARDOUR.PluginType.LV2, "")
	assert(eq and not eq:isnil(), "a-eq not found under either URI")
	track:add_processor_by_index(eq, 0, nil, true)
end)

step("set plugin parameter", function()
	-- parameter 0 on a-eq is the low-shelf frequency; any settable index
	-- proves the mechanism
	local ok = ARDOUR.LuaAPI.set_processor_param(eq, 0, 200)
	assert(ok, "set_processor_param returned false")
end)

step("record 3 seconds", function()
	track:rec_enable_control():set_value(1,
		PBD.GroupControlDisposition.NoGroup)
	session:maybe_enable_record()
	session:request_roll(ARDOUR.TransportRequestSource.TRS_UI)
	ARDOUR.LuaAPI.usleep(3 * 1000 * 1000)
	session:request_stop(false, false, ARDOUR.TransportRequestSource.TRS_UI)
	ARDOUR.LuaAPI.usleep(500 * 1000)
	track:rec_enable_control():set_value(0,
		PBD.GroupControlDisposition.NoGroup)
end)

step("captured a region", function()
	local pl = track:playlist()
	assert(pl:region_list():size() > 0, "no region on the track playlist")
	say("  regions: " .. tostring(pl:region_list():size()))
end)

step("play back", function()
	session:goto_start()
	session:request_roll(ARDOUR.TransportRequestSource.TRS_UI)
	ARDOUR.LuaAPI.usleep(2 * 1000 * 1000)
	session:request_stop(false, false, ARDOUR.TransportRequestSource.TRS_UI)
end)

step("save session", function()
	session:save_state("", false, false, false, false, false)
end)

print("PHASE1-SUMMARY-BEGIN")
for _, line in ipairs(results) do print(line) end
print("PHASE1-SUMMARY-END")
close_session()
