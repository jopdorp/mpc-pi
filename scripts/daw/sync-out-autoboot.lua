-- Enable the MPC2000XL's MIDI-clock sync output headlessly, then play.
--
-- Navigation (MPC2000XL): Shift+9 opens MIDI/SYNC mode; the Sync screen's
-- "Out:" field is reached with the cursor arrows; the DATA wheel changes
-- OFF -> MIDI CLOCK. Verification is external: the harness watches the
-- MIDI out port for 0xF8 clock bytes once PLAY starts.
--
-- Env knobs so the harness can iterate the sequence without editing:
--   SYNCOUT_DOWNS   cursor Down presses before turning (default 1)
--   SYNCOUT_RIGHTS  cursor Right presses before turning (default 0)
--   SYNCOUT_DETENTS data-wheel increments (default 1)
local function field(port_tag, field_name)
    return manager.machine.ioport.ports[port_tag].fields[field_name]
end

local function press(button, duration)
    button:set_value(1)
    emu.wait(duration or 0.4)
    button:clear_value()
end

local downs = tonumber(os.getenv("SYNCOUT_DOWNS") or "1")
local rights = tonumber(os.getenv("SYNCOUT_RIGHTS") or "0")
local detents = tonumber(os.getenv("SYNCOUT_DETENTS") or "1")

local function snap(tag)
    -- LCD renders even with -video none; snapshots make the navigation
    -- verifiable from outside.
    manager.machine.video:snapshot()
    print("SYNCOUT_SNAP " .. tag)
end

manager.machine.sound.ui_mute = true
manager.machine.video.speed_factor = 4000
emu.wait(24)
manager.machine.video.speed_factor = 1000
emu.wait(0.5)

snap("main")

-- Shift+9 -> MIDI/SYNC mode
local shift = field(":Y0", "Shift")
shift:set_value(1)
emu.wait(0.3)
press(field(":Y0", "9 / MIDI/Sync"))
shift:clear_value()
emu.wait(1.0)
snap("mode")

local ups = tonumber(os.getenv("SYNCOUT_UPS") or "0")
for _ = 1, downs do press(field(":Y2", "Down Arrow")); emu.wait(0.3) end
for _ = 1, rights do press(field(":Y3", "Right Arrow")); emu.wait(0.3) end
for _ = 1, ups do press(field(":Y5", "Up Arrow")); emu.wait(0.3) end

-- Data wheel: quadrature encoder, ONE position unit per detent (the
-- map-panel-analog sweep: 32 units moved = 32 increment messages).
local dial = manager.machine.ioport.ports[":DATAENTRY"].fields["Data Entry"]
    or select(2, next(manager.machine.ioport.ports[":DATAENTRY"].fields))
for i = 1, detents do
    dial:set_value(i & 0xff)
    emu.wait(0.3)
end
print("SYNCOUT_DIAL_STEPPED " .. detents)
emu.wait(0.5)
snap("after-turn")

print("SYNCOUT_SETUP_DONE downs=" .. downs .. " rights=" .. rights ..
    " detents=" .. detents)

-- Back to main screen, then play forever.
press(field(":Y4", "Main Screen"))
emu.wait(1.0)
manager.machine.sound.ui_mute = false

-- SYNCOUT_TAP=1: count firmware writes to the SIO (MIDI UART) I/O windows.
-- Distinguishes "firmware never sends clock" from "UART/portmidi loses it".
local tap_counts = { a = 0, b = 0 }
-- Register writes seen per channel, keyed "offset=value", so the firmware's
-- actual UART programming (mode byte in particular: bit for internal BRG vs
-- external TRNCLK/RVCLK) is visible without a rebuild.
local reg_writes = { a = {}, b = {} }
if os.getenv("SYNCOUT_TAP") == "1" then
    local io_space = manager.machine.devices[":maincpu"].spaces["io"]
    io_space:install_write_tap(0x0180, 0x0187, "sio_a", function(offset, data, mask)
        tap_counts.a = tap_counts.a + 1
        local key = string.format("%d=%02x", offset - 0x0180, data & 0xff)
        reg_writes.a[key] = (reg_writes.a[key] or 0) + 1
    end)
    io_space:install_write_tap(0x01a0, 0x01a7, "sio_b", function(offset, data, mask)
        tap_counts.b = tap_counts.b + 1
        local key = string.format("%d=%02x", offset - 0x01a0, data & 0xff)
        reg_writes.b[key] = (reg_writes.b[key] or 0) + 1
    end)
    print("SYNCOUT_TAP_INSTALLED")
end

local function dump_regs()
    for _, ch in ipairs({ "a", "b" }) do
        local parts = {}
        for key, count in pairs(reg_writes[ch]) do
            parts[#parts + 1] = key .. "x" .. count
        end
        table.sort(parts)
        print("SYNCOUT_REGS_" .. ch .. " " .. table.concat(parts, " "))
    end
end

print("SYNCOUT_PLAYBACK_BEGIN")
while true do
    press(field(":Y4", "Play Start"))
    emu.wait(2)
    snap("playing")
    -- Re-open MIDI/SYNC while the sequencer runs: proves whether the Sync
    -- Out setting survived leaving the screen.
    shift:set_value(1)
    emu.wait(0.3)
    press(field(":Y0", "9 / MIDI/Sync"))
    shift:clear_value()
    emu.wait(1.0)
    snap("sync-while-playing")
    press(field(":Y4", "Main Screen"))
    emu.wait(0.5)
    for _ = 1, 3 do
        emu.wait(5)
        if os.getenv("SYNCOUT_TAP") == "1" then
            print(string.format("SYNCOUT_TAP_COUNTS a=%d b=%d",
                tap_counts.a, tap_counts.b))
            dump_regs()
        end
    end
end
