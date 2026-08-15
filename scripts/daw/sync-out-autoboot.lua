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

manager.machine.sound.ui_mute = true
manager.machine.video.speed_factor = 4000
emu.wait(24)
manager.machine.video.speed_factor = 1000
emu.wait(0.5)

-- Shift+9 -> MIDI/SYNC mode
local shift = field(":Y0", "Shift")
shift:set_value(1)
emu.wait(0.3)
press(field(":Y0", "9 / MIDI/Sync"))
shift:clear_value()
emu.wait(1.0)

for _ = 1, downs do press(field(":Y2", "Down Arrow")); emu.wait(0.3) end
for _ = 1, rights do press(field(":Y3", "Right Arrow")); emu.wait(0.3) end

-- Data wheel: quadrature encoder, 4 position units per detent (see
-- map-panel-analog.lua).
local dial = manager.machine.ioport.ports[":DATAENTRY"].fields["Data Entry"]
    or select(2, next(manager.machine.ioport.ports[":DATAENTRY"].fields))
for i = 1, detents do
    dial:set_value((i * 4) & 0xff)
    emu.wait(0.3)
end
print("SYNCOUT_DIAL_STEPPED " .. detents)
emu.wait(0.5)

print("SYNCOUT_SETUP_DONE downs=" .. downs .. " rights=" .. rights ..
    " detents=" .. detents)

-- Back to main screen, then play forever.
press(field(":Y4", "Main Screen"))
emu.wait(1.0)
manager.machine.sound.ui_mute = false
print("SYNCOUT_PLAYBACK_BEGIN")
while true do
    press(field(":Y4", "Play Start"))
    emu.wait(15)
end
