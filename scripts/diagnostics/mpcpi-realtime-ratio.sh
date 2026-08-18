#!/bin/sh
# mpcpi-realtime-ratio.sh <seconds>
# What fraction of realtime the emulator is ACTUALLY producing audio at.
#
# MAME prints one "audio buffer correction" line per 500 host sound updates per
# stream. With MAME_SOUND_UPDATE_FRAMES=64 that is 32000 frames of audio, so
#     ratio = lines * 500 * 64 / (44100 * seconds)
# This works in every configuration, unlike the "audio clock:" line, which is
# only emitted while realtime pacing is engaged.
#
# Below ~99% means audio is being dropped before it ever reaches PipeWire, and
# no buffer tuning will help - check thread priorities first (see
# docs/audio-chain.md). Needs MAME_PIPEWIRE_STATS=1, which the appliance unit
# deliberately does not set:
#
#   systemctl edit mpcpi-emulator   # Environment=MAME_PIPEWIRE_STATS=1
secs="${1:-20}"
sleep "$secs"
journalctl -u mpcpi-emulator --since "-${secs}s" --no-pager -o cat |
  grep "audio buffer correction on stream" |
  sed 's/.*on stream \([0-9]*\).*/\1/' | sort | uniq -c |
  awk -v s="$secs" '{ f = $1 * 500 * 64; printf "stream %-3s updates=%-6d frames=%-8d realtime=%.1f%%\n", $2, $1*500, f, 100*f/(44100*s) }'
