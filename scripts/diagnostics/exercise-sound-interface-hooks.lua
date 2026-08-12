manager.machine.sound.ui_mute = true
manager.machine.video.speed_factor = 4000
emu.wait(24)
manager.machine.video.speed_factor = 1000

local targets = {}
for tag, sound in pairs(manager.machine.sounds) do
	if sound.speaker or (sound.outputs > 0) then
		table.insert(targets, { tag = tag, sound = sound, seen = false, hooked = 0 })
	end
end
assert(#targets > 0, "no sound interfaces found")

local callbacks = 0
emu.register_sound_update(function(data)
	callbacks = callbacks + 1
	for _, target in ipairs(targets) do
		if data[target.tag] ~= nil then
			target.seen = true
			target.hooked = target.hooked + 1
		end
	end
end)

for _, target in ipairs(targets) do
	target.sound.hook = false
end
emu.wait(0.05)
for _, target in ipairs(targets) do
	assert(not target.seen, target.tag .. " appeared while its hook was disabled")
	target.sound.hook = true
end
emu.wait(0.05)
for _, target in ipairs(targets) do
	assert(target.seen, target.tag .. " did not appear after its hook was enabled")
	target.sound.hook = false
	target.before_disable = target.hooked
end
emu.wait(0.05)
for _, target in ipairs(targets) do
	assert(target.hooked == target.before_disable, target.tag .. " continued after its hook was disabled")
end

print(string.format("SOUND_INTERFACE_HOOKS_OK callbacks=%d interfaces=%d", callbacks, #targets))
manager.machine:exit()
