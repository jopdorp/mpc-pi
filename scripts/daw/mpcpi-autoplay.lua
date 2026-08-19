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
local lamp_frames = 0

-- Resolve each lamp to an output PROXY once, at startup.
--
-- output:get_value(name) is deprecated and MAME warns on every single call.
-- At thirteen lamps per frame that was ~1000 warnings a second into the
-- journal - it buried everything else and wrote the SD card continuously for
-- no benefit. device.outputs[name] hands back an output_proxy, and :get() on
-- it is the supported path.
local lamp_proxy = {}

-- Prove the exporter is RUNNING, separately from whether the values move.
-- Without this a frozen file cannot be told from a notifier that fired once:
-- "bank_a=1 and nothing ever changes" reads identically either way.

local function export_lamps()
    local parts = {}
    for _, name in ipairs(lamp_order) do
        local p = lamp_proxy[name]
        local ok, v = false, nil
        if p then
            ok, v = pcall(function() return p:get() end)
        end
        parts[#parts + 1] = name .. "=" .. ((ok and v and v ~= 0) and "1" or "0")
    end
    lamp_frames = lamp_frames + 1
    local line = table.concat(parts, " ") .. " frames=" .. lamp_frames
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

-- KEEP THE TOKEN. add_machine_frame_notifier returns a subscription object,
-- and the notifier lives only as long as something references it. Discarding
-- it - `emu.add_machine_frame_notifier(fn)` as a bare statement - leaves the
-- callback alive exactly until Lua's next collection, which measured as
-- FIFTEEN frames: the lamp file was written a few times at boot and then froze
-- forever, showing bank A lit and nothing else ever changing. That reads
-- identically to "the machine never changes its lamps", which is why the
-- exported line carries a frame counter now.
--
-- Global on purpose: a local would go out of scope at the end of this script.
do
    local root = manager.machine.devices[":"]
    local resolved = 0
    for name, out in pairs(LAMPS) do
        local ok, proxy = pcall(function() return root.outputs[out] end)
        if ok and proxy then
            lamp_proxy[name] = proxy
            resolved = resolved + 1
        end
    end
    print("MPCPI_LAMP_PROXIES " .. resolved .. "/" .. #lamp_order)
end

mpcpi_lamp_notifier = emu.add_machine_frame_notifier(function()
    pcall(export_lamps)
end)
print("MPCPI_LAMP_EXPORT " .. lamp_path)

-- ===================================================================
-- MOUNT THE FLOPPY THE PANEL CHOSE.
--
-- The other half of the FILES browser. daw-ctl walks the tree, the panel
-- draws it, and the chosen path is published to /dev/shm/mpc-disk - and
-- until now nothing read that file, so the screen said "LOAD BEAT02.IMG"
-- and the drive did not change. Swapping media at runtime is MAME's side
-- of the fence and this is MAME's side: the autoboot script is already
-- running Lua inside the machine, so the loader is a poll loop here
-- rather than a patch to the emulator.
--
-- WHY A FILE AND NOT A SOCKET. Same reason daw-ctl uses a FIFO: either
-- side can restart without a reconnect dance, and the request survives
-- the gap. The panel writes a path, we load it, we write back what
-- happened - a request/response pair of two tiny files on tmpfs.
--
-- ANSWERING IS PART OF THE JOB. A load can fail - the file can be a
-- directory, the wrong size, or gone by the time we look - and a panel
-- that reports success unconditionally is worse than one that reports
-- nothing. The status file is what lets daw-ctl replace its optimistic
-- "LOAD X" with "LOADED X" or the emulator's own refusal.
local DISK_REQUEST = os.getenv("MPCPI_DISK_REQUEST") or "/dev/shm/mpc-disk"
local DISK_STATUS = os.getenv("MPCPI_DISK_STATUS") or "/dev/shm/mpc-disk-status"
-- WHERE THE CHOICE SURVIVES A REBOOT. /dev/shm is a tmpfs, so a disk
-- chosen on the panel is forgotten at power-off and the machine comes
-- back with whatever -flop the unit hardcodes. The appliance's standard
-- is that a reboot returns you to the same state, so daw-ctl also writes
-- the choice somewhere that persists and we seed from it at startup.
-- This costs one stat at boot and nothing afterwards.
local DISK_MEMORY = os.getenv("MPCPI_DISK_MEMORY")
    or ((os.getenv("MAME_RUNTIME_DIR") or "/var/lib/mpcpi") .. "/disk")

-- Find the drive by INSTANCE NAME, not by a hardcoded tag.
--
-- The tag is ":fdc:0" on this driver, but a slot's card device is named
-- by the slot machinery and a hardcoded tag is exactly the kind of thing
-- that silently resolves to nil after a MAME bump - and a nil here reads
-- as "the panel does nothing", which is the bug this whole function
-- exists to fix. -listmedia calls it "floppydisk"; that is the contract
-- the frontend already publishes, so match on it and say what we found.
local function find_drive()
    local images = manager.machine.images
    local want = os.getenv("MPCPI_DISK_DEVICE")
    if want then
        local ok, dev = pcall(function() return images[want] end)
        if ok and dev then return dev, want end
        print("MPCPI_DISK: no image device at " .. want)
    end
    for tag, img in pairs(images) do
        local ok, inst = pcall(function() return img.instance_name end)
        if ok and (inst == "floppydisk" or inst == "flop" or inst == "flop1") then
            return img, tag
        end
    end
    return nil, nil
end

local disk_drive, disk_tag = find_drive()
if disk_drive then
    print("MPCPI_DISK_DRIVE " .. tostring(disk_tag))
else
    print("MPCPI_DISK_DRIVE none - no floppy image device on this machine")
end

local function write_status(text)
    local f = io.open(DISK_STATUS, "w")
    if f then
        f:write(text .. "\n")
        f:close()
    end
end

local function read_path(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local line = f:read("*l")
    f:close()
    if not line then return nil end
    line = line:gsub("^%s+", ""):gsub("%s+$", "")
    if line == "" then return nil end
    return line
end

-- The last request we ACTED ON, successfully or not.
--
-- Remembering failures too is what keeps a bad path from being retried
-- at 4 Hz forever: the file cannot change unless the player picks
-- something else, and picking again is exactly when a retry is wanted.
local last_request = nil

local function mount(path, why)
    if not disk_drive then
        write_status("error no drive")
        return
    end
    -- Already in the drive. Loading it again would still cost a media
    -- change - the MPC re-reads the disk and loses its place - so a
    -- second press of ENTER on the disk you are already running is a
    -- no-op that says so rather than a reload.
    local ok, current = pcall(function() return disk_drive.filename end)
    if ok and current == path then
        write_status("ok " .. path)
        print("MPCPI_DISK already mounted: " .. path)
        return
    end
    -- EJECT, WAIT, INSERT. A real swap has a gap in it, and the guest's
    -- disk-change line is edge-triggered: loading straight over a
    -- mounted image can leave the MPC believing the old directory is
    -- still good. A quarter of a second of empty drive is what the
    -- machine would see from a hand.
    local had = (ok and current ~= "" and current) or nil
    pcall(function() disk_drive:unload() end)
    emu.wait(0.25)
    local raised, err = pcall(function() return disk_drive:load(path) end)
    -- load() answers nil on success and a message on failure; pcall's
    -- first return says whether it threw at all. Both are failures and
    -- both have to put the drive back.
    local failure = nil
    if not raised then
        failure = tostring(err)
    elseif err ~= nil then
        failure = tostring(err)
    end
    if failure then
        -- PUT BACK WHAT WAS IN THERE. The eject above already happened,
        -- so a refused image would otherwise leave the machine with an
        -- empty drive - strictly worse than before the player pressed
        -- anything, and not what they asked for. The browser lists
        -- anything disk-shaped on purpose (the emulator is the authority
        -- on what it can mount), which makes a refusal an ordinary
        -- outcome here rather than an exceptional one.
        if had then
            pcall(function() disk_drive:load(had) end)
        end
        write_status("error " .. failure)
        print("MPCPI_DISK refused " .. path .. ": " .. failure)
        return
    end
    write_status("ok " .. path)
    print("MPCPI_DISK mounted (" .. why .. "): " .. path)
end

-- Seed from the remembered choice, but only when there is no live
-- request: a request that is already sitting there is newer than memory
-- and is handled by the first poll below.
do
    local live = read_path(DISK_REQUEST)
    local remembered = read_path(DISK_MEMORY)
    if not live and remembered then
        last_request = remembered
        mount(remembered, "remembered")
    end
end

-- PLAY START rather than PLAY: it restarts from the top, so re-pressing it
-- keeps audio flowing even after the sequence ends.
--
-- Resolved unconditionally so the poll loop below can be one loop. It is
-- still only ever PRESSED when MPCPI_AUTOPLAY is set: this is a test aid,
-- and an instrument that starts playing on its own is wrong.
local play = field(":Y4", "Play Start")
if autoplay and not play then
    print("MPCPI_AUTOPLAY: no ':Y4' / 'Play Start' field on this machine")
end
if autoplay then
    print("MPCPI_AUTOPLAY: holding PLAY START every 15s")
end

-- ONE loop for both jobs. The disk poll has to run whether or not the
-- test aid is on - it is the appliance's own behaviour - and a second
-- coroutine to hold it would be a second thing that can stop.
local POLL_S = tonumber(os.getenv("MPCPI_DISK_POLL_S") or "0.25")
local since_play = 0
while true do
    local want = read_path(DISK_REQUEST)
    if want and want ~= last_request then
        last_request = want
        mount(want, "requested")
    end
    if autoplay and play then
        since_play = since_play + POLL_S
        if since_play >= 15 then
            since_play = 0
            press(play)
        end
    end
    emu.wait(POLL_S)
end
