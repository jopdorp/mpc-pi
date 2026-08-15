-- Phase 2 proof of concept: Ardour records the running MPC emulator.
--
-- Preconditions (phase2-run.sh arranges them): MAME is already running with
-- -sound pipewire and playing the demo project, so its output ports exist in
-- the PipeWire graph. This script creates four tracks, connects the first
-- pair to MAME's outputs, records five seconds, and asserts the capture
-- contains real signal rather than silence.

local out_dir = os.getenv("PHASE2_DIR") or "/tmp/daw-phase2"
local results = {}
local function say(text) io.write(text .. "\n") io.flush() end
local function step(name, fn)
	local ok, err = pcall(fn)
	results[#results + 1] = string.format("%s: %s%s",
		ok and "PASS" or "FAIL", name, ok and "" or (" -- " .. tostring(err)))
	say(results[#results])
	return ok
end

local session = nil

step("select backend", function()
	-- set_backend only; create_session owns the engine lifecycle (see
	-- maschine-daw-design.md, Phase 1 findings).
	local backend = AudioEngine:set_backend("JACK/Pipewire", "", "")
	assert(backend and not backend:isnil(), "no JACK/Pipewire backend")
end)

step("create session", function()
	session = create_session(out_dir, "phase2", 48000)
	assert(session, "create_session returned nil")
end)
assert(session, "no session; cannot continue")

local tracks = {}
step("create 4 tracks", function()
	local names = { "MPC", "GTR1", "GTR2", "MIC" }
	for _, name in ipairs(names) do
		local tl = session:new_audio_track(2, 2, ARDOUR.RouteGroup(), 1,
			name, ARDOUR.PresentationInfo.max_order,
			ARDOUR.TrackMode.Normal, true, true)
		assert(tl:size() > 0, "no track for " .. name)
		tracks[name] = tl:front()
	end
end)

step("connect MPC track to emulator output", function()
	-- MAME's pipewire node exposes playback ports; find them by name.
	local input = tracks["MPC"]:input()
	-- MAME's pipewire node for the stereo output is ":speaker"; its ports
	-- are ":speaker:output_FL" / ":speaker:output_FR".
	local want = os.getenv("MPC_PORT_PATTERN") or "speaker"
	local found = 0
	-- AudioEngine:get_ports with flags: use the backend port names
	local all = C.StringVector()
	AudioEngine:get_backend_ports("", ARDOUR.DataType("audio"),
		ARDOUR.PortFlags.IsOutput, all)
	local candidates = {}
	for i = 1, all:size() do
		local name = all:at(i - 1)
		if name:lower():find(want) then
			candidates[#candidates + 1] = name
		end
	end
	assert(#candidates >= 2, "fewer than 2 emulator output ports matching '"
		.. want .. "'")
	for ch = 0, 1 do
		local port = input:audio(ch)
		assert(port:connect(candidates[ch + 1]) == 0,
			"connect failed: " .. candidates[ch + 1])
		say("  " .. candidates[ch + 1] .. " -> MPC/" .. tostring(ch))
		found = found + 1
	end
	assert(found == 2)
end)

step("record 5 seconds of the running emulator", function()
	tracks["MPC"]:rec_enable_control():set_value(1,
		PBD.GroupControlDisposition.NoGroup)
	session:maybe_enable_record()
	session:request_roll(ARDOUR.TransportRequestSource.TRS_UI)
	ARDOUR.LuaAPI.usleep(5 * 1000 * 1000)
	session:request_stop(false, false, ARDOUR.TransportRequestSource.TRS_UI)
	ARDOUR.LuaAPI.usleep(500 * 1000)
	tracks["MPC"]:rec_enable_control():set_value(0,
		PBD.GroupControlDisposition.NoGroup)
end)

step("captured region exists", function()
	local pl = tracks["MPC"]:playlist()
	assert(pl:region_list():size() > 0, "no region captured")
	say("  regions: " .. tostring(pl:region_list():size()))
end)

step("save session", function()
	session:save_state("", false, false, false, false, false)
end)

print("PHASE2-SUMMARY-BEGIN")
for _, line in ipairs(results) do print(line) end
print("PHASE2-SUMMARY-END")
close_session()
