-- Read a list of candidate tempo addresses on a booted project, and dump
-- the LCD so the answer can be checked against the number the machine
-- itself is showing.
--
-- The narrowing half of scripts/diagnostics/find-mpc-tempo.lua: one project
-- gives sixteen addresses that happen to hold 860, a second project at
-- another tempo leaves exactly the ones that mean it.
--
--   MPC_TEMPO_ADDRS=006541,007a59,... (hex, comma separated)
-- MPC_TEMPO_TAP_S=0.6 taps TAP TEMPO at that interval first, which SETS the
-- tempo to 60/interval - the one way to move it without navigating the
-- cursor onto the J: field. That is what actually narrows the list: a second
-- project might be at the same tempo as the first (both tutor beats are
-- 86.0), but nothing else in RAM has any reason to become 100.0 because a
-- key was tapped six times.
local mem = manager.machine.devices[":maincpu"].spaces["program"]

local function field(port_tag, field_name)
    local port = manager.machine.ioport.ports[port_tag]
    return port and port.fields[field_name] or nil
end

local list = os.getenv("MPC_TEMPO_ADDRS") or ""
local addrs = {}
for hex in list:gmatch("[^,%s]+") do
    addrs[#addrs + 1] = tonumber(hex, 16)
end
local tap_s = tonumber(os.getenv("MPC_TEMPO_TAP_S") or "") or nil
local taps = tonumber(os.getenv("MPC_TEMPO_TAPS") or "6")

manager.machine.sound.ui_mute = true
manager.machine.video.speed_factor = 4000
emu.wait(26)
manager.machine.video.speed_factor = 1000
emu.wait(1.0)

local function dump(label)
    for _, a in ipairs(addrs) do
        local le = mem:read_u8(a) + mem:read_u8(a + 1) * 0x100
        local be = mem:read_u8(a) * 0x100 + mem:read_u8(a + 1)
        print(string.format("TEMPO_READ %s %06x le=%d (%.1f) be=%d (%.1f)",
            label, a, le, le / 10, be, be / 10))
    end
end

dump("boot")

-- MPC_TEMPO_WHEEL=n moves the cursor onto the main screen's "J:" field and
-- turns the DATA wheel n detents. Tapping TAP TEMPO only moves the MASTER
-- tempo, and a project playing "86.0(SEQ)" is on the SEQUENCE's - measured:
-- six taps at 0.6 s took 0x00fee1 from 1200 to 998 and left every copy of
-- 860 exactly where it was. This edits the number the screen is showing.
local wheel = tonumber(os.getenv("MPC_TEMPO_WHEEL") or "") or nil
if wheel then
    local down = field(":Y2", "Down Arrow")
    local dial = manager.machine.ioport.ports[":DATAENTRY"]
    dial = dial and dial.fields["Dial"]
    if not down or not dial then
        print("TEMPO_READ no Down Arrow / DATAENTRY field")
    else
        down:set_value(1); emu.wait(0.2); down:clear_value(); emu.wait(0.5)
        for _ = 1, math.abs(wheel) do
            local step = wheel > 0 and 1 or -1
            dial.user_value = (dial.user_value or 0) + step
            emu.wait(0.12)
        end
        emu.wait(1.0)
        dump("wheel")
    end
end

if tap_s then
    local tap = field(":Y3", "Tap Tempo")
    if not tap then
        print("TEMPO_READ no Tap Tempo field")
    else
        print(string.format("TEMPO_TAPPING %d taps at %.3f s = %.1f BPM",
            taps, tap_s, 60.0 / tap_s))
        for i = 1, taps do
            tap:set_value(1)
            emu.wait(0.05)
            tap:clear_value()
            if i < taps then emu.wait(tap_s - 0.05) end
        end
        emu.wait(1.0)
        dump("tapped")
    end
end
print("TEMPO_READ_END")
