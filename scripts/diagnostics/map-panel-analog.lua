-- Characterize the panel's analog controls: the DATAENTRY quadrature encoder
-- and the VARIATION slider. Run with MAME_MPC_PANEL_TX_LOG=1 and correlate the
-- emitted messages with the markers printed here.
manager.machine.sound.ui_mute = true
manager.machine.video.speed_factor = 8000
emu.wait(24)
manager.machine.video.speed_factor = 1000
emu.wait(1)

local ports = manager.machine.ioport.ports
local dial = ports[":DATAENTRY"].fields["Data Entry"]
    or select(2, next(ports[":DATAENTRY"].fields))
local slider = ports[":VARIATION"] and select(2, next(ports[":VARIATION"].fields))

print("PANEL_ANALOG_BEGIN")

-- Encoder: sweep upward, then downward, in small steps so each detent shows.
print("PANEL_ANALOG_DIAL_UP")
for step = 1, 8 do
    dial:set_value((step * 4) & 0xff)
    emu.wait(0.15)
end
print("PANEL_ANALOG_DIAL_DOWN")
for step = 8, 1, -1 do
    dial:set_value((step * 4) & 0xff)
    emu.wait(0.15)
end
dial:clear_value()
emu.wait(0.3)

if slider then
    print("PANEL_ANALOG_SLIDER")
    for _, level in ipairs({ 0, 25, 50, 75, 100 }) do
        slider:set_value(level)
        emu.wait(0.3)
    end
    slider:clear_value()
    emu.wait(0.3)
end

print("PANEL_ANALOG_END")
manager.machine:exit()
