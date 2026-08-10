manager.machine.sound.ui_mute = true
manager.machine.video.speed_factor = 4000
emu.wait(24)
manager.machine.video.speed_factor = 1000
emu.wait(0.5)
local play = manager.machine.ioport.ports[":Y4"].fields["Play Start"]
play:set_value(1)
emu.wait(0.4)
play:clear_value()
emu.wait(60)
manager.machine:exit()
