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

-- --- what EDIT and WAVE send, on the audio a take just made ------------
--
-- The pure self-test checks the arithmetic and daw-ctl's checks the wire
-- format; only this can check that a split leaves two regions where one
-- was, that an undo puts them back, and that what daw-ctl reads is what
-- the playlist actually holds. Every one of these lines is what the panel
-- puts on the queue, verbatim.

local published = os.getenv("LOOPTEST_DIR") and
	(os.getenv("LOOPTEST_DIR") .. "-regions") or "/tmp/mpcpi-looptest-regions"

-- Read back what daw-ctl would read: the header, and one row per region.
local function read_published()
	assert(loop.publish(published), "publish failed")
	local f = assert(io.open(published, "r"), "nothing was published")
	local head, rows = nil, {}
	for line in f:lines() do
		if line:sub(1, 1) == "#" then
			head = {}
			local words = {}
			for w in line:sub(2):gmatch("%S+") do words[#words + 1] = w end
			for i = 1, #words - 1, 2 do head[words[i]] = words[i + 1] end
		else
			local c = {}
			for field in (line .. "\t"):gmatch("([^\t]*)\t") do
				c[#c + 1] = field
			end
			rows[#rows + 1] = { track = c[1], name = c[2],
				pos = tonumber(c[3]), len = tonumber(c[4]),
				fade_in = tonumber(c[5]), fade_out = tonumber(c[6]),
				gain = tonumber(c[7]) }
		end
	end
	f:close()
	return head, rows
end

local function rows_of(head_rows, track)
	local out = {}
	for _, r in ipairs(head_rows) do
		if r.track == track then out[#out + 1] = r end
	end
	table.sort(out, function(a, b) return a.pos < b.pos end)
	return out
end

step("the region list publishes what the playlist holds", function()
	local head, rows = read_published()
	assert(head, "no header line")
	assert(tonumber(head.rate) == RATE,
		"the header must carry ARDOUR's rate, got " .. tostring(head.rate))
	assert(tonumber(head.transport), "no transport position in the header")
	assert(tonumber(head.gen) > 0, "no generation counter")
	local mine = rows_of(rows, "LOOP2")
	local truth = regions("LOOP2")
	assert(#mine == #truth,
		string.format("published %d regions, the playlist holds %d",
			#mine, #truth))
	for i, r in ipairs(mine) do
		assert(r.name == truth[i].name, "published a different region")
		assert(r.pos == truth[i].pos, "published a different position")
		assert(r.len == truth[i].len, "published a different length")
	end
	-- ...and a second publish is a new generation, so a reader can tell a
	-- frame it has already seen from one it has not.
	local h2 = read_published()
	assert(tonumber(h2.gen) > tonumber(head.gen), "the generation stuck")
end)

step("SPLIT cuts one region into two, and UNDO puts it back", function()
	local before = regions("LOOP2")
	local target = before[1]
	local at = target.pos + math.floor(target.len / 2)
	assert(loop.apply(string.format("split LOOP2 %s %d", target.name, at)))
	local after = regions("LOOP2")
	dump("LOOP2")
	assert(#after == #before + 1,
		string.format("split made %d regions from %d", #after, #before))
	-- The halves must be ADDRESSABLE and CLAIMED, or the next finalize on
	-- this lane reads them as a fresh capture and swallows them.
	local _, rows = read_published()
	local names = {}
	for _, r in ipairs(rows_of(rows, "LOOP2")) do names[r.name] = true end
	local fresh = loop.unclaimed(loop.regions_of(loop.playlist_of("LOOP2")),
		loop.claimed["LOOP2"] or {})
	assert(#fresh == 0, "the split left " .. #fresh .. " unclaimed pieces")
	assert(loop.apply("undo"))
	local back = regions("LOOP2")
	assert(#back == #before,
		string.format("undo left %d regions, wanted %d", #back, #before))
	local found = false
	for _, r in ipairs(back) do if r.name == target.name then found = true end end
	assert(found, "undo did not put " .. target.name .. " back")
end)

step("DUPLICATE copies a region to the cursor, and UNDO removes the copy",
	function()
		local before = regions("LOOP2")
		local src = before[1]
		local at = src.pos + 20 * L2
		assert(loop.apply(string.format("duplicate LOOP2 %s %d",
			src.name, at)))
		local after = regions("LOOP2")
		assert(#after == #before + 1, "no copy appeared")
		local copy
		for _, r in ipairs(after) do if r.pos == at then copy = r end end
		assert(copy, "the copy did not land where it was asked to")
		assert(copy.name ~= src.name,
			"clone_region reuses its source's name; the copy must be " ..
			"addressable on its own")
		assert(copy.len == src.len, "the copy is a different length")
		assert(loop.apply("undo"))
		assert(#regions("LOOP2") == #before, "undo left the copy behind")
	end)

step("GAIN, FADES and NORM reach the audio and come back published",
	function()
		local target = regions("LOOP2")[1]
		assert(loop.apply(string.format("gain LOOP2 %s 0.25", target.name)))
		local _, rows = read_published()
		local r = rows_of(rows, "LOOP2")[1]
		assert(math.abs(r.gain - 0.25) < 0.001,
			"published gain " .. tostring(r.gain))
		assert(loop.apply(string.format("fadein LOOP2 %s 4410", target.name)))
		assert(loop.apply(string.format("fadeout LOOP2 %s 2205", target.name)))
		_, rows = read_published()
		r = rows_of(rows, "LOOP2")[1]
		assert(r.fade_in == 4410, "published fade in " .. tostring(r.fade_in))
		assert(r.fade_out == 2205, "published fade out " ..
			tostring(r.fade_out))
		-- NORM on a SILENT take must refuse rather than divide by its peak.
		-- The Dummy backend records silence, so this is the case the
		-- appliance hits first if nothing is plugged in.
		local ok = loop.apply(string.format("normalize LOOP2 %s", target.name))
		assert(not ok, "normalising silence must fail, not produce infinity")
		-- three undos: fadeout, fadein, gain - and the gain must come back
		for _ = 1, 3 do assert(loop.apply("undo")) end
		_, rows = read_published()
		r = rows_of(rows, "LOOP2")[1]
		assert(math.abs(r.gain - 1.0) < 0.001,
			"undo did not restore the gain: " .. tostring(r.gain))
		assert(r.fade_in ~= 4410, "undo did not restore the fade")
	end)

step("TRIM moves a region's bounds, and UNDO restores them", function()
	local target = regions("LOOP2")[1]
	local from = target.pos + math.floor(L2 / 4)
	local to = target.pos + math.floor(L2 / 2)
	assert(loop.apply(string.format("trim LOOP2 %s %d %d", target.name,
		from, to)))
	local _, rows = read_published()
	local r = rows_of(rows, "LOOP2")[1]
	assert(r.pos == from, "trim start landed at " .. r.pos .. " not " .. from)
	assert(r.len == to - from, "trim length is " .. r.len)
	assert(loop.apply("undo"))
	_, rows = read_published()
	r = rows_of(rows, "LOOP2")[1]
	assert(r.pos == target.pos and r.len == target.len,
		"undo did not restore the trim")
end)

step("REMOVE takes a region off the playlist, and UNDO puts it back",
	function()
		local before = regions("LOOP2")
		local doomed = before[#before]
		assert(loop.apply(string.format("remove LOOP2 %s", doomed.name)))
		assert(#regions("LOOP2") == #before - 1, "the region is still there")
		assert(loop.apply("undo"))
		local back = regions("LOOP2")
		assert(#back == #before, "undo did not put the region back")
		local found
		for _, r in ipairs(back) do
			if r.name == doomed.name then found = r end
		end
		assert(found, "undo put back something else")
		assert(found.pos == doomed.pos, "it came back in the wrong place")
	end)

step("an empty history refuses rather than pretending", function()
	while loop.apply("undo") do end
	local ok, err = loop.apply("undo")
	assert(not ok, "undo on an empty stack must fail")
	assert(tostring(err):find("nothing to undo"), tostring(err))
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
