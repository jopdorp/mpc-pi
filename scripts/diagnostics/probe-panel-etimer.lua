-- Sample the panel uPD78C10 event-counter registers during playback to
-- determine the real ECNT match period, which bounds how much timer
-- batching could ever be worth.
local function field(port_tag, field_name)
    return manager.machine.ioport.ports[port_tag].fields[field_name]
end

manager.machine.sound.ui_mute = true
manager.machine.video.speed_factor = 100000
emu.wait(24)
local button = field(":Y4", "Play Start")
button:set_value(1)
emu.wait(0.4)
button:clear_value()
emu.wait(2)

local sub = manager.machine.devices[":subcpu"]
local seen = {}
for i = 1, 40 do
    local ecnt = sub.state["ECNT"].value
    local etm0 = sub.state["ETM0"].value
    local etm1 = sub.state["ETM1"].value
    local etmm = sub.state["ETMM"] and sub.state["ETMM"].value or -1
    print(string.format("PANEL_ETIMER ECNT=%04x ETM0=%04x ETM1=%04x ETMM=%02x", ecnt, etm0, etm1, etmm))
    emu.wait(0.05)
end
manager.machine:exit()
