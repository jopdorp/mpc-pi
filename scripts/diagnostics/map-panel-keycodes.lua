-- Derive the panel key-code table by pressing every key field in turn while
-- MAME_MPC_PANEL_TX_LOG is active. Each press emits 0x84 <code> and each
-- release 0x85 <code>, so the surrounding markers identify the field.
manager.machine.sound.ui_mute = true
manager.machine.video.speed_factor = 8000
emu.wait(24)
manager.machine.video.speed_factor = 1000
emu.wait(1)

local ports = manager.machine.ioport.ports
local names = {}
for tag, port in pairs(ports) do
    if tag:match("^:Y%d$") or tag:match("^:PB%d$") then
        for field_name, field in pairs(port.fields) do
            names[#names + 1] = { tag = tag, name = field_name, field = field }
        end
    end
end
table.sort(names, function(a, b)
    if a.tag ~= b.tag then return a.tag < b.tag end
    return a.name < b.name
end)

print(string.format("PANEL_KEYMAP_BEGIN count=%d", #names))
for _, entry in ipairs(names) do
    print(string.format("PANEL_KEYMAP_PRESS tag=%s name=%s", entry.tag, entry.name))
    entry.field:set_value(1)
    emu.wait(0.12)
    entry.field:clear_value()
    emu.wait(0.12)
    print(string.format("PANEL_KEYMAP_DONE tag=%s name=%s", entry.tag, entry.name))
end
print("PANEL_KEYMAP_END")
manager.machine:exit()
