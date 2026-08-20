-- Locate the sequencer's TEMPO in the MPC2000XL's RAM.
--
-- The companion to scripts/daw/find-transport-state.lua, which pinned the
-- elapsed-milliseconds counter at 0x014188. That counter fixes bar PHASE
-- exactly, because playback always starts on a bar line - but bar LENGTH
-- needs the tempo, and daw-ctl had no source for it at all. It ran on a
-- hardcoded 120 BPM while the projects on this appliance play at 86.0, so
-- every "bar" it quantised a punch to was 2.000 s against a bar that is
-- actually 2.791 s, and the loop it recorded could not line up with the
-- drums it was recorded over. Quantising to the wrong grid is worse than
-- not quantising: it looks deliberate.
--
-- Method: the main screen shows "J:  86.0", so the tempo is tenths of a BPM
-- and the value to look for is 860. Scan main RAM for every encoding that
-- could hold it, print the hits, and let a second project with a different
-- tempo pick the winner.
--
--   MPC_TEMPO_EXPECT=860 scripts/diagnostics/find-mpc-tempo.sh <image>
local function field(port_tag, field_name)
    local port = manager.machine.ioport.ports[port_tag]
    return port and port.fields[field_name] or nil
end

local function press(button, duration)
    if not button then return end
    button:set_value(1)
    emu.wait(duration or 0.4)
    button:clear_value()
end

local mem = manager.machine.devices[":maincpu"].spaces["program"]

local EXPECT = tonumber(os.getenv("MPC_TEMPO_EXPECT") or "860")
local SCAN_BEGIN = tonumber(os.getenv("SCAN_BEGIN") or "0")
local SCAN_END = tonumber(os.getenv("SCAN_END") or "524288")

manager.machine.sound.ui_mute = true
manager.machine.video.speed_factor = 4000
emu.wait(24)
manager.machine.video.speed_factor = 1000
emu.wait(0.5)

print("TEMPO_SCAN_BEGIN expect=" .. EXPECT)

-- STOPPED FIRST. A tempo does not depend on the transport, and scanning a
-- running machine only adds counters that happen to pass through 860.
local stopped = {}
for addr = SCAN_BEGIN, SCAN_END - 1 do stopped[addr] = mem:read_u8(addr) end

local lo = EXPECT % 256
local hi = math.floor(EXPECT / 256) % 256
local hits = 0
for addr = SCAN_BEGIN, SCAN_END - 2 do
    if stopped[addr] == lo and stopped[addr + 1] == hi then
        print(string.format("TEMPO_CANDIDATE_LE %06x", addr))
        hits = hits + 1
    end
    if stopped[addr] == hi and stopped[addr + 1] == lo then
        print(string.format("TEMPO_CANDIDATE_BE %06x", addr))
        hits = hits + 1
    end
end
print("TEMPO_CANDIDATES " .. hits)

-- AND THE ONES THAT SURVIVE PLAYBACK. A tempo is read by the sequencer and
-- must not move while it runs; anything that changes here is a coincidence
-- - a counter or a buffer that happened to hold 860 for one sample.
press(field(":Y4", "Play Start"))
emu.wait(3.0)
local stable = 0
for addr = SCAN_BEGIN, SCAN_END - 2 do
    if (stopped[addr] == lo and stopped[addr + 1] == hi) or
       (stopped[addr] == hi and stopped[addr + 1] == lo) then
        if mem:read_u8(addr) == stopped[addr] and
           mem:read_u8(addr + 1) == stopped[addr + 1] then
            print(string.format("TEMPO_STABLE %06x", addr))
            stable = stable + 1
        end
    end
end
print("TEMPO_SCAN_END stable=" .. stable)
