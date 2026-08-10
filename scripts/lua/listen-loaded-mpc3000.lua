local function field(port_tag, field_name)
    return manager.machine.ioport.ports[port_tag].fields[field_name]
end

local function press(button, duration)
    button:set_value(1)
    emu.wait(duration or 0.4)
    button:clear_value()
end

-- TeleDisk floppy loading is intentionally slow. Accelerate only the load;
-- playback always runs at normal emulation speed.
manager.machine.video.speed_factor = 4000
emu.wait(110)
manager.machine.video.speed_factor = 1000
emu.wait(2)
press(field(":Y7", "Play Start"))
manager.machine:popmessage("Project loaded. Stop: K, Play Start: V")
