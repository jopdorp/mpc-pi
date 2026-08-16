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
print(string.format("RESULT ok=%d missing=%d", ok, miss))
close_session()
LUA
out=$(PDIR="$base/s" URIS="$base/uris.txt" \
  MPCPI_COMPAT="$PWD/scripts/daw/ardour-compat.lua" timeout 240 \
  "$LUASESSION" "$base/probe.lua" 2>/dev/null | grep -E "^RESULT|^MISSING")
echo "$out"
rm -rf "$base"
echo "$out" | grep -q "missing=0"
