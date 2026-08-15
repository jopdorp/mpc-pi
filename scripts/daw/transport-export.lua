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
-- Output: $MPC_TRANSPORT_PATH (default /dev/shm/mpc-transport), rewritten
-- every poll as a single line:
--     <playing 0|1> <elapsed_ms> <emu_seconds>
-- daw-ctl reads the file; the line is short enough that a reader never
-- sees a torn value in practice, and each field is independently sane.
local ADDR = tonumber(os.getenv("MPC_TRANSPORT_ADDR") or "0x014188")
local PATH = os.getenv("MPC_TRANSPORT_PATH") or "/dev/shm/mpc-transport"
local HZ = tonumber(os.getenv("MPC_TRANSPORT_HZ") or "200")

local mem = manager.machine.devices[":maincpu"].spaces["program"]

local function elapsed_ms()
    return mem:read_u8(ADDR)
        + mem:read_u8(ADDR + 1) * 0x100
        + mem:read_u8(ADDR + 2) * 0x10000
        + mem:read_u8(ADDR + 3) * 0x1000000
end

local last_ms, last_change = elapsed_ms(), 0
local interval = 1.0 / HZ

print("MPC_TRANSPORT_EXPORT " .. PATH .. " addr=" ..
    string.format("%06x", ADDR) .. " hz=" .. HZ)

while true do
    emu.wait(interval)
    local ms = elapsed_ms()
    local now = emu.time and emu.time() or 0
    if ms ~= last_ms then
        last_ms = ms
        last_change = now
    end
    -- Playing = the counter moved recently. One poll of slack absorbs the
    -- gap between millisecond ticks at high poll rates.
    local playing = (now - last_change) < math.max(interval * 2, 0.01)
    local file = io.open(PATH, "w")
    if file then
        file:write(string.format("%d %d %.6f\n", playing and 1 or 0, ms, now))
        file:close()
    end
end
