-- Phase 2 autoboot: boot the loaded demo project fast, then keep the demo
-- song playing until the harness kills the emulator. PLAY START restarts
-- from the top, so re-pressing it every 15 s keeps audio flowing even after
-- the song ends.
local function field(port_tag, field_name)
    return manager.machine.ioport.ports[port_tag].fields[field_name]
end

local function press(button, duration)
    button:set_value(1)
    emu.wait(duration or 0.4)
    button:clear_value()
end

manager.machine.sound.ui_mute = true
manager.machine.video.speed_factor = 4000
emu.wait(24)
manager.machine.video.speed_factor = 1000
emu.wait(0.5)
manager.machine.sound.ui_mute = false
print("PHASE2_PLAYBACK_READY")
while true do
    press(field(":Y4", "Play Start"))
    emu.wait(15)
end
