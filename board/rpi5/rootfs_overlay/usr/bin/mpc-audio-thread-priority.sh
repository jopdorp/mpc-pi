#!/bin/sh
# Put MAME's audio threads ABOVE its emulation thread.
#
# This is the fix for the crackle. Not the quantum, not the cushion, not the
# device, not the IRQs, not the ring buffer - the scheduler.
#
# run-mpc.sh starts MAME with
#
#     taskset --cpu-list 3 nice -n .. chrt --rr 20 env .. mpc ..
#
# so the whole process is SCHED_RR 20 pinned to one core, and every thread MAME
# creates inherits that. Three of those threads matter:
#
#     emulation thread   runs the machine, ~17% of core 3
#     effects thread     MAME's sound worker; sound_manager::run_effects() is
#                        what calls osd().sound_stream_sink_update(), so THIS
#                        thread is the audio producer, not the emulation thread
#     thread-loop        PipeWire's client loop; fills and queues the buffers
#
# Under SCHED_RR a thread that wakes at EQUAL priority does not preempt the
# running one. It waits until that thread blocks or exhausts its timeslice, and
# /proc/sys/kernel/sched_rr_timeslice_ms on this kernel is 100. The emulation
# thread is runnable almost continuously, so the two audio threads only ran when
# it happened to block. Measured with /proc/<tid>/schedstat over 10 s:
#
#     emulation thread   ran 1127 ms, waited on the runqueue    0.3 ms
#     thread-loop        ran   51 ms, waited on the runqueue  532.5 ms
#     effects thread     ran   12 ms, waited on the runqueue 1013.3 ms
#
# The consequence is not jitter, it is loss. The effects thread delivered ~10%
# of the audio the machine generated; the rest was never handed over at all.
# abuffer::get() padded the shortfall by repeating the last sample, and the
# prebuffer path filled whole buffers with zeros - a capture of the codec's
# monitor ports was 84% digital silence. Audio produced per second of wall
# clock, as a fraction of realtime:
#
#     all threads SCHED_RR 20 (before)      9.7%
#     audio threads SCHED_FIFO 60 (after) 101.6%
#
# and in steady state 99.8% with underruns=0, overruns=0, at a 64-frame quantum.
#
# This also explains the one result that made no sense for weeks: MAME's own
# -wavwrite was always CLEAN while everything downstream crackled. -wavwrite is
# written by streams_update() on the EMULATION thread, upstream of the effects
# thread, so it never saw the loss.
#
# The durable fix belongs inside MAME - the sound threads should set their own
# priority rather than inherit the emulation thread's. Until that patch exists,
# this runs from mpcpi-emulator.service's ExecStartPost.
set -eu

prio=${MPC_AUDIO_THREAD_PRIORITY:-60}
tries=${MPC_AUDIO_THREAD_TRIES:-30}

pid=""
i=0
while [ "$i" -lt "$tries" ]; do
    pid=$(pgrep -x mpc | head -1 || true)
    [ -n "$pid" ] && [ -d "/proc/$pid/task" ] && break
    i=$((i + 1))
    sleep 1
done
[ -n "$pid" ] || { echo "mpc-audio-thread-priority: no mpc process" >&2; exit 1; }

# Identify the emulation thread as the one with the most CPU time. On this
# appliance the gap is ~30x (17% against 0.5%), so require a clear margin rather
# than demoting an audio thread by accident during startup.
ranked=$(for t in "/proc/$pid/task/"*; do
        [ -r "$t/stat" ] || continue
        printf '%s %s\n' "$(awk '{print $14 + $15}' "$t/stat")" "${t##*/}"
    done | sort -rn)

top=$(echo "$ranked" | sed -n 1p)
second=$(echo "$ranked" | sed -n 2p)
top_ticks=${top%% *}; emu=${top##* }
second_ticks=${second%% *}

if [ -z "$emu" ] || [ "$top_ticks" -lt $(( (second_ticks + 1) * 3 )) ]; then
    echo "mpc-audio-thread-priority: emulation thread not yet distinguishable" \
         "(top=$top_ticks second=$second_ticks); not touching priorities" >&2
    exit 1
fi

raised=""
for t in "/proc/$pid/task/"*; do
    tid=${t##*/}
    [ "$tid" = "$emu" ] && continue
    if chrt -f -p "$prio" "$tid" 2>/dev/null; then
        raised="$raised $tid($(cat "$t/comm" 2>/dev/null))"
    fi
done

printf 'mpc-audio-thread-priority: emulation thread %s left at SCHED_RR %s; raised to SCHED_FIFO %s:%s\n' \
    "$emu" "$(chrt -p "$emu" 2>/dev/null | tail -1 | sed 's/.*: //')" "$prio" "$raised"
