-- Throughput fixture: identical to live-logic-mpc2000xl.lua except that the
-- playback phase is requested at MPC_HEADROOM_SPEED_FACTOR instead of 100%.
-- Use it with MAME_TIMING_MASTER=video so MAME's own throttle, not the
-- PipeWire clock, bounds the run. The reported average speed is then the
-- achieved emulation throughput with sound and the LCD active.
local function field(port_tag, field_name)
    return manager.machine.ioport.ports[port_tag].fields[field_name]
end

local function press(button, duration)
    button:set_value(1)
    emu.wait(duration or 0.4)
    button:clear_value()
end

local requested = tonumber(os.getenv("MPC_HEADROOM_SPEED_FACTOR") or "") or 100000

manager.machine.sound.ui_mute = true
manager.machine.video.speed_factor = requested
emu.wait(24)
emu.wait(0.5)
print("MPC_HEADROOM_BEGIN")
manager.machine.sound.ui_mute = false
press(field(":Y4", "Play Start"))
emu.wait(18)
print("MPC_HEADROOM_END")
manager.machine.sound.ui_mute = true
manager.machine:exit()
