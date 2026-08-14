#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

repo_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
mame_source_dir=${MAME_SOURCE_DIR:-"$repo_root/.cache/mame"}
mame_bin=${MAME_BIN:-"$mame_source_dir/mpc"}
cpu=${MAME_BENCHMARK_CPU:-20}
runs=${MPC_BENCHMARK_RUNS:-2}
project="$repo_root/results/projects/mpc-tutor-logic-mpc2000xl.img"
fixture="$repo_root/scripts/diagnostics/benchmark-loaded-mpc2000xl.lua"
result_dir=$(mktemp -d "$repo_root/results/diagnostics/current-stack-performance-XXXXXX")

if [[ ! -x "$mame_bin" ]]; then
	printf 'error: MAME binary is not executable: %s\n' "$mame_bin" >&2
	exit 1
fi
if [[ ! "$runs" =~ ^[1-9][0-9]*$ ]]; then
	printf 'error: MPC_BENCHMARK_RUNS must be a positive integer, got %s\n' "$runs" >&2
	exit 2
fi
if ! taskset --cpu-list "$cpu" true 2>/dev/null; then
	printf 'error: MAME_BENCHMARK_CPU is not an available CPU: %s\n' "$cpu" >&2
	exit 2
fi
if [[ ! -f "$project" ]]; then
	printf 'error: benchmark project is missing: %s\n' "$project" >&2
	exit 1
fi

stat_events='task-clock,cpu_atom/cycles/,cpu_atom/instructions/,cpu_atom/branches/,cpu_atom/branch-misses/,cpu_atom/cache-misses/'
if taskset --cpu-list 0 perf stat -e task-clock -- true >/dev/null 2>&1; then
	perf_available=1
else
	perf_available=0
fi

record_manifest()
{
	{
		printf 'timestamp=%s\n' "$(date --iso-8601=seconds)"
		printf 'repository_revision=%s\n' "$(git -C "$repo_root" rev-parse HEAD)"
		printf 'repository_status_begin\n'
		git -C "$repo_root" status --short
		printf 'repository_status_end\n'
		printf 'mame_binary=%s\n' "$mame_bin"
		sha256sum "$mame_bin" "$fixture" "$project" "$repo_root/roms/mpc2000xl.zip"
		printf 'mame_source_dir=%s\n' "$mame_source_dir"
		printf 'mame_base_revision=%s\n' "$(git -C "$mame_source_dir" rev-parse HEAD 2>/dev/null || printf unknown)"
		printf 'benchmark_cpu=%s\n' "$cpu"
		printf 'benchmark_runs_per_mode=%s\n' "$runs"
		printf 'power_profile=%s\n' "$(powerprofilesctl get 2>/dev/null || printf unknown)"
		printf 'governor=%s\n' "$(cat "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_governor" 2>/dev/null || printf unknown)"
		printf 'epp=%s\n' "$(cat "/sys/devices/system/cpu/cpu$cpu/cpufreq/energy_performance_preference" 2>/dev/null || printf unknown)"
		printf 'host_audio_active=no (-sound none)\n'
		printf 'video_mode=none\n'
		printf 'hardware_perf_counters=%s\n' "$perf_available"
		if (( !perf_available )); then
			printf 'hardware_perf_reason=kernel.perf_event_paranoid=%s\n' "$(cat /proc/sys/kernel/perf_event_paranoid)"
		fi
		printf 'workload=loaded Logic project, 24 s accelerated boot plus 60 s playback\n'
	} >"$result_dir/manifest.txt"
}

run_one()
{
	local mode=$1
	local ordinal=$2
	local prefix="$result_dir/${ordinal}-${mode}"
	local runtime
	runtime=$(mktemp -d "$repo_root/results/runtime/current-stack-${mode}-XXXXXX")

	local -a mode_environment
	case "$mode" in
		accurate)
			mode_environment=(
				MPC_PANEL_MODE=accurate
				MPC_PANEL_TIMER_MODE=accurate
				MPC_MIDI_CLOCK_MODE=accurate
				MPC_V53_STATUS_MODE=accurate
				MPC_V53_EVENT_SERVICE_MODE=accurate
				MPC_V53_DISPATCH_MODE=accurate
			)
			;;
		optimized)
			mode_environment=(
				MPC_PANEL_MODE=event
				MPC_PANEL_TIMER_MODE=coalesced
				MPC_MIDI_CLOCK_MODE=event
				MPC_V53_STATUS_MODE=hle
				MPC_V53_EVENT_SERVICE_MODE=accurate
				MPC_V53_DISPATCH_MODE=direct
			)
			;;
		*)
			printf 'internal error: unknown mode %s\n' "$mode" >&2
			exit 2
			;;
	esac

	printf 'run=%s mode=%s started=%s\n' "$ordinal" "$mode" "$(date --iso-8601=seconds)" | tee "$prefix.status"
	local frequency_stop="$prefix.frequency-stop"
	rm -f -- "$frequency_stop"
	(
		while [[ ! -e "$frequency_stop" ]]; do
			printf '%s\t' "$(date +%s.%N)"
			cat "/sys/devices/system/cpu/cpu$cpu/cpufreq/scaling_cur_freq" 2>/dev/null || printf 'unknown\n'
			sleep 0.1
		done
	) >"$prefix.frequency.tsv" &
	local frequency_pid=$!
	local -a workload=(
		env MAME_BIN="$mame_bin" MAME_RUNTIME_DIR="$runtime"
		MAME_CPUSET="$cpu" MAME_NICE=0 MAME_RT_PRIORITY=1 \
		MAME_TIMING_MASTER=video MPC_VIDEO_MODE=none \
		MPC_ARTWORK_RESOLUTION=auto MPC_GL_VBO=1 MPC_ASYNC_PRESENT=1 \
		MPC_SDL_EXTERNAL_EVENT_LOOP=1 MPC_MIDI_INPUT_MODE=accurate \
		MPC_OUTPUT_MODE=all MAME_BIOS=default \
		"${mode_environment[@]}" \
		"$repo_root/scripts/run-mpc.sh" mpc2000xl 32 \
		-flop "$project" -skip_gameinfo -sound none -nothrottle \
		-autoboot_script "$fixture"
	)
	if (( perf_available )); then
		set +e
		taskset --cpu-list 0 perf stat -x, -e "$stat_events" -o "$prefix.perf" -- \
			"${workload[@]}" >"$prefix.log" 2>&1
		local run_status=$?
		set -e
	else
		set +e
		/usr/bin/time -v -o "$prefix.time" "${workload[@]}" >"$prefix.log" 2>&1
		local run_status=$?
		set -e
	fi
	touch "$frequency_stop"
	wait "$frequency_pid"
	rm -f -- "$frequency_stop"
	if (( run_status )); then
		printf 'FAIL: %s run %s exited with status %s\n' "$mode" "$ordinal" "$run_status" >&2
		exit "$run_status"
	fi

	grep -Fq 'MPC_BENCHMARK_BEGIN' "$prefix.log"
	grep -Fq 'MPC_BENCHMARK_END' "$prefix.log"
	grep -F 'Average speed:' "$prefix.log" | tail -1 >"$prefix.speed"
	printf 'run=%s mode=%s finished=%s\n' "$ordinal" "$mode" "$(date --iso-8601=seconds)" >>"$prefix.status"
}

record_manifest
ordinal=0
for (( pair=1; pair <= runs; pair++ )); do
	if (( pair % 2 )); then
		order=(accurate optimized)
	else
		order=(optimized accurate)
	fi
	for mode in "${order[@]}"; do
		(( ordinal += 1 ))
		run_one "$mode" "$ordinal"
	done
done

python3 - "$result_dir" <<'PY'
from pathlib import Path
import re
import statistics
import sys

root = Path(sys.argv[1])
events = {
    "task-clock": "task_clock_ms",
    "cpu_atom/cycles/": "cycles",
    "cpu_atom/instructions/": "instructions",
    "cpu_atom/branches/": "branches",
    "cpu_atom/branch-misses/": "branch_misses",
    "cpu_atom/cache-misses/": "cache_misses",
}
rows = []
paths = sorted(root.glob("*.perf")) or sorted(root.glob("*.time"))
for path in paths:
    match = re.match(r"(\d+)-(accurate|optimized)\.(?:perf|time)", path.name)
    if not match:
        continue
    row = {"run": int(match.group(1)), "mode": match.group(2)}
    if path.suffix == ".perf":
        for line in path.read_text().splitlines():
            fields = line.split(",")
            if len(fields) < 3:
                continue
            raw, _, event = fields[:3]
            event = event.strip()
            if event in events and raw.strip() not in {"<not counted>", "<not supported>"}:
                row[events[event]] = float(raw.strip())
    else:
        values = {}
        for line in path.read_text().splitlines():
            if ": " in line:
                key, value = line.strip().split(": ", 1)
                values[key] = value
        user = float(values["User time (seconds)"])
        system = float(values["System time (seconds)"])
        row["task_clock_ms"] = (user + system) * 1000.0
        row["max_rss_kib"] = float(values["Maximum resident set size (kbytes)"])
    speed_text = path.with_suffix(".speed").read_text()
    speed = re.search(r"Average speed:\s+([0-9.]+)%", speed_text)
    row["speed_percent"] = float(speed.group(1)) if speed else float("nan")
    rows.append(row)

metrics = ["task_clock_ms", "speed_percent"]
for metric in ["cycles", "instructions", "branches", "branch_misses", "cache_misses", "max_rss_kib"]:
    if all(metric in row for row in rows):
        metrics.append(metric)
with (root / "runs.tsv").open("w") as out:
    out.write("run\tmode\t" + "\t".join(metrics) + "\n")
    for row in rows:
        out.write(f"{row['run']}\t{row['mode']}\t" + "\t".join(f"{row[m]:.6f}" for m in metrics) + "\n")

summary = []
for metric in metrics:
    accurate = statistics.mean(row[metric] for row in rows if row["mode"] == "accurate")
    optimized = statistics.mean(row[metric] for row in rows if row["mode"] == "optimized")
    change = (optimized / accurate - 1.0) * 100.0
    summary.append((metric, accurate, optimized, change))

with (root / "summary.tsv").open("w") as out:
    out.write("metric\taccurate_mean\toptimized_mean\tchange_percent\n")
    for metric, accurate, optimized, change in summary:
        out.write(f"{metric}\t{accurate:.6f}\t{optimized:.6f}\t{change:.6f}\n")

print((root / "summary.tsv").read_text(), end="")
PY

printf 'Artifacts: %s\n' "$result_dir"
