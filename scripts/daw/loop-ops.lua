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
	M.fades = {}                -- what we set, where this Ardour cannot say
	-- A new session is a new history. The inverses below close over region
	-- objects from the session being replaced, and running one of those
	-- against a different session is the one way this stack can do harm.
	M.history = {}
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
-- The session record-enable as a small integer: 0 disabled, 1 engaged and
-- waiting, 2 actually writing. By COMPARISON with the enum rather than by
-- casting it - the numeric values are Ardour's business and have moved
-- between versions, and a wrong number here would tell daw-ctl to toggle
-- recording off at the worst possible moment.
function M.record_state()
	local ok, st = pcall(function() return M.session:record_status() end)
	if not ok then return 0 end
	if st == ARDOUR.Session.RecordState.Recording then return 2 end
	if st == ARDOUR.Session.RecordState.Enabled then return 1 end
	return 0
end

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

-- ---- the channel back: the region list ------------------------------
--
-- The queue carries edits DOWN. This carries the playlist UP, and it is
-- the only thing daw-ctl can see of the audio it is editing: until it
-- existed the EDIT page drew its bar grid, its snap and its cursor over an
-- empty timeline and there was nothing for SPLIT or the region keys to
-- select, so every audio-changing verb on EDIT and WAVE was blocked on it.
--
-- It mirrors the queue rather than inventing a second mechanism - one file
-- each way, write-then-rename so a reader never sees half a frame, and a
-- format that survives either side restarting with no reconnect dance.
--
--   # rate <n> transport <samples> gen <n>
--   <track>\t<region>\t<pos>\t<len>\t<fade in>\t<fade out>\t<gain>
--
-- THE HEADER IS NOT DECORATION. Positions here are in ARDOUR's timeline
-- and at ARDOUR's sample rate, and daw-ctl knows neither on its own: it
-- counts the MPC's elapsed milliseconds at whatever rate it was
-- constructed with, and Ardour's transport is a free-running counter that
-- nothing ever locates to the MPC's zero (see `repeat at` above, which
-- ignores daw-ctl's positions for exactly this reason). A cursor in the
-- wrong coordinates does not draw slightly wrong - it splits a region
-- somewhere else entirely.
--
-- Names, not indices, because editing renames: split makes two regions
-- neither side named, and clone_region reuses its source's name.
function M.publish(path)
	local f = io.open(path .. ".tmp", "w")
	if not f then return false end
	M.gen = (M.gen or 0) + 1
	-- THE TRANSPORT AND THE RECORD-ENABLE COME BACK UP THIS CHANNEL TOO.
	--
	-- Both are things daw-ctl can only ever have believed. It drives them
	-- through a send-only OSC client, and the session record-enable is a
	-- TOGGLE with no setter (/rec_enable_toggle, Lua's
	-- maybe_enable_record), so a belief that drifts from the truth turns
	-- every second press of REC into a silent disarm. Ardour drops the
	-- record-enable itself when the transport stops while recording -
	-- which is exactly what a punch-out does - so the drift is not
	-- hypothetical, it is the normal case.
	--
	-- Publishing what IS lets daw-ctl reconcile instead of guess. Same
	-- reasoning as the region gain feeding WAVE's knob: the channel closes
	-- when the answer comes back, not when the request goes out.
	f:write(string.format("# rate %d transport %d gen %d rolling %d rec %d\n",
		M.session:sample_rate(),
		M.samples_of(M.session:transport_sample()), M.gen,
		M.session:transport_rolling() and 1 or 0,
		M.record_state()))
	for r in M.session:get_routes():iter() do
		local t = r:to_track()
		if t and not t:isnil() then
			local pl = t:playlist()
			if pl and not pl:isnil() then
				for reg in pl:region_list():iter() do
					local ar = reg:to_audioregion()
					local gain, fi, fo = 1.0, 0, 0
					if ar and not ar:isnil() then
						gain = ar:scale_amplitude()
						-- NOT ar:fade_in_length(). Ardour 8 does not bind it
						-- and this used to die here, mid-file, on the
						-- appliance only - the moment the first take gave
						-- the publisher something to say.
						fi = M.fade_length(r:name(), reg:name(), ar, "in")
						fo = M.fade_length(r:name(), reg:name(), ar, "out")
					end
					f:write(string.format("%s\t%s\t%d\t%d\t%d\t%d\t%.4f\n",
						r:name(), reg:name(),
						M.samples_of(reg:position()),
						M.samples_of(reg:length()), fi, fo, gain))
				end
			end
		end
	end
	-- THE MARKERS RIDE THE SAME FILE, as three-field rows. Three fields
	-- and not seven on purpose: an older daw-ctl requires seven and skips
	-- anything shorter, so a governor that learned markers first cannot
	-- confuse a panel that has not. A tab inside a name would fake a
	-- fourth field, so it is flattened - names written by ops.mark never
	-- carry one, but an imported session's might.
	for l in M.session:locations():list():iter() do
		if M.is_marker(l) then
			f:write(string.format("mark\t%s\t%d\n",
				(l:name() or ""):gsub("\t", " "),
				M.samples_of(l:start())))
		end
	end
	f:close()
	return os.rename(path .. ".tmp", path) ~= nil
end

-- ---- the region edits the EDIT and WAVE pages send -------------------
--
-- UNDO IS OURS, BECAUSE ARDOUR'S IS NOT REACHABLE FROM LUA. Measured on
-- both the appliance's Ardour 8 and the build host's Ardour 9, with
-- scripts/daw/loop-ops.lua's own vocabulary against a real captured
-- region:
--
--   Session:begin_reversible_command    bound
--   Session:add_stateful_diff_command   bound
--   Session:commit_reversible_command   bound
--   Session:undo / redo / undo_depth    NOT BOUND - "attempt to call a
--                                       nil value (method 'undo')"
--
-- So a command can be pushed onto Ardour's history and nothing in this
-- process can ever pop it: wrapping the edits below in a reversible
-- command would produce an undo stack only a GUI could reach, on an
-- appliance that has no GUI. The stack below is therefore an INVERSE-OP
-- stack of our own - each edit records how to put things back - which is
-- the whole of what `UNDO` on the EDIT and WAVE pages means.
--
-- It covers REGION EDITS ONLY. finalize / repeat / clear are the loop
-- lifecycle and have their own undo already (daw-ctl's engine sends
-- `clear`, which is take-level ERASE and UNDO both); mixing them in here
-- would make one press of UNDO on the EDIT page throw away a whole take.

M.history = {}
M.HISTORY_MAX = 32

function M.remember(label, undo)
	M.history[#M.history + 1] = { label = label, undo = undo }
	-- Bounded, because every entry pins a region object alive. Losing the
	-- oldest edit is the right thing to lose.
	if #M.history > M.HISTORY_MAX then table.remove(M.history, 1) end
end

-- The names on a playlist right now, and what appeared since.
--
-- split_region does not tell you what it made, and a clone comes back
-- named after its source (see copy_name), so the only reliable way to
-- name the pieces an edit produced is to look before and after.
function M.snapshot(pl)
	local seen = {}
	for r in pl:region_list():iter() do seen[r:name()] = true end
	return seen
end

function M.added(pl, before)
	local out = {}
	for r in pl:region_list():iter() do
		if not before[r:name()] then out[#out + 1] = r end
	end
	return out
end

-- A name no region on this track holds yet.
function M.unique_name(track, base)
	local n = 1
	while M.region_by_name(track, M.copy_name(base, n)) do n = n + 1 end
	return M.copy_name(base, n)
end

-- The scale factor that puts `peak` at `target_db`.
--
-- Pure, so the self-test can check the arithmetic without an audio file -
-- and because AudioRegion:normalize is NOT BOUND in Lua on either Ardour
-- (measured, same probe as above), so normalising here means computing
-- the factor and setting the region's gain. maximum_amplitude reports the
-- SOURCE's peak, unscaled, so this is absolute rather than relative to
-- whatever gain the region already carries.
--
-- -0.5 dB rather than 0: a region normalised to exactly full scale
-- clips the moment anything downstream sums with it.
function M.norm_gain(peak, target_db)
	if not peak or peak <= 0 then return nil end
	return (10 ^ ((target_db or -0.5) / 20)) / peak
end

-- WHAT THE FADES ARE, ON AN ARDOUR THAT WILL NOT SAY.
--
-- Ardour 8 - the appliance's - binds no fade_in_length (see
-- ardour-compat.lua's fade_length for the measurements), so the only fade
-- lengths knowable there are the ones we set ourselves. They are kept here,
-- and the getter is preferred whenever this Ardour has one.
--
-- The gap this leaves is one line long and worth stating: on Ardour 8 a
-- region nobody has faded publishes 0 rather than the short default fade
-- Ardour gives a fresh capture, and the first undo of a fade restores 0
-- rather than that default. Both are a few dozen samples of crossfade at
-- one edge of one region.
M.fades = {}

function M.fade_key(track, region) return tostring(track) .. "\0" .. region end

function M.fade_length(track, region, ar, which)
	local live = M.compat and M.compat.fade_length(ar, which)
	if live then return live end
	local shadow = M.fades[M.fade_key(track, region)]
	return (shadow and shadow[which]) or 0
end

function M.note_fade(track, region, which, len)
	local key = M.fade_key(track, region)
	M.fades[key] = M.fades[key] or {}
	M.fades[key][which] = len
end

function M.audio_region(track, region)
	local r, pl = M.region_by_name(track, region)
	assert(r, "no region " .. tostring(region))
	local ar = r:to_audioregion()
	assert(ar and not ar:isnil(), tostring(region) .. " is not an audio region")
	return ar, r, pl
end

function M.ops.split(track, region, pos)
	local r, pl = M.region_by_name(track, region)
	assert(r and pl, "no region " .. tostring(region))
	local at = M.samples_of(r:position())
	local before = M.snapshot(pl)
	pl:split_region(r, Temporal.timepos_t(tonumber(pos)))
	local halves = M.added(pl, before)
	-- CLAIM THE PIECES. Everything a lane has accounted for is claimed
	-- (see unclaimed), and a half-region nobody claimed would be read as a
	-- fresh capture by the next finalize on this lane - so splitting a loop
	-- would make the next take swallow the pieces of the old one.
	for _, h in ipairs(halves) do M.claim(track, h:name()) end
	M.remember("split " .. region, function()
		for _, h in ipairs(halves) do
			pl:remove_region(h)
			if M.claimed[track] then M.claimed[track][h:name()] = nil end
		end
		pl:add_region(r, Temporal.timepos_t(at), 1, false)
		M.claim(track, r:name())
	end)
end

-- COPY THE REGION TO `pos`. What DUPLICATE sends.
function M.ops.duplicate(track, region, pos)
	local src, pl = M.region_by_name(track, region)
	assert(src and pl, "no region " .. tostring(region))
	local copy = ARDOUR.RegionFactory.clone_region(src, false, false)
	assert(copy and not copy:isnil(), "clone_region failed")
	-- clone_region hands back the SOURCE'S OWN NAME, so without this the
	-- playlist holds two regions region_by_name cannot tell apart and the
	-- EDIT page - which addresses regions by name - points at whichever
	-- one iterates first.
	copy:set_name(M.unique_name(track, region))
	pl:add_region(copy, Temporal.timepos_t(tonumber(pos)), 1, false)
	copy:set_opaque(src:opaque())
	M.claim(track, copy:name())
	M.remember("duplicate " .. region, function()
		pl:remove_region(copy)
		if M.claimed[track] then M.claimed[track][copy:name()] = nil end
	end)
	M.say("GOVERNOR_REGION duplicate " .. track .. " " .. copy:name())
end

function M.ops.move(track, region, pos)
	local r = M.region_by_name(track, region)
	assert(r, "no region " .. tostring(region))
	local was = M.samples_of(r:position())
	r:set_position(Temporal.timepos_t(tonumber(pos)))
	M.remember("move " .. region, function()
		r:set_position(Temporal.timepos_t(was))
	end)
end

function M.ops.fadein(track, region, len)
	local ar = M.audio_region(track, region)
	local was = M.fade_length(track, region, ar, "in")
	local active = ar:fade_in_active()
	local want = math.floor(tonumber(len))
	ar:set_fade_in_length(want)
	ar:set_fade_in_active(true)
	M.note_fade(track, region, "in", want)
	M.remember("fadein " .. region, function()
		ar:set_fade_in_length(was)
		ar:set_fade_in_active(active)
		M.note_fade(track, region, "in", was)
	end)
end

function M.ops.fadeout(track, region, len)
	local ar = M.audio_region(track, region)
	local was = M.fade_length(track, region, ar, "out")
	local active = ar:fade_out_active()
	local want = math.floor(tonumber(len))
	ar:set_fade_out_length(want)
	ar:set_fade_out_active(true)
	M.note_fade(track, region, "out", want)
	M.remember("fadeout " .. region, function()
		ar:set_fade_out_length(was)
		ar:set_fade_out_active(active)
		M.note_fade(track, region, "out", was)
	end)
end

function M.ops.trim(track, region, from, to)
	local r = M.region_by_name(track, region)
	assert(r, "no region " .. tostring(region))
	local was_pos = M.samples_of(r:position())
	local was_len = M.samples_of(r:length())
	r:trim_to(Temporal.timepos_t(tonumber(from)),
	          Temporal.timecnt_t(tonumber(to) - tonumber(from)))
	M.remember("trim " .. region, function()
		r:trim_to(Temporal.timepos_t(was_pos), Temporal.timecnt_t(was_len))
	end)
end

function M.ops.gain(track, region, factor)
	local ar = M.audio_region(track, region)
	local was = ar:scale_amplitude()
	ar:set_scale_amplitude(tonumber(factor))
	M.remember("gain " .. region, function() ar:set_scale_amplitude(was) end)
end

-- NORM on the WAVE page.
function M.ops.normalize(track, region, target_db)
	local ar = M.audio_region(track, region)
	local peak = ar:maximum_amplitude(nil)
	local want = M.norm_gain(peak, tonumber(target_db))
	assert(want, "nothing to normalise: " .. tostring(region) .. " is silent")
	local was = ar:scale_amplitude()
	ar:set_scale_amplitude(want)
	M.remember("normalize " .. region, function()
		ar:set_scale_amplitude(was)
	end)
	M.say(string.format("GOVERNOR_REGION normalize %s %s peak=%.4f gain=%.4f",
		track, region, peak, want))
end

function M.ops.remove(track, region)
	local r, pl = M.region_by_name(track, region)
	assert(r and pl, "no region " .. tostring(region))
	local at = M.samples_of(r:position())
	pl:remove_region(r)
	if M.claimed[track] then M.claimed[track][region] = nil end
	-- The Lua reference keeps the region alive after the playlist drops it,
	-- which is the only reason putting it back is possible at all.
	M.remember("remove " .. region, function()
		pl:add_region(r, Temporal.timepos_t(at), 1, false)
		M.claim(track, r:name())
	end)
end

-- Which locations the panel sees. Ardour keeps its own machinery in the
-- same list - the loop range, the punch range, the session extent - and
-- every one of them would read as a section to a panel that cannot see
-- flags. What is left is what a player put there: marks, and the
-- zero-length ranges the op below creates.
function M.is_marker(l)
	return not (l:is_session_range() or l:is_auto_loop()
		or l:is_auto_punch() or l:is_hidden())
end

-- DROP A SECTION MARKER where Ardour's playhead is right now.
--
--   mark
--
-- No position on the wire, deliberately. daw-ctl's playhead is the MPC's
-- clock and the two transports free-run against each other (see publish
-- above), so any position it sent would be in the wrong coordinates by
-- an unknown constant. The side that owns the timeline stamps the
-- marker, the same shape as normalize: send the verb, let the authority
-- decide the number, read the answer back off the published list.
--
-- A ZERO-LENGTH RANGE, not a mark, because a mark cannot be made from
-- here: neither Ardour 8.6 nor 9.0 binds Locations:add_mark or the
-- Location constructor to Lua (probed on the build host's 9, read in
-- 8.6's luabindings.cc), while add_range, set_name and remove are bound
-- on both. A range whose start is its end jumps and publishes exactly
-- like the mark it stands in for.
function M.ops.mark()
	local locs = M.session:locations()
	local at = M.samples_of(M.session:transport_sample())
	local names, count = {}, 0
	for l in locs:list():iter() do
		if M.is_marker(l) then
			names[l:name()] = true
			count = count + 1
		end
	end
	local n = count + 1
	while names["M" .. n] do n = n + 1 end
	local name = "M" .. n
	local loc = locs:add_range(Temporal.timepos_t(at),
		Temporal.timepos_t(at))
	assert(loc, "add_range refused")
	loc:set_name(name)
	-- THE DUPLICATE CHECK IS AGAINST WHERE IT LANDED, not where it was
	-- aimed. Ardour stores the new location in the BEATS domain whatever
	-- domain the position we pass is in (measured: aimed 5120, stored
	-- b410, read back 5125), so a sample compared before creating is
	-- never equal to anything and the guard it was in never fired. Two
	-- presses inside one tick would stack markers at one published
	-- position - a stack that reads as one marker PREV can never step
	-- past - so the second is taken back out and refused.
	local landed = math.floor(M.samples_of(loc:start()))
	for l in locs:list():iter() do
		if M.is_marker(l) and l:name() ~= name and
				math.floor(M.samples_of(l:start())) == landed then
			locs:remove(loc)
			error("marker already at " .. landed)
		end
	end
	M.remember("mark " .. name, function() locs:remove(loc) end)
	M.say("GOVERNOR_MARK " .. name .. " " .. landed)
end

-- Put the last region edit back. Takes no arguments: one stack, in the
-- order the edits happened, whichever page they came from.
function M.ops.undo()
	local entry = table.remove(M.history)
	assert(entry, "nothing to undo")
	-- The entry is already off the stack, so a failing inverse cannot be
	-- retried forever by a player holding the button down.
	entry.undo()
	M.say("GOVERNOR_UNDO " .. entry.label)
end

function M.ops.save()
	M.session:save_state("", false, false, false, false, false)
end

-- ---- ARDOUR FOLLOWS THE MPC ------------------------------------------
--
--   transport roll | stop
--
-- A capture needs a rolling transport, and NOTHING ROLLED IT. That is the
-- second half of why loop recording had never produced a take from the
-- panel: the punch reached Ardour, the lane rec-enabled, and the timeline
-- sat at sample 0 with nothing to write. The take used to verify the
-- region path was made by rolling the transport from a Lua console by
-- hand.
--
-- WHY IT LIVES HERE AND NOT ON THE OSC WIRE. This is not a user-facing
-- control - the transport belongs to the MPC and Ardour follows it, so
-- binding PLAY to Ardour would fight the one clock the system agrees on
-- (docs/daw-interaction.md, "Recording a loop"). What daw-ctl sends is a
-- consequence of what the emulator's transport export says. And it
-- belongs on this side because this side is the only one that can READ
-- Ardour's transport: osc.Client is send-only, so a roll sent over OSC is
-- a request nobody can confirm, while request_roll() here is guarded by
-- transport_rolling() and is therefore idempotent. finalize_stop() below
-- already owns stopping and re-rolling for a punch-out; one owner.
--
-- The locate that finalize_stop does is deliberately NOT done here. A
-- resume after the player stopped the MPC is not a hole punched in a
-- running timeline - nothing was playing across it - so there is no phase
-- to make up, and locating would only throw away where the loops are.
function M.ops.transport(what)
	if what == "roll" then
		if not M.session:transport_rolling() then
			M.session:request_roll(ARDOUR.TransportRequestSource.TRS_UI)
			M.say("GOVERNOR_TRANSPORT roll")
		end
	elseif what == "stop" then
		if M.session:transport_rolling() then
			M.session:request_stop(false, false,
				ARDOUR.TransportRequestSource.TRS_UI)
			M.say("GOVERNOR_TRANSPORT stop")
		end
	else
		error("transport takes roll or stop, not " .. tostring(what))
	end
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

	-- the EDIT and WAVE vocabulary is on the ops table, or daw-ctl's lines
	-- come back "unknown op" from a governor that looks perfectly healthy
	for _, verb in ipairs({ "split", "move", "fadein", "fadeout", "trim",
	                        "gain", "remove", "duplicate", "normalize",
	                        "undo", "save", "mark" }) do
		assert(type(M.ops[verb]) == "function", "no op " .. verb)
	end

	-- normalise is arithmetic, because Ardour binds no normalize() to Lua
	local g = M.norm_gain(0.5, -0.5)
	assert(math.abs(g - 1.8891) < 0.001, "norm gain " .. tostring(g))
	eq(M.norm_gain(1.0, 0.0), 1.0, "a full-scale region needs no gain")
	-- silence has no peak to normalise to, and 1/0 is not an answer
	eq(M.norm_gain(0, -0.5), nil, "silence")
	eq(M.norm_gain(nil, -0.5), nil, "no peak at all")

	-- the undo stack is LIFO, bounded, and drops the OLDEST
	M.history = {}
	local undone = {}
	for i = 1, 3 do
		M.remember("edit" .. i, function() undone[#undone + 1] = i end)
	end
	M.ops.undo()
	M.ops.undo()
	eq(#undone, 2, "two undos ran")
	eq(undone[1], 3, "undo is last-in-first-out")
	eq(undone[2], 2, "undo is last-in-first-out")
	eq(#M.history, 1, "the stack shrank")
	local ok = pcall(M.ops.undo)
	assert(ok, "the last entry must still be there")
	ok = pcall(M.ops.undo)
	assert(not ok, "an empty history must refuse rather than pretend")
	M.HISTORY_MAX = 2
	M.history = {}
	for i = 1, 4 do M.remember("e" .. i, function() end) end
	eq(#M.history, 2, "the stack is bounded")
	eq(M.history[1].label, "e3", "the OLDEST entry is the one dropped")
	M.HISTORY_MAX = 32

	print("loop-ops self-test PASS: wire format, take selection, fit, plan, " ..
	      "region vocabulary, normalise gain, undo stack")
end

if os.getenv("LOOP_OPS_SELFTEST") == "1" then M.self_test() end

return M
