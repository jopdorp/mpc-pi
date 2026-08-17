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
