-- Phase 2 sync proof: headless Ardour slaves its transport to an external
-- MIDI clock. TransportMasterManager has no Lua bindings, but none are
-- needed: with a fresh config dir the default current master is "MIDI
-- Clock" (added last in set_default_configuration, and restart() keeps it
-- when no transport_masters state file exists). All Lua has to do is
-- enable external sync and watch the transport follow.
--
-- Handshake with phase2-sync-run.sh: after enabling sync this script
-- writes $SYNC_DIR/ready; the runner then links the clock sender to
-- Ardour's "MIDI Clock in" port and the transport should start rolling.

local sync_dir = os.getenv("SYNC_DIR") or "/tmp/daw-sync"
local results = {}
local function say(t) io.write(t .. "\n") io.flush() end
local function step(name, fn)
	local ok, err = pcall(fn)
	results[#results + 1] = string.format("%s: %s%s",
		ok and "PASS" or "FAIL", name, ok and "" or (" -- " .. tostring(err)))
	say(results[#results])
	return ok
end

local session = nil

step("select backend", function()
	local backend = AudioEngine:set_backend("JACK/Pipewire", "", "")
	assert(backend and not backend:isnil(), "no JACK/Pipewire backend")
end)

step("create session", function()
	session = create_session(sync_dir .. "/session", "sync", 48000)
	assert(session, "create_session returned nil")
end)
assert(session, "no session; cannot continue")

step("enable external sync", function()
	session:cfg():set_external_sync(true)
	assert(session:cfg():get_external_sync(), "external sync did not stick")
end)

-- Tell the runner we're ready for the clock.
local f = assert(io.open(sync_dir .. "/ready", "w"))
f:write("ready\n")
f:close()
say("  ready marker written; waiting for clock")

step("transport chases MIDI clock", function()
	local rolled_at = nil
	for i = 1, 60 do -- up to 30 s
		ARDOUR.LuaAPI.usleep(500 * 1000)
		if session:transport_rolling() then
			rolled_at = i * 0.5
			break
		end
	end
	assert(rolled_at, "transport never rolled while clock was running")
	say(string.format("  rolling after %.1f s", rolled_at))
end)

step("chase speed is sane", function()
	local a = session:transport_sample()
	ARDOUR.LuaAPI.usleep(5 * 1000 * 1000)
	local b = session:transport_sample()
	local speed = (b - a) / (5.0 * 48000.0)
	say(string.format("  advanced %d samples in 5 s (speed %.3f)", b - a, speed))
	assert(speed > 0.9 and speed < 1.1, "speed out of range: " .. speed)
end)

print("SYNC-SUMMARY-BEGIN")
for _, line in ipairs(results) do print(line) end
print("SYNC-SUMMARY-END")
close_session()
