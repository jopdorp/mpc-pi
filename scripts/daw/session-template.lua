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
local rate = tonumber(os.getenv("SESSION_RATE") or "48000")
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
step("select backend", function()
	local b = AudioEngine:set_backend("JACK/Pipewire", "", "")
	assert(b and not b:isnil(), "no JACK/Pipewire backend")
end)
step("create session", function()
	session = create_session(dir, name, rate)
	assert(session, "create_session returned nil")
end)
assert(session, "cannot continue without a session")

-- Track creation: the 9-argument form (Ardour 9 added trigger_visibility).
local function add_audio(nm, ins)
	local tl = session:new_audio_track(ins, 2, ARDOUR.RouteGroup(), 1, nm,
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

step("create individual-out tracks", function()
	-- The emulator exposes its eight individual outs as a separate node
	-- (MPC_OUTPUT_MODE=all); one mono track each so the MPC's drums can
	-- be mixed per voice group.
	for i = 1, 8 do
		tracks["MPC" .. i] = add_audio("MPC" .. i, 1)
	end
end)

step("create send buses", function()
	for _, nm in ipairs({ "FX A", "FX B" }) do
		local bl = session:new_audio_route(2, 2, ARDOUR.RouteGroup(), 1, nm,
			ARDOUR.PresentationInfo.Flag.AudioBus,
			ARDOUR.PresentationInfo.max_order)
		assert(bl:size() > 0, "no bus for " .. nm)
		tracks[nm] = bl:front()
	end
end)

local function add_plugin(route, uri, position)
	local p = ARDOUR.LuaAPI.new_plugin(session, uri, ARDOUR.PluginType.LV2, "")
	if not p or p:isnil() then
		return nil
	end
	route:add_processor_by_index(p, position or -1, nil, true)
	return p
end

step("insert send-bus effects", function()
	-- a-Reverb and a-Delay ship inside Ardour, so the send buses work on
	-- a bare install with nothing else present.
	assert(add_plugin(tracks["FX A"], "urn:ardour:a-reverb"),
		"a-reverb missing")
	assert(add_plugin(tracks["FX B"], "urn:ardour:a-delay"),
		"a-delay missing")
end)

step("insert channel chains", function()
	-- EQ on every input channel. LSP's parametric EQ covers hi-pass,
	-- lo-pass and shelves in one plugin; a-EQ is the fallback if the LSP
	-- set is not installed, so a bare Ardour still yields a usable desk.
	local eq_uris = {
		"http://lsp-plug.in/plugins/lv2/para_equalizer_x16_stereo",
		"urn:ardour:a-eq",
	}
	for _, nm in ipairs({ "GTR1", "GTR2", "MIC", "AUX" }) do
		local placed = false
		for _, uri in ipairs(eq_uris) do
			if add_plugin(tracks[nm], uri) then placed = true break end
		end
		assert(placed, "no EQ available for " .. nm)
	end
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
	for i = 1, math.min(8, #outs) do
		tracks["MPC" .. i]:input():audio(0):connect(outs[i])
	end
end)

step("save session", function()
	session:save_state("", false, false, false, false, false)
end)

print("TEMPLATE-SUMMARY-BEGIN")
for _, line in ipairs(results) do print(line) end
print("TEMPLATE-SUMMARY-END")

pcall(function()
	session:request_stop(false, false, ARDOUR.TransportRequestSource.TRS_UI)
end)
close_session()
