-- A take must become a region that repeats - on real Ardour, while the
-- transport keeps rolling.
--
-- This is the only test that can prove the thing the loop recorder is for,
-- because the obstacle it works around is a property of Ardour and not of
-- our arithmetic: a capture becomes a region only when the transport stops
-- (loop-ops.lua's header has the measurements). The pure self-test can
-- check the plan; only this can check that the audio ends up where the plan
-- says.
--
-- It records SILENCE on unconnected inputs under the Dummy backend, which
-- free-runs at wall-clock speed. What is being tested is region lifecycle,
-- not audio content, and Dummy keeps it off the appliance's real graph.
--
--   ARDOUR_BACKEND=Dummy luasession tests/integration/loop_records.lua

local results, failures = {}, 0
local function say(t) io.write(t .. "\n") io.flush() end
local function step(name, fn)
	local ok, err = pcall(fn)
	if not ok then failures = failures + 1 end
	results[#results + 1] = string.format("%s: %s%s", ok and "PASS" or "FAIL",
		name, ok and "" or (" -- " .. tostring(err)))
	say(results[#results])
	return ok
end

local dir = os.getenv("LOOPTEST_DIR") or "/tmp/mpcpi-looptest"
local src = os.getenv("MPCPI_SRC") or "."
local compat = dofile(src .. "/scripts/daw/ardour-compat.lua")
local loop = dofile(src .. "/scripts/daw/loop-ops.lua")
loop.compat = compat

local RATE = 48000
local BAR = RATE / 2                     -- 120 BPM 4/4 would be 2 s; half
                                         -- that keeps the test under 10 s
local session, lanes = nil, {}

AudioEngine:set_backend(os.getenv("ARDOUR_BACKEND") or "Dummy", "", "")

step("create session", function()
	session = create_session(dir, "looptest", RATE)
	assert(session, "create_session returned nil")
end)
assert(session, "no session; cannot continue")

step("create two loop lanes", function()
	for _, nm in ipairs({ "LOOP1", "LOOP2" }) do
		local tl = session:new_audio_track(2, 2, compat.route_group(), 1, nm,
			ARDOUR.PresentationInfo.max_order, ARDOUR.TrackMode.Normal,
			true, true)
		assert(tl:size() > 0, "no track for " .. nm)
		lanes[nm] = tl:front()
	end
	assert(loop.attach(session) == 0, "a fresh session has no regions to claim")
end)

local function regions(nm)
	local out = {}
	for r in lanes[nm]:playlist():region_list():iter() do
		out[#out + 1] = { name = r:name(), pos = r:position():samples(),
		                  len = r:length():samples(), opaque = r:opaque() }
	end
	table.sort(out, function(a, b) return a.pos < b.pos end)
	return out
end
local function arm(nm, v)
	lanes[nm]:rec_enable_control():set_value(v, PBD.GroupControlDisposition.NoGroup)
end
local function dump(nm)
	for _, r in ipairs(regions(nm)) do
		say(string.format("    %s %-24s pos=%-9d len=%-7d opaque=%s", nm,
			r.name, r.pos, r.len, tostring(r.opaque)))
	end
end

step("roll, record-engaged, like the appliance does", function()
	session:cfg():set_external_sync(false)
	session:maybe_enable_record()
	session:request_roll(ARDOUR.TransportRequestSource.TRS_UI)
	for _ = 1, 40 do
		ARDOUR.LuaAPI.usleep(100 * 1000)
		if session:transport_rolling() then return end
	end
	error("transport never rolled")
end)

-- A take: punch in, play, and hand loop-ops the same line daw-ctl's engine
-- would put on the queue. apply() rather than the ops directly, so the wire
-- format is under test too.
local function take(nm, bars, hold_ms)
	arm(nm, 1)
	ARDOUR.LuaAPI.usleep((hold_ms or (bars * 500 + 150)) * 1000)
	local ok, err = loop.apply(string.format("finalize %s length %d", nm,
		bars * BAR))
	assert(ok, tostring(err))
end

local L1, L2 = 2 * BAR, 3 * BAR

step("first take on LOOP1 becomes exactly one region of the take's length",
	function()
		take("LOOP1", 2)
		local r = regions("LOOP1")
		dump("LOOP1")
		assert(#r == 1, "expected one region, got " .. #r)
		assert(r[1].len == L1, "take not fitted to the loop: " .. r[1].len)
		assert(r[1].opaque, "the base layer must be opaque")
		assert(session:transport_rolling(),
			"the transport must be rolling again after a punch-out")
	end)

step("the take repeats: copies land end to end, none on top of another",
	function()
		assert(loop.apply("repeat LOOP1 at 0 times 2"))
		local r = regions("LOOP1")
		dump("LOOP1")
		assert(#r == 3, "expected the take plus two copies, got " .. #r)
		for i = 2, 3 do
			assert(r[i].pos == r[1].pos + (i - 1) * L1,
				string.format("copy %d at %d, wanted %d", i - 1, r[i].pos,
					r[1].pos + (i - 1) * L1))
			assert(r[i].len == L1, "copy is not a loop long: " .. r[i].len)
			assert(r[i].name ~= r[1].name,
				"every repetition must be addressable; clone_region " ..
				"reuses the source's name")
		end
		-- and again from where it left off, not from the start
		assert(loop.apply("repeat LOOP1 at 0 times 1"))
		local r2 = regions("LOOP1")
		assert(#r2 == 4, "expected a fourth region")
		assert(r2[4].pos == r[1].pos + 3 * L1, "top-up overlapped itself")
	end)

step("a second lane loops on ITS OWN length, not LOOP1's", function()
	take("LOOP2", 3)
	assert(loop.apply("repeat LOOP2 at 0 times 2"))
	local r = regions("LOOP2")
	dump("LOOP2")
	assert(#r == 3, "expected the take plus two copies, got " .. #r)
	assert(r[1].len == L2, "LOOP2 take not fitted to three bars: " .. r[1].len)
	assert(r[2].pos - r[1].pos == L2, "LOOP2 repeats on LOOP1's length")
	assert(r[3].pos - r[2].pos == L2, "LOOP2 repeats on LOOP1's length")
	assert(L1 ~= L2, "the test is meaningless if the lengths match")
end)

step("an overdub layers onto the existing length instead of resizing it",
	function()
		local before = #regions("LOOP1")
		-- One bar of dub over a two-bar loop. daw-ctl sends the LOOP's
		-- length, not the take's, and the lane's registered length wins.
		take("LOOP1", 1)
		local r = regions("LOOP1")
		dump("LOOP1")
		assert(#r == before + 1, "the overdub did not arrive")
		local dub
		for _, x in ipairs(r) do if not x.opaque then dub = x end end
		assert(dub, "the overdub must be transparent or it mutes the loop " ..
			"underneath it")
		assert(dub.len <= L1, "the overdub outgrew the loop: " .. dub.len)
		-- Both layers must now repeat, each from its own anchor.
		local n = #regions("LOOP1")
		assert(loop.apply("repeat LOOP1 at 0 times 1"))
		assert(#regions("LOOP1") == n + 2,
			"a repeat must lay one copy of every layer")
	end)

step("a punch-out on one lane does not lose a take on another", function()
	-- The finalize stop closes the capture on EVERY recording lane, so a
	-- lane that was mid-take comes back in fragments. They must still
	-- become one loop of one length.
	arm("LOOP2", 1)
	ARDOUR.LuaAPI.usleep(600 * 1000)
	take("LOOP1", 1)                       -- LOOP1's stop splits LOOP2
	ARDOUR.LuaAPI.usleep(600 * 1000)
	local before = #regions("LOOP2")
	local ok, err = loop.apply(string.format("finalize LOOP2 length %d", L2))
	assert(ok, tostring(err))
	dump("LOOP2")
	local after = regions("LOOP2")
	assert(#after > before, "the fragmented take vanished")
	assert(loop.loops["LOOP2"].length == L2, "the lane's length changed")
end)

step("clear takes the lane off the timeline", function()
	assert(loop.apply("clear LOOP1"))
	local r = regions("LOOP1")
	assert(#r == 0, "a cleared lane left " .. #r .. " regions playing")
	assert(loop.loops["LOOP1"] == nil, "the lane is still registered")
end)

step("the transport survived every punch-out", function()
	assert(session:transport_rolling(), "the transport is stopped")
	local a = session:transport_sample()
	ARDOUR.LuaAPI.usleep(500 * 1000)
	assert(session:transport_sample() > a + RATE / 4,
		"the transport is not advancing")
end)

step("save", function()
	session:save_state("", false, false, false, false, false)
end)

pcall(function()
	session:disable_record(false, false)
	session:request_stop(false, false, ARDOUR.TransportRequestSource.TRS_UI)
end)
ARDOUR.LuaAPI.usleep(500 * 1000)

say("LOOPTEST-SUMMARY-BEGIN")
for _, line in ipairs(results) do say(line) end
say(string.format("LOOPTEST-SUMMARY-END failures=%d", failures))
close_session()
