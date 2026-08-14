-- Boot the Logic fixture, start playback, then dump V53 program RAM and the
-- current translation table for offline disassembly of RAM-resident code.
-- MPC_RAM_DUMP names the output file (raw 512 KiB of linear 0x00000-0x7ffff).
local function field(port_tag, field_name)
    return manager.machine.ioport.ports[port_tag].fields[field_name]
end

local function press(button, duration)
    button:set_value(1)
    emu.wait(duration or 0.4)
    button:clear_value()
end

manager.machine.sound.ui_mute = true
manager.machine.video.speed_factor = 100000
emu.wait(24)
press(field(":Y4", "Play Start"))
emu.wait(6)

local cpu = manager.machine.devices[":maincpu"]
local mem = cpu.spaces["program"]
local path = os.getenv("MPC_RAM_DUMP") or "ram-dump.bin"
local out = io.open(path, "wb")
for address = 0, 0x7ffff, 4 do
    out:write(string.pack("<I4", mem:read_u32(address)))
end
out:close()
print(string.format("MPC_RAM_DUMP_DONE %s", path))
manager.machine:exit()
