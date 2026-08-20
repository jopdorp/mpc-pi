-- Drive the MPC2000XL's sampling flow from inside the machine.
--
-- MAME autoboot script. Every key press goes through manager.machine.ioport,
-- so the rig needs no window focus, no xdotool and no desktop at all - it is
-- the machine pressing its own buttons. Each stage is bracketed by a
-- "TESTRIG MARK <STAGE>" line on stdout so an external capture of :speaker can
-- be sliced per stage and measured.
--
-- Sequence: SHIFT+4 opens the record screen (which arms the sampler and starts
-- the input monitor), F6 records, F6 stops, Down + Pad 5 assigns the take,
-- F4 auditions it, F5 keeps it, MAIN SCREEN leaves, then Pad 5 twice plays it.
--
--   MAME_MPC_SAMPLE_STAGE_SECS  seconds to hold each measured stage (default 8)
--   MAME_MPC_SAMPLE_BOOT_SECS   seconds to wait for the boot (default 22)

local stage_secs = tonumber(os.getenv("MAME_MPC_SAMPLE_STAGE_SECS") or "") or 8
local boot_secs = tonumber(os.getenv("MAME_MPC_SAMPLE_BOOT_SECS") or "") or 22

local function field(name)
    for _, port in pairs(manager.machine.ioport.ports) do
        local f = port.fields[name]
        if f then return f end
    end
    return nil
end

local function tap(name, hold)
    local f = field(name)
    if not f then print("TESTRIG missing field: " .. name) return false end
    f:set_value(1); emu.wait(hold or 0.15); f:clear_value(); emu.wait(0.35)
    return true
end

local function chord(mod, name)
    local m, f = field(mod), field(name)
    if not m or not f then print("TESTRIG missing chord: " .. mod .. "+" .. name) return false end
    m:set_value(1); emu.wait(0.12)
    f:set_value(1); emu.wait(0.15); f:clear_value()
    emu.wait(0.12); m:clear_value(); emu.wait(0.35)
    return true
end

-- MAME's stdout is block-buffered when redirected, and once the sampler stops
-- logging the buffer can sit unflushed for seconds - long enough to put a
-- stage boundary in the wrong place entirely. So each mark is also appended to
-- its own file, opened and closed around the write, which the runner polls.
local marks_path = os.getenv("MAME_MPC_SAMPLE_MARKS")
local function mark(s)
    print("TESTRIG MARK " .. s)
    if marks_path then
        local f = io.open(marks_path, "a")
        if f then f:write(s .. "\n") f:close() end
    end
end

emu.wait(boot_secs)                 mark("BOOTED")
chord("Shift", "4 / Sample")        emu.wait(3)
mark("MONITOR_BEGIN")               emu.wait(stage_secs)  mark("MONITOR_END")
tap("Soft Key 6")                   emu.wait(1)
mark("RECORD_BEGIN")                emu.wait(stage_secs)  mark("RECORD_END")
tap("Soft Key 6")                   emu.wait(2)
tap("Down Arrow")                   emu.wait(1)
tap("Pad 5")                        emu.wait(2)
tap("Soft Key 4")                   emu.wait(1)
mark("PLAYBACK_BEGIN")              emu.wait(stage_secs)  mark("PLAYBACK_END")
tap("Soft Key 5")                   emu.wait(2)
tap("Main Screen")                  emu.wait(2)
mark("PAD_BEGIN")
tap("Pad 5")                        emu.wait(3)
tap("Pad 5")                        emu.wait(3)
mark("PAD_END")                     mark("DONE")
