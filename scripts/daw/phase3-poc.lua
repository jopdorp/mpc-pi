-- Phase 3 proof of concept: one loop lane on the linear timeline.
--
-- TriggerBox has no headless control path (see maschine-daw-design.md), so
-- the loop engine is: record on a track pair under external MIDI-clock
-- sync, then lay the captured region repeatedly ahead of the playhead with
-- playlist:add_region. This script proves every primitive the daw-ctl
-- daemon needs:
--   record base layer -> duplicate it N times ahead (loop) ->
--   record overdub layer while the base repetitions play ->
--   duplicate overdub -> undo (remove overdub regions) -> save.
--
-- phase3-run.sh arranges: MAME playing (audio source), mclk (MIDI clock,
-- delayed Start), port linking on the ready marker.

local sync_dir = os.getenv("PHASE3_DIR") or "/tmp/daw-phase3"
local results = {}
local function say(t) io.write(t .. "\n") io.flush() end
local function step(name, fn)
	local ok, err = pcall(fn)
	results[#results + 1] = string.format("%s: %s%s",
		ok and "PASS" or "FAIL", name, ok and "" or (" -- " .. tostring(err)))
	say(results[#results])
	return ok
end

local session = nil
local lanes = {}

step("select backend", function()
	local backend = AudioEngine:set_backend("JACK/Pipewire", "", "")
	assert(backend and not backend:isnil(), "no JACK/Pipewire backend")
end)

step("create session", function()
	session = create_session(sync_dir .. "/session", "phase3", 48000)
	assert(session, "create_session returned nil")
end)
assert(session, "no session; cannot continue")

step("create loop lane (track pair)", function()
	for _, name in ipairs({ "LOOP1", "LOOP1+" }) do
		local tl = session:new_audio_track(2, 2, ARDOUR.RouteGroup(), 1,
			name, ARDOUR.PresentationInfo.max_order,
			ARDOUR.TrackMode.Normal, true, true)
		assert(tl:size() > 0, "no track for " .. name)
		lanes[name] = tl:front()
	end
end)

step("connect lane inputs to emulator", function()
	-- PHASE3_INPUT=none records silence instead: isolates whether linking
	-- to the emulator's node is what stalls the slaved transport on record.
	if os.getenv("PHASE3_INPUT") == "none" then
		say("  (inputs left unconnected by request)")
		return
	end
	local all = C.StringVector()
	AudioEngine:get_backend_ports("", ARDOUR.DataType("audio"),
		ARDOUR.PortFlags.IsOutput, all)
	local candidates = {}
	for i = 1, all:size() do
		local name = all:at(i - 1)
		if name:lower():find("speaker") then
			candidates[#candidates + 1] = name
		end
	end
	assert(#candidates >= 2, "emulator :speaker ports not found")
	for _, lane in pairs(lanes) do
		for ch = 0, 1 do
			assert(lane:input():audio(ch):connect(candidates[ch + 1]) == 0,
				"connect failed")
		end
	end
end)

step("enable external sync", function()
	session:cfg():set_external_sync(true)
	assert(session:cfg():get_external_sync())
end)

local f = assert(io.open(sync_dir .. "/ready", "w"))
f:write("ready\n")
f:close()
say("  ready marker written; waiting for clock")

step("transport rolls under MIDI clock", function()
	for i = 1, 60 do
		ARDOUR.LuaAPI.usleep(500 * 1000)
		if session:transport_rolling() then return end
	end
	error("transport never rolled")
end)

step("transport position advances", function()
	local a = session:transport_sample()
	ARDOUR.LuaAPI.usleep(2 * 1000 * 1000)
	local b = session:transport_sample()
	say(string.format("  position %d -> %d (+%d in 2 s)", a, b, b - a))
	assert(b > a + 48000, "transport barely moving: +" .. (b - a))
end)

-- 120 BPM 4/4: one bar = 2 s = 96000 samples at 48 kHz.
local BAR = 96000

local function next_bar_sample()
	local now = session:transport_sample()
	return (math.floor(now / BAR) + 1) * BAR
end

local function wait_until(target)
	-- Bounded: a stalled transport must fail loudly, not hang the harness.
	local last, stall = -1, 0
	while session:transport_sample() < target do
		ARDOUR.LuaAPI.usleep(100 * 1000)
		local now = session:transport_sample()
		if now == last then
			stall = stall + 1
			if stall % 20 == 0 then
				say(string.format("  ...transport stuck at %d (want %d), rolling=%s",
					now, target, tostring(session:transport_rolling())))
			end
			if stall > 100 then -- 10 s frozen
				error(string.format("transport stalled at %d waiting for %d",
					now, target))
			end
		else
			stall = 0
		end
		last = now
	end
end

local function record_bars(lane, bars)
	-- Arm and capture whole bars; returns the captured region.
	local before = lane:playlist():region_list():size()
	lane:rec_enable_control():set_value(1, PBD.GroupControlDisposition.NoGroup)
	session:maybe_enable_record()
	local start = next_bar_sample()
	wait_until(start)
	-- Recording follows the rolling transport once the track is armed and
	-- the session record-enabled; stop capture by disarming at the bar line.
	wait_until(start + bars * BAR)
	lane:rec_enable_control():set_value(0, PBD.GroupControlDisposition.NoGroup)
	ARDOUR.LuaAPI.usleep(500 * 1000)
	local pl = lane:playlist()
	assert(pl:region_list():size() > before, "no new region captured")
	-- newest region = the one whose position is latest
	local newest, newest_pos = nil, -1
	for r in pl:region_list():iter() do
		local pos = r:position():samples()
		if pos > newest_pos then newest, newest_pos = r, pos end
	end
	return newest
end

-- PHASE3_WATCH=1: no record calls at all; just measure whether the slaved
-- transport keeps advancing with the emulator linked. Separates "the graph
-- itself degrades" from "a record call wedges the engine".
if os.getenv("PHASE3_WATCH") == "1" then
	step("watch-only: 5x2s advance", function()
		for i = 1, 5 do
			local a = session:transport_sample()
			ARDOUR.LuaAPI.usleep(2 * 1000 * 1000)
			local b = session:transport_sample()
			say(string.format("  window %d: +%d samples", i, b - a))
			assert(b > a + 40000, "advance collapsed in window " .. i)
		end
	end)
	print("PHASE3-SUMMARY-BEGIN")
	for _, line in ipairs(results) do print(line) end
	print("PHASE3-SUMMARY-END")
	close_session()
	return
end

local base_region = nil
step("record base layer (2 bars)", function()
	session:maybe_enable_record()
	base_region = record_bars(lanes["LOOP1"], 2)
	say(string.format("  region at %d len %d",
		base_region:position():samples(), base_region:length():samples()))
end)

step("loop base layer (lay 4 repetitions ahead)", function()
	local pl = lanes["LOOP1"]:playlist()
	local pos = base_region:position():samples()
	local len = base_region:length():samples()
	for i = 1, 4 do
		pl:add_region(base_region, Temporal.timepos_t(pos + i * len), 1, false)
	end
	local n = pl:region_list():size()
	say("  playlist regions: " .. n)
	assert(n >= 5, "expected 5+ regions after duplication, got " .. n)
end)

local over_region = nil
step("record overdub layer while base plays", function()
	over_region = record_bars(lanes["LOOP1+"], 2)
	say(string.format("  overdub at %d len %d",
		over_region:position():samples(), over_region:length():samples()))
end)

step("loop overdub layer (2 repetitions)", function()
	local pl = lanes["LOOP1+"]:playlist()
	local pos = over_region:position():samples()
	local len = over_region:length():samples()
	for i = 1, 2 do
		pl:add_region(over_region, Temporal.timepos_t(pos + i * len), 1, false)
	end
	assert(pl:region_list():size() >= 3)
end)

step("undo overdub (remove its regions)", function()
	local pl = lanes["LOOP1+"]:playlist()
	local doomed = {}
	for r in pl:region_list():iter() do doomed[#doomed + 1] = r end
	for _, r in ipairs(doomed) do pl:remove_region(r) end
	local n = pl:region_list():size()
	say("  regions after undo: " .. n)
	assert(n == 0, "overdub regions not removed")
end)

step("base layer survives undo", function()
	assert(lanes["LOOP1"]:playlist():region_list():size() >= 5)
end)

step("save session", function()
	session:save_state("", false, false, false, false, false)
end)

-- Disengage record and external sync before closing: close_session hangs
-- when the session is still record-engaged under a rolling external master.
pcall(function()
	session:disable_record(false, false)
	session:cfg():set_external_sync(false)
	session:request_stop(false, false, ARDOUR.TransportRequestSource.TRS_UI)
end)
ARDOUR.LuaAPI.usleep(500 * 1000)

print("PHASE3-SUMMARY-BEGIN")
for _, line in ipairs(results) do print(line) end
print("PHASE3-SUMMARY-END")
close_session()
