manager.machine.sound.ui_mute = true
manager.machine.video.speed_factor = 4000
emu.wait(24)
manager.machine.video.speed_factor = 1000
emu.wait(0.5)

manager.machine.sound.ui_mute = false
print("MPC_MIDI_INPUT_READY")
emu.wait(8)

manager.machine.sound.ui_mute = true
manager.machine:exit()
