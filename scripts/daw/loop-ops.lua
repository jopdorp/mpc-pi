-- Loop recording's region work: what happens to a playlist when a take closes.
--
-- Split out of session-governor.lua only so it can be TESTED. The governor
-- owns the session and the queue; this owns the playlist. Three callers:
--
--   session-governor.lua                          production
--   LOOP_OPS_SELFTEST=1 luasession loop-ops.lua   pure functions, no session
--   tests/integration/loop_records.sh             a real capture, real Ardour
--
-- THE CONSTRAINT THIS FILE IS SHAPED BY
--
-- Ardour turns a capture into a region only when the TRANSPORT STOPS
-- (Track::transport_stopped_wallclock consumes capture_info;
-- DiskWriter::finish_capture on punch-out is bookkeeping only). Measured
-- again here against Ardour 9.0.0 before any of this was written, because
-- the whole design hangs off it:
--
--   punch-out, keep rolling      0 regions, 2 s later; no wav on disk either
--   request_locate while rolling 0 regions, 1 s later (MustRoll, +4800)
--   request_stop                 the region appears after 10-50 ms
--
-- So a loop recorder on stock Ardour must stop the transport to close a
-- take, and the MPC - which is the clock the whole appliance agrees on -
-- keeps playing through it. What is done about that is finalize_stop()
-- below: stop, wait, LOCATE FORWARD OVER THE PAUSE, roll. The timeline
-- loses 65-110 ms of playback at each punch-out and then resumes in phase,
-- rather than falling permanently behind the drums.
--
-- The real fix is one Ardour patch exposing "finalize captures now" to Lua
-- (docs/maschine-daw-design.md, Phase 3 findings). Until the appliance
-- builds its own Ardour, this is the whole of the workaround, and every
-- surprise it stands on is written down where it is relied upon.
--
-- WHAT THE QUEUE SAYS. daw-ctl writes its loop engine's action strings
-- through VERBATIM - "finalize LOOP1 length 192000", "repeat LOOP1 at
-- 288000 times 2" - so there is one vocabulary, not two. This codebase has
-- shipped the same bug three times (dead knobs, dead punch verbs, a renamed
-- strip list) and every one of them was two halves agreeing about a wire
-- format that nobody checked end to end. The keyword words are IN the line;
-- ops read what they need by name and ignore the rest.

local M = {}

-- ====================================================================
-- Pure helpers. No session, no Ardour objects: these are what the
-- self-test can reach, and they are where the arithmetic lives.
-- ====================================================================

function M.words(line)
	local parts = {}
	for w in line:gmatch("%S+") do parts[#parts + 1] = w end
	return parts
end

-- "length 192000" -> { length = "192000" }.
--
-- Odd trailing words are dropped rather than shifting every key by one:
-- a truncated line must lose its last field, not silently rename them all.
function M.args(rest)
	local kw = {}
	for i = 1, #rest - 1, 2 do kw[rest[i]] = rest[i + 1] end
	return kw
end

-- Which of `names` this lane has not accounted for yet.
--
-- This is how a take is identified, and it is deliberately not "the newest
-- region" or "the one whose name matches": a finalize stop closes the
-- capture on EVERY recording lane, so a lane that was mid-take when its
-- neighbour punched out comes back as two regions (measured: LOOP2-1.1 plus
-- Take2_LOOP2-1.1, Ardour renames the second half). Everything the governor
-- has ever seen or laid is claimed, so "unclaimed" is exactly this take,
-- fragments and all, with no coordinate arithmetic to get wrong.
function M.unclaimed(regions, claimed)
	local out = {}
	for _, r in ipairs(regions) do
		if not claimed[r.name] then out[#out + 1] = r end
	end
	table.sort(out, function(a, b) return a.pos < b.pos end)
	return out
end

-- Cut a take down to the loop's length.
--
-- Only ever DOWN. The capture ends where the punch-out landed, which is
-- within a UI frame of the bar line but not on it, so a take is a few
-- milliseconds long or short. Short is silence at the end of each
-- repetition and inaudible; long is consecutive copies overlapping at the
-- loop point, which clicks. Extending is not on the table at all - there is
-- no audio past the end of the capture to extend into.
--
-- Returns what to keep (with the length each piece should end up), what to
-- drop, and the anchor every repetition counts from.
function M.fit(pieces, length)
	local anchor = pieces[1].pos
	local limit = anchor + length
	local keep, drop = {}, {}
	for _, p in ipairs(pieces) do
		if p.pos >= limit then
			drop[#drop + 1] = p
		else
			local want = math.min(p.len, limit - p.pos)
			keep[#keep + 1] = { name = p.name, pos = p.pos, len = want,
			                    trim = want < p.len }
		end
	end
	return keep, drop, anchor
end

-- Where the next `times` copies of one layer go.
--
-- Pure because laying a copy on top of one that is already there is the
-- single mistake here that a listening test catches and a unit test does
-- not: the same take twice at the same position is not a doubled region on
-- screen, it is one take at double level. daw_ctl.Lane.filled_to exists for
-- the same reason and got this wrong once already.
--
-- The layer's own fill mark drives it, so a layer recorded three loops
-- after the base one starts repeating three loops later - each layer counts
-- from its own anchor, and they share only the lane's length.
function M.plan(layer, length, times)
	local out = {}
	local filled = layer.filled_to
	for _ = 1, times do
		local offset = filled - layer.anchor
		local copy = math.floor(offset / length)
		for i, p in ipairs(layer.pieces) do
			out[#out + 1] = { index = i, name = p.name, copy = copy,
			                  pos = p.pos + offset }
		end
		filled = filled + length
	end
	return out, filled
end

-- The name a repetition gets.
--
-- clone_region hands back a region with the SAME NAME as its source -
-- measured: three clones of LOOP1-1.1 all came back called LOOP1-1.2 - so
-- without this the playlist holds several regions that region_by_name
-- cannot tell apart, the claimed set collapses to one entry, and the EDIT
-- page (which addresses regions by name) points at whichever one iterates
-- first.
function M.copy_name(name, copy)
	return string.format("%s@%d", name, copy)
end

-- ====================================================================
-- Session-bound. Everything below needs a real Ardour.
-- ====================================================================

function M.say(t) io.write(t .. "\n") io.flush() end

-- Ardour's time getters return timecnt/timepos objects rather than plain
-- numbers, and which one varies by call, so normalise here.
function M.samples_of(v)
	if type(v) == "number" then return v end
	if type(v) == "userdata" then
		local ok, n = pcall(function() return v:samples() end)
		if ok and type(n) == "number" then return n end
		local ok2, n2 = pcall(function() return v:val() end)
		if ok2 and type(n2) == "number" then return n2 end
	end
	return 0
end

function M.route_by_name(track)
	local r = M.session:route_by_name(track)
	if r and not r:isnil() then return r end
	return nil
end

function M.playlist_of(track)
	local r = M.route_by_name(track)
	if not r then return nil end
	local t = r:to_track()
	if not t or t:isnil() then return nil end
	return t:playlist()
end

function M.track_of(track)
	local r = M.route_by_name(track)
	assert(r, "no route " .. tostring(track))
	local t = r:to_track()
	assert(t and not t:isnil(), tostring(track) .. " is not a track")
	return t
end

-- Regions are addressed by name, which is what daw-ctl sees in the state
-- it renders; an index would break the moment anything is added.
function M.region_by_name(track, want)
	local pl = M.playlist_of(track)
	if not pl then return nil, nil end
	for r in pl:region_list():iter() do
		if r:name() == want then return r, pl end
	end
	return nil, pl
end

function M.regions_of(pl)
	local out = {}
	for r in pl:region_list():iter() do
		out[#out + 1] = { name = r:name(), pos = M.samples_of(r:position()),
		                  len = M.samples_of(r:length()), region = r }
	end
	return out
end

-- Open for business on this session.
--
-- Everything already on a playlist is claimed here, so the first take after
-- a governor restart is identified as what it is rather than swallowing the
-- session's existing regions. The loops themselves are NOT recovered: a
-- restarted governor keeps the audio that is already laid out and stops
-- topping it up. Rebuilding a loop from a saved playlist would mean
-- guessing which regions were repetitions of what, and guessing wrong lays
-- a second copy of a take on top of the first.
function M.attach(session)
	M.session = session
	M.rate = session:sample_rate()
	M.loops = {}                -- [track] = { length =, layers = { ... } }
	M.claimed = {}              -- [track] = { [region name] = true }
	-- What the last punch-out cost, in samples, so the next one can locate
	-- over its own pause instead of over a guess. See finalize_stop.
	M.roll_gap = math.floor(M.rate * 0.06)
	local n = 0
	for r in session:get_routes():iter() do
		local t = r:to_track()
		if t and not t:isnil() then
			local pl = t:playlist()
			if pl and not pl:isnil() then
				local claimed = {}
				for reg in pl:region_list():iter() do
					claimed[reg:name()] = true
					n = n + 1
				end
				M.claimed[r:name()] = claimed
			end
		end
	end
	return n
end

function M.claim(track, name)
	M.claimed[track] = M.claimed[track] or {}
	M.claimed[track][name] = true
end

-- A free-running sample counter that keeps counting while the transport is
-- stopped, which is exactly the quantity the locate below has to skip.
-- processed_samples is the engine's own, already in samples and needing no
-- rate conversion; the wall clock is the fallback for a backend that does
-- not advance it (and it is only ever used to measure a difference).
function M.engine_samples()
	local ok, n = pcall(function()
		return M.session:engine():processed_samples()
	end)
	if ok and type(n) == "number" and n > 0 then return n, "engine" end
	return math.floor(ARDOUR.LuaAPI.monotonic_time() * M.rate / 1000000), "clock"
end

-- STOP THE TRANSPORT TO CLOSE THE CAPTURE, AND PUT THE CLOCK BACK.
--
-- The sequence is not obvious and every step of it was measured:
--
--  * the region appears 10-50 ms after request_stop, but the transport is
--    still DeclickToStop at that moment and a locate then is REJECTED
--    outright ("bad transition, current state = DeclickToStop ... event =
--    Locate"), so wait for transport_stopped() as well as for the region;
--  * stopping while Recording disables the SESSION record-enable, and
--    daw-ctl believes it is still on and will not re-send its toggle (the
--    OSC path is a toggle with no setter), so put it back from here;
--  * locate to where the transport WOULD have been. The MPC never paused,
--    so a transport that resumes where it stopped is permanently late
--    against the drums, and every loop already laid out is late with it.
--
-- The locate target has to include the cost of the roll that has not
-- happened yet, which cannot be measured before the fact - so it is learned
-- from the previous punch-out (roll_gap) and re-measured every time. The
-- first take pays whatever the initial guess is off by, and the first take
-- is the one where nothing else is playing yet, so nothing is out of phase
-- with anything.
--
-- Residual error, honestly: the difference between the predicted and actual
-- roll, a few ms, applied once per punch-out to everything already on the
-- timeline. It accumulates over a set. The Ardour patch removes the stop
-- and with it all of this.
function M.finalize_stop(pl, before)
	if not M.session:transport_rolling() then
		-- Nothing to put back. Whatever stopped the transport already
		-- finalized the capture.
		return 0, 0
	end
	local at = M.session:transport_sample()
	local t0 = M.engine_samples()
	local recording = M.session:record_status()
	M.session:request_stop(false, false, ARDOUR.TransportRequestSource.TRS_UI)

	-- Two waits, not one. The transport must be fully stopped before the
	-- locate below is even legal, and the region has to have appeared before
	-- there is anything to find - but if it does not appear shortly after the
	-- stop it is not coming (nothing was armed, or the punch-in never
	-- reached Ardour), and standing here for two seconds with the transport
	-- halted is a far worse answer than reporting an empty take.
	local waited = 0
	while waited < 2000 and not M.session:transport_stopped() do
		ARDOUR.LuaAPI.usleep(2 * 1000)
		waited = waited + 2
	end
	local grace = 0
	while grace < 300 and pl:region_list():size() <= before do
		ARDOUR.LuaAPI.usleep(2 * 1000)
		grace = grace + 2
	end

	if recording ~= ARDOUR.Session.RecordState.Disabled then
		M.session:maybe_enable_record()
	end
	local stopped_for = M.engine_samples() - t0
	M.compat.locate(M.session, at + stopped_for + M.roll_gap, true)
	local rolling = 0
	while rolling < 2000 and not M.session:transport_rolling() do
		ARDOUR.LuaAPI.usleep(2 * 1000)
		rolling = rolling + 2
	end
	-- What the roll actually cost, for the next punch-out to locate over.
	M.roll_gap = math.max(0, (M.engine_samples() - t0) - stopped_for)
	return stopped_for, M.roll_gap
end

M.ops = {}

-- CLOSE A TAKE: turn what was just captured into a region that repeats.
--
--   finalize <track> length <samples>
--
-- The length is the musical one, in bars, decided by daw-ctl's bar
-- quantisation - and on an overdub it is the length of the take that
-- already owns the lane, so a two-bar dub cannot shorten a four-bar loop.
-- The lane's registered length wins over the wire either way.
function M.ops.finalize(track, ...)
	local kw = M.args({ ... })
	local want = tonumber(kw.length)
	assert(want and want > 0, "finalize needs a positive length")
	local t = M.track_of(track)
	local pl = t:playlist()

	-- Stop this lane writing from HERE rather than trusting the OSC
	-- punch-out to have landed first. daw-ctl sends "disarm" and this line
	-- in the same batch, over two different transports (UDP and this
	-- queue), and if the stop below beats the disarm the lane starts a
	-- second capture at the re-roll that nothing will ever close.
	t:rec_enable_control():set_value(0, PBD.GroupControlDisposition.NoGroup)

	local before = pl:region_list():size()
	local stopped_for, roll = M.finalize_stop(pl, before)

	local fresh = M.unclaimed(M.regions_of(pl), M.claimed[track] or {})
	assert(#fresh > 0, "nothing was captured on " .. track)
	for _, p in ipairs(fresh) do M.claim(track, p.name) end

	local lane = M.loops[track]
	local length = (lane and lane.length) or want
	local keep, drop, anchor = M.fit(fresh, length)
	for _, p in ipairs(drop) do pl:remove_region(p.region) end
	for _, p in ipairs(keep) do
		if p.trim then
			local r = M.region_by_name(track, p.name)
			r:trim_to(Temporal.timepos_t(p.pos), Temporal.timecnt_t(p.len))
		end
	end

	-- An overdub has to be HEARD OVER the loop underneath it, and two
	-- opaque regions on one playlist do not mix - the top layer masks the
	-- one below, so the base take would go silent under its own dub. There
	-- is no partner track to put it on: the desk has five LOOP strips and
	-- no LOOP1+ (session-template.lua), which is what the phase-3 proof of
	-- concept used.
	local layer = { pieces = {}, anchor = anchor, filled_to = anchor + length,
	                opaque = (lane == nil), laid = {} }
	for _, p in ipairs(keep) do
		layer.pieces[#layer.pieces + 1] = { name = p.name, pos = p.pos,
		                                    len = p.len }
		if not layer.opaque then
			local r = M.region_by_name(track, p.name)
			if r then r:set_opaque(false) end
		end
	end

	if lane then
		lane.layers[#lane.layers + 1] = layer
	else
		M.loops[track] = { length = length, layers = { layer } }
	end
	M.say(string.format(
		"GOVERNOR_TAKE %s length=%d anchor=%d pieces=%d layer=%d " ..
		"stopped=%dms roll=%dms",
		track, length, anchor, #layer.pieces, #M.loops[track].layers,
		math.floor(stopped_for * 1000 / M.rate),
		math.floor(roll * 1000 / M.rate)))
end

-- KEEP THE LANE SOUNDING: lay `times` more copies of every layer.
--
--   repeat <track> at <sample> times <n>
--
-- `at` IS DELIBERATELY IGNORED. It is a position in daw-ctl's coordinates,
-- which are the MPC's elapsed milliseconds; Ardour's transport is a
-- free-running counter that nothing ever locates to the MPC's zero, so the
-- two differ by an unknown constant. Repetition positions come from where
-- Ardour actually put the capture, which is the only place the audio is.
-- What daw-ctl contributes is the PACING - it emits this when its own
-- lookahead runs out, and both sides count in the same loop lengths off the
-- same hardware clock, so the counts stay in step.
M.ops["repeat"] = function(track, ...)
	local kw = M.args({ ... })
	local times = math.floor(tonumber(kw.times) or 0)
	local lane = M.loops[track]
	assert(lane, "no loop on " .. tostring(track))
	assert(times > 0, "repeat needs a positive count")
	-- A corrupt or hostile line must not fill the timeline with a million
	-- regions; two bars of lookahead is what the engine asks for.
	times = math.min(times, 8)
	local pl = M.playlist_of(track)
	for _, layer in ipairs(lane.layers) do
		local plan, filled = M.plan(layer, lane.length, times)
		for _, item in ipairs(plan) do
			local src = M.region_by_name(track, item.name)
			assert(src, "repetition source gone: " .. item.name)
			local copy = ARDOUR.RegionFactory.clone_region(src, false, false)
			assert(copy and not copy:isnil(), "clone_region failed")
			copy:set_name(M.copy_name(item.name, item.copy))
			pl:add_region(copy, Temporal.timepos_t(item.pos), 1, false)
			-- add_region can rename to keep the playlist unique; claim
			-- what the region ended up called, not what we asked for.
			copy:set_opaque(layer.opaque)
			layer.laid[#layer.laid + 1] = copy:name()
			M.claim(track, copy:name())
		end
		layer.filled_to = filled
	end
end

-- DISCARD THE LANE. UNDO and ERASE both land here through daw-ctl's engine.
--
-- Non-destructive in the sense the design doc means: the regions go, the
-- captured audio files stay on disk. Removing the repetitions is not
-- optional - a lane whose engine state says "idle" while four copies of the
-- take are still laid ahead of the playhead goes on playing with no button
-- left that means stop.
function M.ops.clear(track)
	local lane = M.loops[track]
	if not lane then return end
	local pl = M.playlist_of(track)
	assert(pl, "no playlist for " .. tostring(track))
	for _, layer in ipairs(lane.layers) do
		local doomed = {}
		for _, p in ipairs(layer.pieces) do doomed[#doomed + 1] = p.name end
		for _, n in ipairs(layer.laid) do doomed[#doomed + 1] = n end
		for _, n in ipairs(doomed) do
			local r = M.region_by_name(track, n)
			if r then pl:remove_region(r) end
			if M.claimed[track] then M.claimed[track][n] = nil end
		end
	end
	M.loops[track] = nil
end

-- ---- the region edits the EDIT and WAVE pages send -------------------

function M.ops.split(track, region, pos)
	local r, pl = M.region_by_name(track, region)
	assert(r and pl, "no region " .. tostring(region))
	pl:split_region(r, Temporal.timepos_t(tonumber(pos)))
end

function M.ops.move(track, region, pos)
	local r = M.region_by_name(track, region)
	assert(r, "no region " .. tostring(region))
	r:set_position(Temporal.timepos_t(tonumber(pos)))
end

function M.ops.fadein(track, region, len)
	local r = M.region_by_name(track, region)
	assert(r, "no region")
	local ar = r:to_audioregion()
	assert(ar and not ar:isnil(), "not an audio region")
	ar:set_fade_in_length(tonumber(len))
	ar:set_fade_in_active(true)
end

function M.ops.fadeout(track, region, len)
	local r = M.region_by_name(track, region)
	assert(r, "no region")
	local ar = r:to_audioregion()
	assert(ar and not ar:isnil(), "not an audio region")
	ar:set_fade_out_length(tonumber(len))
	ar:set_fade_out_active(true)
end

function M.ops.trim(track, region, from, to)
	local r = M.region_by_name(track, region)
	assert(r, "no region")
	r:trim_to(Temporal.timepos_t(tonumber(from)),
	          Temporal.timecnt_t(tonumber(to) - tonumber(from)))
end

function M.ops.gain(track, region, factor)
	local r = M.region_by_name(track, region)
	assert(r, "no region")
	local ar = r:to_audioregion()
	assert(ar and not ar:isnil(), "not an audio region")
	ar:set_scale_amplitude(tonumber(factor))
end

function M.ops.remove(track, region)
	local r, pl = M.region_by_name(track, region)
	assert(r and pl, "no region " .. tostring(region))
	pl:remove_region(r)
	if M.claimed[track] then M.claimed[track][region] = nil end
end

function M.ops.save()
	M.session:save_state("", false, false, false, false, false)
end

-- Apply one queue line. Returns ok, err - the caller counts and reports.
function M.apply(line)
	local parts = M.words(line)
	if #parts == 0 then return true end
	local fn = M.ops[parts[1]]
	if not fn then return false, "unknown op " .. parts[1] end
	return pcall(fn, table.unpack(parts, 2))
end

-- ====================================================================

function M.self_test()
	local function eq(a, b, what)
		assert(a == b, string.format("%s: %s ~= %s", what, tostring(a),
		                             tostring(b)))
	end

	-- the wire format daw-ctl's engine actually emits, word for word
	local p = M.words("finalize LOOP1 length 192000")
	eq(#p, 4, "words")
	eq(p[1], "finalize", "verb")
	eq(M.args({ table.unpack(p, 3) }).length, "192000", "finalize length")
	p = M.words("repeat LOOP2 at 288000 times 2")
	local kw = M.args({ table.unpack(p, 3) })
	eq(kw.times, "2", "repeat times")
	eq(kw.at, "288000", "repeat at")
	-- a truncated line loses its last field, it does not rename the rest
	eq(M.args({ "times", "2", "at" }).times, "2", "odd trailing word")
	eq(M.args({ "times", "2", "at" }).at, nil, "odd trailing word")

	-- a take is what this lane has not accounted for, in position order
	local claimed = { OLD = true }
	local fresh = M.unclaimed({
		{ name = "B", pos = 200, len = 50 },
		{ name = "OLD", pos = 0, len = 100 },
		{ name = "A", pos = 100, len = 100 },
	}, claimed)
	eq(#fresh, 2, "unclaimed count")
	eq(fresh[1].name, "A", "unclaimed order")
	eq(fresh[2].name, "B", "unclaimed order")

	-- fit: only ever shorter, and a piece past the end is dropped
	local keep, drop, anchor = M.fit({
		{ name = "A", pos = 1000, len = 900 },
		{ name = "B", pos = 1900, len = 400 },
		{ name = "C", pos = 2400, len = 100 },
	}, 1200)
	eq(anchor, 1000, "anchor")
	eq(#keep, 2, "kept")
	eq(#drop, 1, "dropped")
	eq(drop[1].name, "C", "dropped which")
	eq(keep[1].len, 900, "untouched piece")
	eq(keep[1].trim, false, "untouched piece is not trimmed")
	eq(keep[2].len, 300, "trimmed to the loop's end")
	eq(keep[2].trim, true, "trimmed piece says so")
	-- a take shorter than the loop is left alone: there is no audio to
	-- extend into, and the silence lands at the end of every repetition
	keep = M.fit({ { name = "A", pos = 0, len = 90 } }, 100)
	eq(keep[1].len, 90, "short take untouched")

	-- plan: copies go after the take, never on top of it
	local layer = { anchor = 1000, filled_to = 1200,
	                pieces = { { name = "A", pos = 1000 },
	                           { name = "B", pos = 1150 } } }
	local plan, filled = M.plan(layer, 200, 2)
	eq(#plan, 4, "two copies of a two-piece layer")
	eq(plan[1].pos, 1200, "first copy of the first piece")
	eq(plan[2].pos, 1350, "the second piece keeps its offset in the loop")
	eq(plan[1].copy, 1, "copy index")
	eq(plan[3].pos, 1400, "second copy")
	eq(plan[3].copy, 2, "copy index")
	eq(filled, 1600, "fill mark advanced by two lengths")
	-- ...and the next call carries on from there rather than repeating
	layer.filled_to = filled
	plan = M.plan(layer, 200, 1)
	eq(plan[1].pos, 1600, "no overlap with what was already laid")

	-- a layer recorded three loops after the base starts repeating there
	local dub = { anchor = 1600, filled_to = 1800,
	              pieces = { { name = "D", pos = 1600 } } }
	plan = M.plan(dub, 200, 1)
	eq(plan[1].pos, 1800, "an overdub counts from its own anchor")

	-- every repetition is addressable, which clone_region does not manage
	eq(M.copy_name("LOOP1-1.1", 3), "LOOP1-1.1@3", "copy name")

	print("loop-ops self-test PASS: wire format, take selection, fit, plan")
end

if os.getenv("LOOP_OPS_SELFTEST") == "1" then M.self_test() end

return M
