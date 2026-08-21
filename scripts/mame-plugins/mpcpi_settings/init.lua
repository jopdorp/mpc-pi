-- MPC-Pi device settings: one menu for the four things a player changes
-- without wanting to learn MAME - the disk in the drive, the MIDI ports,
-- the audio output device, and the audio buffer.
--
-- Three of those are live. The buffer size and the sample rate are read
-- when the audio stream is created and when the PipeWire graph is forced,
-- both of which happen before this plugin exists, so the menu writes them
-- to a settings file the ./mpcpi wrapper sources and asks the wrapper for
-- a fresh launch by leaving a marker behind. The menu says which is which
-- on the row rather than pretending everything applies at once.
--
-- By default, Menu or Tab opens Device Settings while MAME's UI is inactive.
-- MPCPI_SETTINGS_HOTKEY replaces that complete default set with one MAME
-- input sequence.

local exports = {
	name = 'mpcpi_settings',
	version = '0.0.1',
	description = 'MPC-Pi device settings',
	license = 'BSD-3-Clause',
	author = { name = 'MPC-Pi' } }

local mpcpi_settings = exports

local plugin_dir

function mpcpi_settings.set_folder(path)
	plugin_dir = path
end

function mpcpi_settings.startplugin()

	local MENU_NAME = 'Device Settings'
	local DEFAULT_HOTKEYS = { 'KEYCODE_MENU', 'KEYCODE_TAB' }

	-- What -listmedia reports for this drive, plus MAME's archive wrapper.
	-- A file that is not one of these is refused by name instead of being
	-- handed to the FDC, which answers a wrong-sized file with a silent empty
	-- drive. MAME selects the supported floppy image inside a ZIP itself.
	local DISK_EXTENSIONS = {
		mfi = true, dfi = true, mfm = true, td0 = true, imd = true,
		dsk = true, ima = true, img = true, ufi = true, ['360'] = true,
		ipf = true, hfe = true, zip = true }

	local FRAME_CHOICES = { 32, 64, 128, 256, 512 }
	local RATE_CHOICES = { 44100, 48000 }

	-- Written in the order a reader would want them, not hash order.
	local SETTING_ORDER = {
		'MPC_PIPEWIRE_FRAMES', 'PIPEWIRE_RATE_HZ', 'MPCPI_AUDIO_SINK',
		'MPCPI_MIDI_IN', 'MPCPI_MIDI_OUT', 'MPCPI_DISK' }

	local function env(name, fallback)
		local value = os.getenv(name)
		if value and value ~= '' then
			return value
		end
		return fallback
	end

	local home = env('HOME', '.')
	local conf_dir = env('XDG_CONFIG_HOME', home .. '/.config') .. '/mpcpi'
	local settings_file = env('MPCPI_SETTINGS_FILE', conf_dir .. '/settings.env')
	local relaunch_file = env('MPCPI_RELAUNCH_FILE', conf_dir .. '/relaunch')

	-- What this process was actually started with. The settings file holds
	-- what the NEXT launch will use, and the difference is the whole point
	-- of the "relaunch to apply" wording.
	local running_frames = env('MPC_PIPEWIRE_FRAMES', '64')
	local running_rate = env('PIPEWIRE_RATE_HZ', '48000')

	local settings = {}
	local pending_relaunch = false

	local function dirname(path)
		return path:match('^(.*)/[^/]*$') or '.'
	end

	local function basename(path)
		return path:match('([^/]+)/?$') or path
	end

	local function shquote(value)
		return "'" .. (tostring(value):gsub("'", "'\\''")) .. "'"
	end

	local function popmessage(text)
		manager.machine:popmessage(text)
	end

	local function run_lines(command)
		local lines = {}
		local pipe = io.popen(command .. ' 2>/dev/null')
		if not pipe then
			return lines
		end
		for line in pipe:lines() do
			lines[#lines + 1] = line
		end
		pipe:close()
		return lines
	end

	-- Settings file: KEY='value', one per line, so the wrapper can source it
	-- with no parser of its own. Values are single-quoted because sink and
	-- MIDI port names carry spaces.

	local function load_settings()
		settings = {}
		local file = io.open(settings_file, 'r')
		if not file then
			return
		end
		for line in file:lines() do
			local key, raw = line:match('^%s*([%w_]+)=(.*)$')
			if key then
				local inner = raw:match("^'(.*)'$")
				if inner then
					raw = inner:gsub("'\\''", "'")
				end
				settings[key] = raw
			end
		end
		file:close()
	end

	local function save_settings()
		lfs.mkdir(dirname(dirname(settings_file)))
		lfs.mkdir(dirname(settings_file))
		local file = io.open(settings_file, 'w')
		if not file then
			popmessage('Could not write ' .. settings_file)
			return false
		end
		file:write('# MPC-Pi device settings, written by the Device Settings menu.\n')
		file:write('# KEY=VALUE, sourced by ./mpcpi before each launch.\n')
		for _, key in ipairs(SETTING_ORDER) do
			local value = settings[key]
			if value and value ~= '' then
				file:write(key .. '=' .. shquote(value) .. '\n')
			end
		end
		file:close()
		return true
	end

	-- Devices are found by instance name, not by tag: ":fdc:0" is a slot
	-- card's tag and slot tags are exactly the kind of thing that quietly
	-- resolves to nil after a MAME bump. -listmedia publishes the instance
	-- names, so match those.
	local function find_image(names)
		local wanted = {}
		for _, name in ipairs(names) do
			wanted[name] = true
		end
		for _, image in pairs(manager.machine.images) do
			local ok, instance = pcall(function () return image.instance_name end)
			if ok and wanted[instance] then
				return image
			end
		end
		return nil
	end

	local function floppy_device()
		return find_image({ 'floppydisk', 'flop', 'flop1' })
	end

	local function midi_device(direction)
		if direction == 'in' then
			return find_image({ 'midiin1', 'midiin' })
		end
		return find_image({ 'midiout1', 'midiout' })
	end

	local function mounted_name(image)
		if not image then
			return nil
		end
		local ok, name = pcall(function ()
			if image.exists then
				return image.filename
			end
			return nil
		end)
		if ok then
			return name
		end
		return nil
	end

	-- Audio routing lives in the shell helper beside this file: it is the
	-- graph's business, not the emulator's, and one implementation is
	-- enough for both the menu and the wrapper's startup restore.
	local function route_helper()
		local explicit = os.getenv('MPCPI_AUDIO_ROUTE')
		if explicit and explicit ~= '' then
			return explicit
		end
		if plugin_dir then
			return plugin_dir .. '/mpcpi-audio-route'
		end
		return nil
	end

	local function route(args)
		local helper = route_helper()
		if not helper then
			return nil
		end
		return run_lines(shquote(helper) .. ' ' .. args)
	end

	local function current_sink()
		local out = route('--current')
		if out and out[1] and out[1] ~= '' then
			return out[1]
		end
		return nil
	end

	local function list_sinks()
		local sinks = {}
		for _, line in ipairs(route('--list') or {}) do
			local name, description = line:match('^([^\t]+)\t(.*)$')
			if name then
				sinks[#sinks + 1] = { name = name, description = description }
			end
		end
		return sinks
	end

	-- MAME publishes MIDI ports only through -listmidi, and there is no Lua
	-- binding for the OSD's enumeration, so ask the binary. It is the same
	-- binary this process is, one exec, and only when the list is opened.
	local midi_ports
	local function list_midi(force)
		if midi_ports and not force then
			return midi_ports
		end
		midi_ports = { ['in'] = {}, out = {} }
		local binary = os.getenv('MAME_BIN')
		if not binary or binary == '' then
			return midi_ports
		end
		local bucket
		for _, line in ipairs(run_lines(shquote(binary) .. ' -listmidi')) do
			if line:match('^MIDI input ports') then
				bucket = midi_ports['in']
			elseif line:match('^MIDI output ports') then
				bucket = midi_ports.out
			elseif bucket and line:match('%S') then
				local name = line:gsub('%s*%(default%)%s*$', '')
				name = name:gsub('%s+$', '')
				if name ~= '' then
					bucket[#bucket + 1] = name
				end
			end
		end
		return midi_ports
	end

	local function connect_midi(direction, port)
		local image = midi_device(direction)
		if not image then
			popmessage('No MIDI ' .. direction .. ' device on this machine')
			return
		end
		if image.exists then
			image:unload()
		end
		local key = (direction == 'in') and 'MPCPI_MIDI_IN' or 'MPCPI_MIDI_OUT'
		if port then
			local err = image:load(port)
			if err then
				popmessage('MIDI ' .. direction .. ': ' .. tostring(err))
				return
			end
			settings[key] = port
			popmessage('MIDI ' .. direction .. ': ' .. port)
		else
			settings[key] = nil
			popmessage('MIDI ' .. direction .. ' disconnected')
		end
		save_settings()
	end

	local function mount_disk(path)
		local image = floppy_device()
		if not image then
			popmessage('No floppy drive on this machine')
			return
		end
		local extension = basename(path):match('%.([^.]+)$')
		if not extension or not DISK_EXTENSIONS[extension:lower()] then
			popmessage('NOT A DISK: ' .. basename(path))
			return
		end
		if image.exists then
			image:unload()
		end
		local err = image:load(path)
		if err then
			popmessage('Could not mount ' .. basename(path) .. ': ' .. tostring(err))
			return
		end
		settings.MPCPI_DISK = path
		save_settings()
		popmessage('Mounted ' .. basename(path))
	end

	-- Menu state. Every populate pass rebuilds a handler table parallel to
	-- the item list, so an item's behaviour sits next to its text instead
	-- of in index arithmetic somewhere else.

	local VIEW_MAIN, VIEW_DISK, VIEW_MIDI, VIEW_SINK = 1, 2, 3, 4
	local view = VIEW_MAIN
	local midi_direction = 'in'
	local browse_dir
	local handlers = {}
	local restore_selection

	local function start_dir()
		local image = floppy_device()
		local mounted = mounted_name(image)
		if mounted and mounted ~= '' then
			local dir = dirname(mounted)
			if lfs.attributes(dir, 'mode') == 'directory' then
				return dir
			end
		end
		local configured = os.getenv('MPCPI_DISK_DIR')
		if configured and lfs.attributes(configured, 'mode') == 'directory' then
			return configured
		end
		local projects = home .. '/development/mpc-pi/results/projects'
		if lfs.attributes(projects, 'mode') == 'directory' then
			return projects
		end
		return home
	end

	local function list_dir(dir)
		local dirs, files = {}, {}
		pcall(function ()
			for name in lfs.dir(dir) do
				if name:sub(1, 1) ~= '.' then
					local attr = lfs.attributes(dir .. '/' .. name)
					if attr and attr.mode == 'directory' then
						dirs[#dirs + 1] = name
					elseif attr and attr.mode == 'file' then
						files[#files + 1] = { name = name, size = attr.size }
					end
				end
			end
		end)
		table.sort(dirs)
		table.sort(files, function (a, b) return a.name < b.name end)
		return dirs, files
	end

	local function human_size(bytes)
		if bytes >= 1024 * 1024 then
			return string.format('%.1f MB', bytes / (1024 * 1024))
		end
		return string.format('%d KB', math.floor(bytes / 1024))
	end

	local function cycle(choices, current, step)
		local index = 1
		for i, value in ipairs(choices) do
			if tostring(value) == tostring(current) then
				index = i
				break
			end
		end
		index = index + step
		if index < 1 then
			index = #choices
		elseif index > #choices then
			index = 1
		end
		return tostring(choices[index])
	end

	local function relaunch_note(key, running, unit)
		local chosen = settings[key] or running
		if chosen ~= running then
			return chosen .. ' ' .. unit .. '  (running ' .. running .. ' - relaunch to apply)'
		end
		return chosen .. ' ' .. unit
	end

	local function populate_main()
		local items = {}
		local function add(text, subtext, flags, handler)
			items[#items + 1] = { text, subtext or '', flags or '' }
			handlers[#items] = handler
			return #items
		end

		local floppy = floppy_device()
		local mounted = mounted_name(floppy)

		add('MPC-Pi device settings', '', 'heading')
		add('---')
		add('Floppy', '', 'heading')
		add('Disk', mounted and basename(mounted) or '(drive empty)', '', function (event)
			if event == 'select' then
				browse_dir = start_dir()
				view = VIEW_DISK
				restore_selection = 3
				return true
			end
		end)
		add('Eject', '', mounted and '' or 'off', function (event)
			if event == 'select' and mounted then
				floppy:unload()
				settings.MPCPI_DISK = nil
				save_settings()
				popmessage('Drive empty')
				return true
			end
		end)

		add('---')
		add('MIDI', '', 'heading')
		for _, direction in ipairs({ 'in', 'out' }) do
			local image = midi_device(direction)
			local port = mounted_name(image)
			add('MIDI ' .. direction, port or '(not connected)', image and '' or 'off',
				function (event)
					if event == 'select' and image then
						midi_direction = direction
						view = VIEW_MIDI
						restore_selection = 3
						return true
					end
				end)
		end

		add('---')
		add('Audio', '', 'heading')
		local sink = current_sink()
		add('Output device', sink or '(unknown)', route_helper() and '' or 'off', function (event)
			if event == 'select' then
				view = VIEW_SINK
				restore_selection = 3
				return true
			end
		end)
		add('Buffer', relaunch_note('MPC_PIPEWIRE_FRAMES', running_frames, 'frames'), 'lr',
			function (event)
				local step = (event == 'left') and -1 or ((event == 'right') and 1 or 0)
				if step ~= 0 then
					settings.MPC_PIPEWIRE_FRAMES =
						cycle(FRAME_CHOICES, settings.MPC_PIPEWIRE_FRAMES or running_frames, step)
					save_settings()
					return true
				end
			end)
		add('Sample rate', relaunch_note('PIPEWIRE_RATE_HZ', running_rate, 'Hz'), 'lr',
			function (event)
				local step = (event == 'left') and -1 or ((event == 'right') and 1 or 0)
				if step ~= 0 then
					settings.PIPEWIRE_RATE_HZ =
						cycle(RATE_CHOICES, settings.PIPEWIRE_RATE_HZ or running_rate, step)
					save_settings()
					return true
				end
			end)

		add('---')
		local frames_differ = (settings.MPC_PIPEWIRE_FRAMES or running_frames) ~= running_frames
		local rate_differ = (settings.PIPEWIRE_RATE_HZ or running_rate) ~= running_rate
		add('Apply and relaunch',
			(frames_differ or rate_differ) and 'buffer/rate changed' or 'restarts the emulator',
			'', function (event)
				if event == 'select' then
					if not save_settings() then
						return true
					end
					local marker = io.open(relaunch_file, 'w')
					if not marker then
						popmessage('Could not ask for a relaunch: ' .. relaunch_file)
						return true
					end
					marker:write('relaunch\n')
					marker:close()
					pending_relaunch = true
					manager.machine:exit()
					return true
				end
			end)
		add('Settings file', settings_file, 'off')

		return items
	end

	local function populate_disk()
		local items = {}
		local function add(text, subtext, flags, handler)
			items[#items + 1] = { text, subtext or '', flags or '' }
			handlers[#items] = handler
			return #items
		end

		add(browse_dir, '', 'heading')
		add('---')
		if browse_dir ~= '/' then
			add('..', '', '', function (event)
				if event == 'select' then
					browse_dir = dirname(browse_dir)
					if browse_dir == '' then
						browse_dir = '/'
					end
					return true
				end
			end)
		end

		local dirs, files = list_dir(browse_dir)
		for _, name in ipairs(dirs) do
			add(name .. '/', '', '', function (event)
				if event == 'select' then
					browse_dir = (browse_dir == '/') and ('/' .. name) or (browse_dir .. '/' .. name)
					return true
				end
			end)
		end
		for _, entry in ipairs(files) do
			local path = (browse_dir == '/') and ('/' .. entry.name) or (browse_dir .. '/' .. entry.name)
			add(entry.name, human_size(entry.size), '', function (event)
				if event == 'select' then
					mount_disk(path)
					view = VIEW_MAIN
					return true
				end
			end)
		end
		if #dirs == 0 and #files == 0 then
			add('(empty directory)', '', 'off')
		end

		add('---')
		add('Back', '', '', function (event)
			if event == 'select' then
				view = VIEW_MAIN
				return true
			end
		end)

		return items
	end

	local function populate_midi()
		local items = {}
		local function add(text, subtext, flags, handler)
			items[#items + 1] = { text, subtext or '', flags or '' }
			handlers[#items] = handler
			return #items
		end

		local image = midi_device(midi_direction)
		local connected = mounted_name(image)
		local ports = list_midi(false)[midi_direction]

		add('MIDI ' .. midi_direction .. ' port', '', 'heading')
		add('---')
		add('(not connected)', connected and '' or 'current', '', function (event)
			if event == 'select' then
				connect_midi(midi_direction, nil)
				view = VIEW_MAIN
				return true
			end
		end)
		for _, port in ipairs(ports) do
			add(port, (connected == port) and 'current' or '', '', function (event)
				if event == 'select' then
					connect_midi(midi_direction, port)
					view = VIEW_MAIN
					return true
				end
			end)
		end
		if #ports == 0 then
			add('(no ports found)', 'MAME_BIN unset or -listmidi empty', 'off')
		end

		add('---')
		add('Rescan ports', '', '', function (event)
			if event == 'select' then
				list_midi(true)
				return true
			end
		end)
		add('Back', '', '', function (event)
			if event == 'select' then
				view = VIEW_MAIN
				return true
			end
		end)

		return items
	end

	local function populate_sink()
		local items = {}
		local function add(text, subtext, flags, handler)
			items[#items + 1] = { text, subtext or '', flags or '' }
			handlers[#items] = handler
			return #items
		end

		local sink = current_sink()
		local sinks = list_sinks()

		add('Audio output device', '', 'heading')
		add('---')
		for _, entry in ipairs(sinks) do
			add(entry.description, (sink == entry.name) and 'current' or '', '', function (event)
				if event == 'select' then
					route(shquote(entry.name))
					if current_sink() == entry.name then
						settings.MPCPI_AUDIO_SINK = entry.name
						save_settings()
						popmessage('Output: ' .. entry.description)
					else
						popmessage('Could not route the output to ' .. entry.description)
					end
					view = VIEW_MAIN
					return true
				end
			end)
		end
		if #sinks == 0 then
			add('(no sinks found)', 'pactl/pw-link not available', 'off')
		end

		add('---')
		add('Back', '', '', function (event)
			if event == 'select' then
				view = VIEW_MAIN
				return true
			end
		end)

		return items
	end

	local function menu_populate()
		handlers = {}
		local items
		if view == VIEW_DISK then
			items = populate_disk()
		elseif view == VIEW_MIDI then
			items = populate_midi()
		elseif view == VIEW_SINK then
			items = populate_sink()
		else
			items = populate_main()
		end
		local selection = restore_selection
		restore_selection = nil
		return items, selection
	end

	local function menu_callback(index, event)
		if event == 'back' or event == 'cancel' then
			if view ~= VIEW_MAIN then
				view = VIEW_MAIN
				return true
			end
			return false
		end
		local handler = handlers[index]
		if handler then
			return handler(event) and true or false
		end
		return false
	end

	-- Whatever was chosen last time, put it back - but never over the top of
	-- a command line. An explicit -flop or -midiin1 on this launch is a
	-- deliberate choice and outranks a menu press from last week, so the
	-- restore only fills empty devices. It runs a few seconds in because the
	-- images exist long before the machine is ready to notice a disk change.
	local restored = false
	local function restore_saved()
		if restored or manager.machine.paused then
			return
		end
		if manager.machine.time.seconds < 3 then
			return
		end
		restored = true
		local floppy = floppy_device()
		if floppy and not floppy.exists and settings.MPCPI_DISK then
			if lfs.attributes(settings.MPCPI_DISK, 'mode') == 'file' then
				floppy:load(settings.MPCPI_DISK)
			end
		end
		for direction, key in pairs({ ['in'] = 'MPCPI_MIDI_IN', out = 'MPCPI_MIDI_OUT' }) do
			local image = midi_device(direction)
			if image and not image.exists and settings[key] then
				image:load(settings[key])
			end
		end
	end

	-- The UI owns Tab after Scroll Lock enables it. Never race MAME for a key
	-- while its UI is active or any MAME menu is already showing.
	local hotkey_sequences = {}
	local hotkey_down = false
	local menu_click_port
	local menu_click_down = false

	local function show_device_menu(requested)
		if requested == 2 then
			browse_dir = start_dir()
			view = VIEW_DISK
			restore_selection = 3
		elseif requested == 3 then
			view = VIEW_MAIN
			restore_selection = 8
		elseif requested == 4 then
			view = VIEW_MAIN
			restore_selection = 12
		else
			view = VIEW_MAIN
			restore_selection = nil
		end
		emu.show_menu(MENU_NAME)
	end

	local function poll_menu_click()
		if not menu_click_port then
			menu_click_port = manager.machine.ioport.ports[':MPCPI_MENU']
		end
		if not menu_click_port then
			return
		end
		local bits = menu_click_port:read() & 0x0f
		if bits == 0 then
			menu_click_down = false
			return
		end
		if menu_click_down then
			return
		end
		menu_click_down = true
		if manager.ui.ui_active or manager.ui.menu_active then
			return
		end
		if bits & 0x02 ~= 0 then
			show_device_menu(2)
		elseif bits & 0x04 ~= 0 then
			show_device_menu(3)
		elseif bits & 0x08 ~= 0 then
			show_device_menu(4)
		else
			show_device_menu(1)
		end
	end

	local function poll_hotkey()
		if #hotkey_sequences == 0 then
			return
		end
		local pressed = false
		for _, sequence in ipairs(hotkey_sequences) do
			if manager.machine.input:seq_pressed(sequence) then
				pressed = true
				break
			end
		end
		if pressed and not hotkey_down
				and not manager.ui.ui_active and not manager.ui.menu_active then
			show_device_menu(1)
		end
		hotkey_down = pressed
	end

	local function on_start()
		load_settings()
		local hotkeys = DEFAULT_HOTKEYS
		local override = os.getenv('MPCPI_SETTINGS_HOTKEY')
		if override and override ~= '' then
			hotkeys = { override }
		end
		for _, tokens in ipairs(hotkeys) do
			local ok, sequence = pcall(function ()
				return manager.machine.input:seq_from_tokens(tokens)
			end)
			if ok and sequence then
				hotkey_sequences[#hotkey_sequences + 1] = sequence
			end
		end
	end

	emu.register_prestart(on_start)
	emu.register_periodic(function ()
		restore_saved()
		poll_menu_click()
		poll_hotkey()
	end)
	emu.register_menu(menu_callback, menu_populate, MENU_NAME)
end

return exports
