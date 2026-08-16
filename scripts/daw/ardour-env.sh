# Find the installed Ardour, whatever major version it is.
#
# The build host runs Ardour 9 from source; Debian trixie on the Pi ships
# Ardour 8. Every script here hardcoded /usr/lib/ardour9, so on the
# target - the only machine whose result actually matters - the
# integration tests skipped and reported themselves skipped. A harness
# that cannot find the program it is testing is not portable, it is
# decorative.
#
# Highest version wins, so a box with both tests the newer one.
#
#   . scripts/daw/ardour-env.sh && ardour_env || echo "no ardour"

ardour_env() {
	local d best=""
	for d in /usr/lib/ardour* /usr/local/lib/ardour*; do
		[ -x "$d/luasession" ] || continue
		case "$d" in *ardour[0-9]*) ;; *) continue ;; esac
		if [ -z "$best" ]; then
			best="$d"
		else
			# Compare the trailing version numbers numerically.
			local a="${d##*ardour}" b="${best##*ardour}"
			[ "${a%%[!0-9]*}" -gt "${b%%[!0-9]*}" ] 2>/dev/null && best="$d"
		fi
	done
	[ -n "$best" ] || return 1

	local v="${best##*ardour}"
	v="${v%%[!0-9]*}"
	LUASESSION="$best/luasession"
	ARDOUR_DLL_PATH="$best"
	ARDOUR_DATA_PATH="/usr/share/ardour$v"
	ARDOUR_CONFIG_PATH="/etc/ardour$v"
	LD_LIBRARY_PATH="$best${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	ARDOUR_VERSION="$v"
	export LUASESSION ARDOUR_DLL_PATH ARDOUR_DATA_PATH ARDOUR_CONFIG_PATH \
		LD_LIBRARY_PATH ARDOUR_VERSION
	return 0
}
