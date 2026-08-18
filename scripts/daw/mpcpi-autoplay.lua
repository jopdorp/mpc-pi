-- Boot the MPC, then optionally keep the loaded project playing.
--
-- Why this exists: a disk in the drive is NOT a loaded project. The emulator
-- takes -flop and the MPC then has media available, but nothing has been read
-- into memory and no program is assigned - so every pad and every PLAY press
-- produces exactly nothing, which is what a real MPC2000XL does too. It looked
-- like a broken MIDI path for a long time and was an empty sampler.
--
-- Gated on MPCPI_AUTOPLAY so this is a TEST aid, not the instrument's
-- behaviour. An instrument that starts playing a demo beat on power-on would be
-- wrong; a test rig that does is exactly what is wanted while proving the audio
-- path.
--
--   MPCPI_AUTOPLAY=1        boot and hold PLAY START down every 15s
--   MPCPI_AUTOPLAY unset    boot and sit there, which is the appliance
--   MPCPI_AUTOPLAY_WARP=n   boot at n x speed (default 4000, i.e. as fast as
--                           the host manages) then drop back to real time
local function field(port_tag, field_name)
    local port = manager.machine.ioport.ports[port_tag]
    if not port then return nil end
    return port.fields[field_name]
end

local function press(button, duration)
    if not button then return false end
    button:set_value(1)
    emu.wait(duration or 0.4)
    button:clear_value()
    return true
end

-- Report every analog control and its value, and raise anything that looks
-- like a volume to maximum.
--
-- Why: the emulator renders SILENCE with a loaded project visibly playing -
-- :outputs captured 232,004 frames at peak 0. The sequencer runs, voices
-- trigger, nothing comes out. An MPC2000XL's MAIN VOLUME is a physical pot,
-- and a MAME analog port that nobody has touched sits at its default, which is
-- commonly zero. That produces exactly this: a working instrument at zero
-- volume, with nothing to see in any log.
--
-- Printing the inventory matters as much as setting it: if there is no volume
-- field at all, the silence is somewhere else and this rules it out.
local function raise_volumes()
    local found = 0
    for pname, port in pairs(manager.machine.ioport.ports) do
        for fname, f in pairs(port.fields) do
            local is_analog = false
            local ok = pcall(function() is_analog = f.is_analog end)
            if ok and is_analog then
                print(string.format("ANALOG %s / %s = %s (min %s max %s)",
                    pname, fname, tostring(f.user_value),
                    tostring(f.minvalue), tostring(f.maxvalue)))
                if fname:lower():find("vol") then
                    f.user_value = f.maxvalue
                    print(string.format("  -> raised %s to %s", fname,
                        tostring(f.maxvalue)))
                    found = found + 1
                end
            end
        end
    end
    print("MPCPI_VOLUMES_RAISED " .. found)
end

local autoplay = os.getenv("MPCPI_AUTOPLAY")
local warp = tonumber(os.getenv("MPCPI_AUTOPLAY_WARP") or "4000")

-- Boot fast and silently, then hand back real time. The MPC spends about
-- twenty seconds of emulated time getting to a usable screen; running that at
-- speed is the difference between an instrument that is ready and one that
-- makes you wait.
manager.machine.sound.ui_mute = true
manager.machine.video.speed_factor = warp
emu.wait(24)
manager.machine.video.speed_factor = 1000
emu.wait(0.5)
manager.machine.sound.ui_mute = false
print("MPCPI_BOOT_READY")
pcall(raise_volumes)

-- Export the MPC's own panel lamps, so the Maschine can show them.
--
-- The lamps are machine state, not controller state: FULL LEVEL and NOTE
-- REPEAT are toggles inside the MPC, and the hub only ever sends a keypress -
-- it never learns what the machine did with it. A lamp driven from the hub's
-- guess drifts the moment anything else changes the state, and a lying lamp on
-- an instrument is worse than a dark one.
--
-- No patch is needed: akai/mpc2000.cpp already drives these through
-- set_output(), so they are readable as ordinary MAME outputs. The names come
-- from the two HC259 latches there:
--
--   led0 After (NOTE REPEAT)   led8  Full Level    led12 Next Seq
--   led1 Record                led9  Bank D        led13 Bank A
--   led2 Undo Sq               led10 Bank B        led14 Bank C
--   led3 Play                  led11 Track Mute    led15 16 Levels
--   led4 Over Dub
--
-- Written to /dev/shm as one line of "name=0|1" pairs, the same shape and the
-- same place as the LCD export the hub already reads. Only on CHANGE: this
-- runs every frame and the file is on a tmpfs the hub polls.
local LAMPS = {
    after = "led0", record = "led1", undo = "led2", play = "led3",
    overdub = "led4", full_level = "led8", bank_d = "led9", bank_b = "led10",
    track_mute = "led11", next_seq = "led12", bank_a = "led13",
    bank_c = "led14", sixteen_levels = "led15",
}
local lamp_path = os.getenv("MAME_MPC_LAMP_EXPORT") or "/dev/shm/mpc-lamps"
local lamp_order = {}
for name in pairs(LAMPS) do lamp_order[#lamp_order + 1] = name end
table.sort(lamp_order)

local last_lamps = nil
local outputs = manager.machine.output

local function export_lamps()
    local parts = {}
    for _, name in ipairs(lamp_order) do
        local ok, v = pcall(function() return outputs:get_value(LAMPS[name]) end)
        parts[#parts + 1] = name .. "=" .. ((ok and v and v ~= 0) and "1" or "0")
    end
    local line = table.concat(parts, " ")
    if line == last_lamps then
        return
    end
    last_lamps = line
    local f = io.open(lamp_path, "w")
    if f then
        f:write(line .. "\n")
        f:close()
    end
end

emu.add_machine_frame_notifier(function() pcall(export_lamps) end)
print("MPCPI_LAMP_EXPORT " .. lamp_path)

if not autoplay then
    return
end

-- PLAY START rather than PLAY: it restarts from the top, so re-pressing it
-- keeps audio flowing even after the sequence ends.
local play = field(":Y4", "Play Start")
if not play then
    print("MPCPI_AUTOPLAY: no ':Y4' / 'Play Start' field on this machine")
    return
end
print("MPCPI_AUTOPLAY: holding PLAY START every 15s")
while true do
    press(play)
    emu.wait(15)
end
