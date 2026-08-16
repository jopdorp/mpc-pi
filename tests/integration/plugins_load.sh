#!/bin/bash
# Every URI in the manifest must actually instantiate. A manifest that
# lists a plugin the host cannot load is a session that builds a chain
# with a hole in it.
set -uo pipefail
cd "$(dirname "$0")/../.."
. scripts/daw/ardour-env.sh
ardour_env || { echo "SKIP: no Ardour found"; exit 0; }
base=$(mktemp -d /tmp/plugtest-XXXXXX)
python3 - > "$base/uris.txt" <<'PY'
import sys
sys.path.insert(0, "scripts/maschine")
import plugins
seen = []
for r in plugins.ROLES:
    u = r["uris"][0]
    if u not in seen:
        seen.append(u)
cab = plugins.role_for_kind("amp")[0].get("cab_uri")
if cab and cab not in seen:
    seen.append(cab)
print("\n".join(seen))
PY
cat > "$base/probe.lua" <<'LUA'
local compat = dofile(os.getenv("MPCPI_COMPAT"))
compat.use_backend()
local s = create_session(os.getenv("PDIR"), "probe", 48000)
assert(s, "create_session returned nil on " .. compat.backend())
local tl = s:new_audio_track(2,2,compat.route_group(),1,"T",
  ARDOUR.PresentationInfo.max_order, ARDOUR.TrackMode.Normal, true, true)
local ok, miss = 0, 0
for line in io.lines(os.getenv("URIS")) do
  if #line > 0 then
    local p = ARDOUR.LuaAPI.new_plugin(s, line, ARDOUR.PluginType.LV2, "")
    if p and not p:isnil() then ok = ok + 1
    else miss = miss + 1; print("MISSING " .. line) end
  end
end
-- Latency, not just presence. A plugin that loads and reports 5745
-- samples of latency is worse than one that fails: it works, sounds
-- right, and puts 130ms between a string and the player. Two got into
-- this desk that way - a lookahead limiter and a linear-phase multiband
-- clipper - and neither cost enough CPU to show up in a DSP
-- measurement.
--
-- The bar is one graph period at the target quantum. Anything above
-- that is a plugin the live path cannot carry, whatever it sounds like.
local LIMIT = tonumber(os.getenv("MAX_LATENCY_SAMPLES") or "64")
local late = 0
for line in io.lines(os.getenv("URIS")) do
  if #line > 0 then
    local p = ARDOUR.LuaAPI.new_plugin(s, line, ARDOUR.PluginType.LV2, "")
    if p and not p:isnil() then
      tl:front():add_processor_by_index(p, -1, nil, true)
      local lat = 0
      pcall(function() lat = p:signal_latency() end)
      if lat > LIMIT then
        late = late + 1
        print(string.format("LATENCY %d samples (limit %d) %s", lat, LIMIT, line))
      end
    end
  end
end
print(string.format("LATE %d", late))
print(string.format("RESULT ok=%d missing=%d", ok, miss))
close_session()
LUA
out=$(PDIR="$base/s" URIS="$base/uris.txt" \
  MPCPI_COMPAT="$PWD/scripts/daw/ardour-compat.lua" timeout 240 \
  "$LUASESSION" "$base/probe.lua" 2>/dev/null |
  grep -E "^RESULT|^MISSING|^LATE|^LATENCY")
echo "$out"
rm -rf "$base"
# Both conditions: every plugin instantiates, and none of them puts more
# than a graph period of latency into the live path.
# Latency is asserted in session_builds.sh instead: there the manifest's
# parameters have been applied, and a plugin's DEFAULT latency is not
# what the instrument runs. The limiter ships with 240 samples of
# lookahead and the session sets it to zero; failing here would be
# failing a plugin we already configured correctly.
echo "$out" | grep -q "missing=0"
