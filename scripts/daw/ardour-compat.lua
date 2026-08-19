-- The parts of Ardour's Lua API that differ between versions and hosts.
--
-- Written once because both the session template and the plugin probe
-- need exactly the same two decisions, and they were made twice and
-- fixed once - the probe kept the original bugs and reported "no plugins
-- load" on a board where all 29 of them load fine.
--
--   local compat = dofile(os.getenv("MPCPI_COMPAT")
--                         or "scripts/daw/ardour-compat.lua")

local M = {}

-- Is there a sound server to talk to?
--
-- io.open is NOT an existence test for these: they are unix sockets, and
-- fopen on a socket fails, so probing pipewire-0 reports "missing" on a
-- machine where PipeWire is plainly running. os.rename(p, p) succeeds
-- for any kind of directory entry.
function M.jack_available()
	local paths = {}
	local xdg = os.getenv("XDG_RUNTIME_DIR")
	if xdg then paths[#paths + 1] = xdg .. "/pipewire-0" end
	paths[#paths + 1] = "/run/user/1000/pipewire-0"
	paths[#paths + 1] = "/dev/shm/jack_default_" .. (os.getenv("USER") or "")
	for _, p in ipairs(paths) do
		if os.rename(p, p) then return true end
	end
	return false
end

-- Which backend to select, decided BEFORE the engine is touched.
--
-- There is no second chance: selecting JACK with no daemon leaves
-- AudioEngine in a state where set_backend("Dummy") returns false and
-- every later create_session returns nil. A trial-and-error loop cannot
-- work in one process, because the first wrong guess poisons the rest -
-- and the result looks like "no backend works anywhere".
function M.backend()
	local want = os.getenv("ARDOUR_BACKEND")
	if want and want ~= "" then return want end
	return M.jack_available() and "JACK/Pipewire" or "Dummy"
end

-- Select it. The return value is deliberately ignored: set_backend
-- ("Dummy") hands back a pointer whose isnil() is true even when the
-- backend was set correctly and the session that follows builds fine.
function M.use_backend()
	local nm = M.backend()
	AudioEngine:set_backend(nm, "", "")
	return nm
end

-- The route-group argument for new_audio_track / new_audio_route.
--
-- Neither value works on both versions. Ardour 9 binds RouteGroup as a
-- constructor and wants an object; Ardour 8 binds it as a plain table,
-- where calling it raises "attempt to call a table value" and every
-- track fails to appear. Pass nil to Ardour 9 instead and the process
-- dies outright mid-run with no Lua error to show for it.
function M.route_group()
	if M._group == nil then
		local ok, g = pcall(function() return ARDOUR.RouteGroup() end)
		M._group = ok and g or false
	end
	if M._group == false then return nil end
	return M._group
end

-- Move the transport, whatever this Ardour's request_locate looks like.
--
-- Ardour 9 takes (sample, force, disposition, source); older builds drop the
-- `force` flag, and the appliance runs Debian's Ardour 8 while the build host
-- runs 9 - the two-versions problem this file exists for. A wrong arity is a
-- Lua error, so try the widest form first and fall back; a locate that never
-- happened leaves the transport where it stopped, which after a punch-out is
-- a session permanently behind the beat, so the caller is told which.
--
-- Returns true if one of the forms was accepted.
function M.locate(session, sample, roll)
	local ltd = roll and ARDOUR.LocateTransportDisposition.MustRoll
	                 or ARDOUR.LocateTransportDisposition.RollIfAppropriate
	local src = ARDOUR.TransportRequestSource.TRS_UI
	local forms = {
		function() session:request_locate(sample, false, ltd, src) end,
		function() session:request_locate(sample, ltd, src) end,
		function() session:request_locate(sample) end,
	}
	for _, form in ipairs(forms) do
		if pcall(form) then return true end
	end
	return false
end

-- How long a region's fade is - if this Ardour will say.
--
-- Ardour 9 binds AudioRegion:fade_in_length and fade_out_length; ARDOUR 8
-- BINDS NEITHER, though both versions bind the SETTERS and both bind
-- fade_in_active. Measured on the appliance (8) and the build host (9)
-- against a real captured region:
--
--   set_fade_in_length   set_fade_out_length     bound on both
--   fade_in_active       set_fade_in_active      bound on both
--   fade_in_length       fade_out_length         Ardour 9 only
--   fade_in()            fade_out()              Ardour 9 only
--
-- This is the two-versions problem this file exists for, and it is the
-- shape that hurts most: the build host could read a fade, so the region
-- publisher and its integration test were both green there, and on the
-- appliance every publish died mid-file with "attempt to call a nil value
-- (method 'fade_in_length')". The region list stopped being published the
-- moment the first take was recorded onto it - which is the only moment it
-- has anything to say.
--
-- Returns nil rather than 0 when the getter is absent, so a caller can tell
-- "no fade" from "this Ardour will not tell you".
function M.fade_length(ar, which)
	if not ar or ar:isnil() then return nil end
	local getter = (which == "out") and ar.fade_out_length or ar.fade_in_length
	if type(getter) ~= "function" then return nil end
	local ok, v = pcall(getter, ar)
	if not ok or type(v) ~= "number" then return nil end
	return v
end

-- Connect the session's master to the first physical playback pair.
--
-- Not cosmetic, and not only about hearing it: PipeWire schedules a node
-- only when it is linked into a driver's graph. An Ardour session whose
-- master goes nowhere is never called, so it burns no CPU, reports no
-- DSP load, and looks - convincingly - like a graph running perfectly
-- and doing nothing. Every plugin cost measured 0.00% for exactly this
-- reason, with the engine reporting running=true throughout.
--
-- Returns how many channels were connected, so a caller can tell
-- "connected" from "no playback ports exist".
function M.connect_master(session)
	local master = session:master_out()
	if not master or master:isnil() then return 0 end
	local ports = C.StringVector()
	AudioEngine:get_backend_ports("", ARDOUR.DataType("audio"),
		ARDOUR.PortFlags.IsInput, ports)
	-- MPCPI_PLAYBACK_MATCH picks WHICH hardware the master lands on.
	-- Without it this takes the first two non-Ardour input ports in
	-- enumeration order - which is how the master kept landing on the
	-- phantom I2S sink after the appliance moved to USB output: the
	-- I2S card exists (the overlay creates it) whether or not anything
	-- is wired to those pins, and its ports enumerate first.
	local want = os.getenv("MPCPI_PLAYBACK_MATCH")
	local playback = {}
	for i = 1, ports:size() do
		local n = ports:at(i - 1)
		if not n:find("Ardour") and (not want or n:find(want, 1, true)) then
			playback[#playback + 1] = n
		end
	end
	local made = 0
	for ch = 0, 1 do
		local p = playback[ch + 1]
		if p then
			local ok = pcall(function()
				master:output():audio(ch):connect(p)
			end)
			if ok then made = made + 1 end
		end
	end
	return made
end

return M
