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
press(field(":Y4", "Play Start"))
print("MPC_ASYNC_PRESENT_STRESS_BEGIN")
emu.wait(30)
print("MPC_ASYNC_PRESENT_STRESS_END")
manager.machine:exit()
