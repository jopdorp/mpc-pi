-- Publish the MPC sequencer's transport to shared memory for daw-ctl.
--
-- MIDI sync out is not emulated (docs/maschine-daw-design.md, "MIDI sync
-- out does not work"), so the DAW follows the MPC through this export
-- instead. It is strictly better than MIDI for our case: no serial link,
-- no jitter, and the value is read straight from the sequencer's own
-- state.
--
-- Signal (found by scripts/daw/find-transport-state.lua): the 32-bit
-- little-endian counter at 0x014188 (mirrored at 0x01418c) advances at
-- exactly 1000 units per second while the sequencer runs and is frozen
-- when it is stopped, i.e. elapsed playback milliseconds.
--
-- Output: $MPC_TRANSPORT_PATH (default /dev/shm/mpc-transport), one line:
--     <playing 0|1> <elapsed_ms> <emu_seconds> [bpm]
-- daw-ctl reads the file; the line is short enough that a reader never
-- sees a torn value in practice, and each field is independently sane.
-- The fourth field is only present when a tempo address is configured
-- (MPC_TEMPO_ADDR); readers must tolerate its absence, which is what the
-- appliance shipped with for months.
--
-- A MODULE, NOT A SCRIPT. This used to be a bare `while true` loop, which
-- is why it could never be loaded by the appliance: mpcpi-autoplay.lua is
-- already MAME's autoboot script and already has a poll loop of its own,
-- and a dofile of an infinite loop never comes back. So the file that
-- exported the transport was never the file that ran, and
-- /dev/shm/mpc-transport did not exist on the instrument - every punch
-- answered `no-transport`. Now it hands back a table:
--
--     local t = dofile("scripts/daw/transport-export.lua")
--     t.attach()            -- resolve the address space, seed the state
--     t.poll()              -- call from a frame notifier or a wait loop
--     t.run()               -- ...or let it own the thread, as before
local M = {}

M.ADDR = tonumber(os.getenv("MPC_TRANSPORT_ADDR") or "0x014188")
M.PATH = os.getenv("MPC_TRANSPORT_PATH") or "/dev/shm/mpc-transport"
M.HZ = tonumber(os.getenv("MPC_TRANSPORT_HZ") or "200")
-- Where the sequencer's tempo lives, when it is known. Unset means "do not
-- publish a tempo", and daw-ctl then keeps whatever it was configured
-- with. See scripts/daw/find-tempo-state.lua for how a value gets here.
M.TEMPO_ADDR = tonumber(os.getenv("MPC_TEMPO_ADDR") or "") or nil
-- Tempo is stored as tenths of a BPM ("J: 86.0" -> 860).
M.TEMPO_SCALE = tonumber(os.getenv("MPC_TEMPO_SCALE") or "10")

-- HOW LONG A FROZEN COUNTER STAYS "PLAYING".
--
-- The counter advances once a millisecond, so any poll faster than that
-- sees it move every time and "it moved recently" is the whole test. The
-- slack has to cover the poll interval, and the appliance polls this from
-- MAME's machine-frame notifier - about 80 Hz, i.e. 12.5 ms - rather than
-- from a 200 Hz wait loop. 50 ms covers a dropped frame or two without
-- making a real stop take visibly long to notice; daw-ctl only uses the
-- flag to roll Ardour behind the MPC, which is not a millisecond decision.
M.STALE_S = tonumber(os.getenv("MPC_TRANSPORT_STALE_S") or "0.05")

function M.now()
	if emu.time then
		local ok, t = pcall(emu.time)
		if ok and type(t) == "number" then return t end
	end
	return 0
end

function M.elapsed_ms()
	local a = M.ADDR
	return M.mem:read_u8(a)
		+ M.mem:read_u8(a + 1) * 0x100
		+ M.mem:read_u8(a + 2) * 0x10000
		+ M.mem:read_u8(a + 3) * 0x1000000
end

function M.tempo()
	if not M.TEMPO_ADDR then return nil end
	local a = M.TEMPO_ADDR
	local raw = M.mem:read_u8(a) + M.mem:read_u8(a + 1) * 0x100
	local bpm = raw / M.TEMPO_SCALE
	-- A tempo outside what the machine can be set to is a mis-read, and a
	-- mis-read tempo is worse than none at all: it silently resizes every
	-- bar daw-ctl quantises to. The MPC2000XL's range is 30.0-300.0.
	if bpm < 30.0 or bpm > 300.0 then return nil end
	return bpm
end

function M.attach()
	M.mem = manager.machine.devices[":maincpu"].spaces["program"]
	M.last_ms = M.elapsed_ms()
	M.last_change = M.now()
	M.last_key = nil
	print("MPC_TRANSPORT_EXPORT " .. M.PATH .. " addr=" ..
		string.format("%06x", M.ADDR) ..
		(M.TEMPO_ADDR and (" tempo=" .. string.format("%06x", M.TEMPO_ADDR))
		 or " tempo=none"))
	return M
end

-- One observation. Cheap enough for a frame notifier: four byte reads and,
-- while the sequencer is stopped, no write at all.
--
-- ONLY ON CHANGE, and the change is judged on (playing, elapsed_ms) rather
-- than on the whole line - the emulated timestamp moves every single poll,
-- so comparing the rendered line would write the file 80 times a second
-- forever, including all night with the instrument sitting idle.
function M.poll()
	local ms = M.elapsed_ms()
	local now = M.now()
	-- FORWARD ONLY counts as running. The counter is milliseconds elapsed
	-- since PLAY, so STOP puts it back to zero - measured on the appliance,
	-- 6206 to 30 across one press - and "it changed, so it is playing" read
	-- that reset as one more frame of playback. The instrument published a
	-- final `playing 1` at a position a second and a half in the past, which
	-- downstream is a take closed against a start that has not happened yet.
	-- PLAY START reboots the same counter, and there the very next frame
	-- moves forward again, so a stricter test costs one frame of latency at
	-- the top of a sequence and nothing else.
	if ms > M.last_ms then
		M.last_change = now
	end
	M.last_ms = ms
	local playing = (now - M.last_change) < M.STALE_S
	local key = (playing and "1" or "0") .. " " .. ms
	local bpm = M.tempo()
	if bpm then key = key .. " " .. bpm end
	if key == M.last_key then return false end
	M.last_key = key
	local file = io.open(M.PATH, "w")
	if not file then return false end
	file:write(string.format("%d %d %.6f%s\n", playing and 1 or 0, ms, now,
		bpm and string.format(" %.1f", bpm) or ""))
	file:close()
	return true
end

-- Own the thread, for the standalone harness (transport-export-run.sh).
function M.run(hz)
	local interval = 1.0 / (hz or M.HZ)
	while true do
		emu.wait(interval)
		pcall(M.poll)
	end
end

return M
