#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
expected_sha256=${MPC_STEREO_REFERENCE_SHA256:-a65077eb074df2671731ea0e3f315f627044b4ece480c75de2871b8fd81b4014}
project="$repo_root/results/projects/mpc-tutor-logic-mpc2000xl.img"
capture_script="$repo_root/scripts/diagnostics/capture-logic-mpc2000xl.lua"

mkdir -p -- "$repo_root/results/diagnostics" "$repo_root/results/runtime"
result_dir=$(mktemp -d "$repo_root/results/diagnostics/stereo-output-XXXXXX")
full_runtime=$(mktemp -d "$repo_root/results/runtime/stereo-output-full-XXXXXX")
stereo_runtime=$(mktemp -d "$repo_root/results/runtime/stereo-output-stereo-XXXXXX")

run_capture() {
	local output_mode=$1
	local runtime_dir=$2
	local wav_path=$3
	local log_path=$4

	MAME_RUNTIME_DIR="$runtime_dir" MAME_NICE=0 \
		MPC_OUTPUT_MODE="$output_mode" \
		MPC_PANEL_MODE=event MPC_PANEL_TIMER_MODE=coalesced \
		MPC_MIDI_CLOCK_MODE=event MPC_V53_STATUS_MODE=hle \
		MPC_V53_EVENT_SERVICE_MODE=hle MPC_V53_DISPATCH_MODE=direct \
		"$repo_root/scripts/run-mpc.sh" mpc2000xl 32 \
		-flop "$project" \
		-skip_gameinfo \
		-video none \
		-sound none \
		-wavwrite "$wav_path" \
		-autoboot_script "$capture_script" \
		>"$log_path" 2>&1
}

run_capture all "$full_runtime" "$result_dir/full.wav" "$result_dir/full.log"
run_capture stereo "$stereo_runtime" "$result_dir/stereo.wav" "$result_dir/stereo.log"

full_sha256=$(sha256sum "$result_dir/full.wav")
full_sha256=${full_sha256%% *}
if [[ "$full_sha256" != "$expected_sha256" ]]; then
	printf 'FAIL: full-output render differs from the frozen event-mode reference PCM\n' >&2
	printf 'expected SHA-256 %s, got %s\n' "$expected_sha256" "$full_sha256" >&2
	exit 1
fi

python3 - "$result_dir/full.wav" "$result_dir/stereo.wav" <<'PY'
import sys
import wave

full_path, stereo_path = sys.argv[1:]

with wave.open(full_path, "rb") as full, wave.open(stereo_path, "rb") as stereo:
	if full.getnchannels() != 11:
		raise SystemExit(f"FAIL: full-output WAV has {full.getnchannels()} channels, expected 11")
	if stereo.getnchannels() != 3:
		raise SystemExit(f"FAIL: stereo-output WAV has {stereo.getnchannels()} channels, expected 3")

	full_format = (full.getsampwidth(), full.getframerate(), full.getnframes(), full.getcomptype())
	stereo_format = (stereo.getsampwidth(), stereo.getframerate(), stereo.getnframes(), stereo.getcomptype())
	if full_format != stereo_format:
		raise SystemExit(
			"FAIL: retained stereo-output WAV format differs from the full-output WAV: "
			f"full={full_format}, stereo={stereo_format}"
		)

	sample_width = full.getsampwidth()
	full_frame_width = full.getnchannels() * sample_width
	retained_width = stereo.getnchannels() * sample_width
	while True:
		full_frames = full.readframes(4096)
		stereo_frames = stereo.readframes(4096)
		if not full_frames and not stereo_frames:
			break
		retained_frames = b"".join(
			full_frames[offset : offset + retained_width]
			for offset in range(0, len(full_frames), full_frame_width)
		)
		if retained_frames != stereo_frames:
			raise SystemExit("FAIL: floppy/main L/R samples differ in stereo-output mode")
PY

full_cfg="$full_runtime/cfg/mpc2000xl.cfg"
if [[ ! -f "$full_cfg" ]]; then
	printf 'FAIL: full-output run did not create %s\n' "$full_cfg" >&2
	exit 1
fi
full_cfg_sha256=$(sha256sum "$full_cfg")
full_cfg_sha256=${full_cfg_sha256%% *}

MAME_RUNTIME_DIR="$full_runtime" MAME_NICE=0 MPC_OUTPUT_MODE=stereo \
	"$repo_root/scripts/run-mpc.sh" mpc2000xl 32 \
	-flop "$project" \
	-skip_gameinfo \
	-video none \
	-sound none \
	-seconds_to_run 1 \
	>"$result_dir/config-isolation.log" 2>&1

full_cfg_after_sha256=$(sha256sum "$full_cfg")
full_cfg_after_sha256=${full_cfg_after_sha256%% *}
if [[ "$full_cfg_after_sha256" != "$full_cfg_sha256" ]]; then
	printf 'FAIL: stereo-output run modified the full-output configuration\n' >&2
	exit 1
fi
if [[ ! -f "$full_runtime/cfg-stereo/mpc2000xl.cfg" ]]; then
	printf 'FAIL: stereo-output run did not create an isolated configuration\n' >&2
	exit 1
fi

printf 'PASS: full-output render matches the frozen 11-channel reference PCM\n'
printf 'PASS: stereo mode retains sample-identical floppy/main L/R output in 3 channels\n'
printf 'PASS: stereo and full-output configurations are isolated\n'
printf 'Artifacts: %s\n' "$result_dir"
