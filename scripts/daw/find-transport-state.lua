-- Locate the sequencer's running position in the MPC2000XL's RAM.
--
-- The main screen shows "Now:BBB.BB.TT" (bar.beat.tick) and "J:  86.0"
-- (tempo). Those values live in main RAM; daw-ctl needs them exported so
-- the DAW's bar grid can track the MPC without any MIDI link (see
-- docs/maschine-daw-design.md, "MIDI sync out does not work").
--
-- Method: snapshot RAM while the sequencer is stopped, start playback,
-- then snapshot repeatedly. Report addresses that
--   * change between samples while playing (moving with the transport),
--   * are stable while stopped,
--   * and, for the beat counter, cycle within a small range.
--
-- Emits candidate addresses for a follow-up narrowing pass.
local function field(port_tag, field_name)
    return manager.machine.ioport.ports[port_tag].fields[field_name]
end

local function press(button, duration)
    button:set_value(1)
    emu.wait(duration or 0.4)
    button:clear_value()
end

local mem = manager.machine.devices[":maincpu"].spaces["program"]

-- MPC2000XL main RAM: scan a bounded window to keep this tractable.
-- Main RAM is 0x000000-0x07ffff (mirrored higher). The sequencer working
-- area lives low; scan a 128K window by default, override to sweep more.
local SCAN_BEGIN = tonumber(os.getenv("SCAN_BEGIN") or "0")
local SCAN_END = tonumber(os.getenv("SCAN_END") or "131072")

local function snapshot()
    local out = {}
    for addr = SCAN_BEGIN, SCAN_END - 1 do
        out[addr] = mem:read_u8(addr)
    end
    return out
end

manager.machine.sound.ui_mute = true
manager.machine.video.speed_factor = 4000
emu.wait(24)
manager.machine.video.speed_factor = 1000
emu.wait(0.5)

print("TRANSPORT_SCAN_BEGIN")

-- Two stopped snapshots: anything differing here is noise (timers, LCD
-- buffers, free-running counters) and gets excluded.
local stopped_a = snapshot()
emu.wait(2)
local stopped_b = snapshot()

local noise = {}
local stable = 0
for addr = SCAN_BEGIN, SCAN_END - 1 do
    if stopped_a[addr] ~= stopped_b[addr] then
        noise[addr] = true
    else
        stable = stable + 1
    end
end
print(string.format("TRANSPORT_STABLE_WHILE_STOPPED %d of %d",
    stable, SCAN_END - SCAN_BEGIN))

-- Now play and sample repeatedly.
manager.machine.sound.ui_mute = false
press(field(":Y4", "Play Start"))
emu.wait(1.0)

-- Sample well under one beat (86 BPM = 0.70 s/beat) so a beat counter
-- shows a staircase rather than aliasing into noise.
local samples = {}
for i = 1, 12 do
    samples[i] = snapshot()
    emu.wait(0.15)
end

-- What daw-ctl actually needs is ONE monotonically advancing sequencer
-- tick counter: its rate against the sample clock gives tempo, and its
-- value modulo the bar length gives bar phase. So look for 16- and 32-bit
-- little-endian words that only ever increase while playing (and were
-- stable while stopped).
local function word(sample, addr, width)
    local v = 0
    for i = width - 1, 0, -1 do
        v = v * 256 + sample[addr + i]
    end
    return v
end

local function monotonic(addr, width)
    local prev, total = nil, 0
    for i = 1, #samples do
        local v = word(samples[i], addr, width)
        if prev then
            if v < prev then return nil end
            total = total + (v - prev)
        end
        prev = v
    end
    return total > 0 and total or nil
end

-- The beat field is unmistakable: a byte that only ever holds 1..4 (or
-- 0..3) and changes while playing. Tick fields stay under the PPQN.
local beats, ticks = {}, {}
for addr = SCAN_BEGIN, SCAN_END - 1 do
    if not noise[addr] then
        local lo, hi, distinct, seen = 255, 0, 0, {}
        for i = 1, #samples do
            local v = samples[i][addr]
            if v < lo then lo = v end
            if v > hi then hi = v end
            if not seen[v] then seen[v] = true distinct = distinct + 1 end
        end
        if distinct > 1 then
            local seq = {}
            for i = 1, #samples do seq[i] = samples[i][addr] end
            local line = string.format("%06x seq=%s", addr,
                table.concat(seq, ","))
            if lo >= 0 and hi <= 4 then
                beats[#beats + 1] = line
            elseif lo >= 0 and hi <= 96 then
                ticks[#ticks + 1] = line
            end
        end
    end
end
print("TRANSPORT_BEATLIKE " .. #beats)
for i = 1, math.min(#beats, 20) do print("TRANSPORT_BEAT " .. beats[i]) end
print("TRANSPORT_TICKLIKE " .. #ticks)
for i = 1, math.min(#ticks, 20) do print("TRANSPORT_TICKFIELD " .. ticks[i]) end

for _, width in ipairs({ 2, 4 }) do
    local hits = {}
    for addr = SCAN_BEGIN, SCAN_END - width do
        local quiet = true
        for i = 0, width - 1 do
            if noise[addr + i] then quiet = false break end
        end
        if quiet then
            local advance = monotonic(addr, width)
            if advance then
                local seq = {}
                for i = 1, #samples do seq[i] = word(samples[i], addr, width) end
                hits[#hits + 1] = { addr = addr, advance = advance,
                    seq = table.concat(seq, ",") }
            end
        end
    end
    table.sort(hits, function(a, b) return a.advance > b.advance end)
    print(string.format("TRANSPORT_MONOTONIC%d %d", width * 8, #hits))
    for i = 1, math.min(#hits, 24) do
        print(string.format("TRANSPORT_TICK%d %06x advance=%d seq=%s",
            width * 8, hits[i].addr, hits[i].advance, hits[i].seq))
    end
end
-- Tempo is static while playing, so it lives in the "stable" set: look
-- for the displayed 86.0 stored as 86, 860 or 8600.
for _, want in ipairs({ 86, 860, 8600 }) do
    local found = 0
    for addr = SCAN_BEGIN, SCAN_END - 2 do
        local v = samples[1][addr] + 256 * samples[1][addr + 1]
        if v == want and found < 12 then
            print(string.format("TRANSPORT_TEMPO_%d %06x", want, addr))
            found = found + 1
        end
    end
    print(string.format("TRANSPORT_TEMPO_%d_COUNT %d", want, found))
end

print("TRANSPORT_SCAN_END")
manager.machine:exit()
