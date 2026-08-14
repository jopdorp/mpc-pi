#!/usr/bin/env bash
# Three-stage profile-guided build of the ordered MPC patch stack.
#
# Stage 1 builds instrumented (-fprofile-generate), stage 2 runs the Logic
# playback fixture headlessly to collect a deployment-shaped profile, stage 3
# rebuilds with -fprofile-use. The resulting binary must still pass the frozen
# PCM gate; -ffp-contract=off is mandatory with -march=native because FMA
# contraction changes float rounding in the stream-mixing chain and breaks the
# frozen reference.
#
# Measured on the 36-patch stack: +11.44% average speed over the generic -O3
# build in a matched ABBA with complete separation, PCM bit-identical.
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
pgo_dir=${MAME_PGO_DIR:-"$repo_root/.cache/pgo-mpc"}
base_opts=${MAME_PGO_BASE_OPTS:-"-march=native -ffp-contract=off"}
project=${MAME_PGO_PROJECT:-"$repo_root/results/projects/mpc-tutor-logic-mpc2000xl.img"}
fixture=${MAME_PGO_FIXTURE:-"$repo_root/scripts/diagnostics/headroom-logic-mpc2000xl.lua"}
train_runtime=${MAME_PGO_RUNTIME:-"$repo_root/results/runtime-pgo-train"}

[[ -f "$project" ]] || { printf 'error: training project missing: %s\n' "$project" >&2; exit 1; }
[[ -f "$fixture" ]] || { printf 'error: training fixture missing: %s\n' "$fixture" >&2; exit 1; }
mkdir -p "$pgo_dir"

printf '=== stage 1/3: instrumented build ===\n'
MAME_ARCHOPTS="$base_opts -fprofile-generate=$pgo_dir -fprofile-update=atomic" \
MAME_LTO=1 "$repo_root/scripts/build-mame.sh"

printf '=== stage 2/3: training run (Logic playback, deployment options) ===\n'
mkdir -p "$train_runtime"
MAME_RUNTIME_DIR="$train_runtime" MAME_CPUSET=${MAME_CPUSET:-0-11} \
MAME_NICE=0 MAME_RT_PRIORITY=20 MAME_TIMING_MASTER=video \
MPC_VIDEO_MODE=opengl MPC_VIEW_NAME='Screen 0' MPC_WINDOW_RESOLUTION=1240x300 \
MPC_OUTPUT_MODE=stereo MPC_ASYNC_PRESENT=1 MPC_SDL_EXTERNAL_EVENT_LOOP=1 \
MPC_PANEL_MODE=event MPC_PANEL_TIMER_MODE=coalesced MPC_MIDI_CLOCK_MODE=event \
MPC_V53_STATUS_MODE=hle MPC_V53_EVENT_SERVICE_MODE=hle \
MPC_V53_DISPATCH_MODE=direct MPC_V53_DIVIDE_MODE=superblock \
MPC_V53_FETCH_MODE=window MPC_LCD_UPDATE_MODE=changed \
MPC_HEADROOM_SPEED_FACTOR=100000 MAME_BIOS=default \
timeout 600 "$repo_root/scripts/run-mpc.sh" mpc2000xl 32 \
    -flop "$project" -skip_gameinfo -seconds_to_run 60 \
    -autoboot_script "$fixture"

printf '=== stage 3/3: optimized rebuild ===\n'
MAME_ARCHOPTS="$base_opts -fprofile-use=$pgo_dir -fprofile-correction -Wno-error=missing-profile -Wno-error=coverage-mismatch" \
MAME_LTO=1 "$repo_root/scripts/build-mame.sh"

printf 'PGO build complete. Run the frozen PCM gate before deploying.\n'
