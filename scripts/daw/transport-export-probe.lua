-- Boot the demo project, start playback, then run the transport export.
-- Used by transport-export-run.sh to verify the export end to end; the
-- appliance runs transport-export.lua directly alongside its own autoboot.
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
press(field(":Y4", "Play Start"))
emu.wait(0.5)
print("TRANSPORT_PROBE_PLAYING")

-- A module now, not a script: mpcpi-autoplay.lua needs to poll it from
-- its own loop, so the infinite loop moved into run(). See its header.
local export = dofile(os.getenv("MPC_TRANSPORT_EXPORT_LUA")
    or "scripts/daw/transport-export.lua")
export.attach()
export.run()
