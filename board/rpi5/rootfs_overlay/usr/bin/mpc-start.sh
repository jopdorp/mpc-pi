#!/bin/sh
# Launch the emulator with the deployment settings. Mirrors
# scripts/run-mpc2000xl-turbo.sh, minus the desktop PipeWire graph juggling:
# on the appliance this process owns the audio device.
set -eu

# Must match S30pipewire, or the emulator cannot find the daemon's socket.
export XDG_RUNTIME_DIR=/run/pipewire

ROMS=${MPC_ROMS:-/usr/share/mpc-pi/roms}
PROJECT=${MPC_PROJECT:-/data/project.img}
LCD_EXPORT=${MPC_LCD_EXPORT:-/dev/shm/mpc-lcd}

# Cores 2-3 are isolated in cmdline.txt for the emulation thread.
CPUS=${MPC_CPUS:-2,3}

# Keep the cores out of deep idle for the session; C-state exit latency lands
# directly in the input path.
if [ -w /dev/cpu_dma_latency ]; then
	exec 9<>/dev/cpu_dma_latency
	printf '\0\0\0\0' >&9
fi

export MAME_MPC_LCD_EXPORT="$LCD_EXPORT"
export MAME_MPC_PANEL_HLE=${MPC_PANEL_HLE:-1}
export MAME_MPC_DSP_DMA_TURBO=${MPC_DSP_DMA_TURBO:-8}
export MAME_MPC_MIDI_POLL_HZ=${MPC_MIDI_POLL_HZ:-8000}
export MAME_MPC_VELOCITY_CURVE=${MPC_VELOCITY_CURVE:-half}
export MAME_MPC_MIDI_INTERNAL_PADS=1
export MAME_MPC_PANEL_EVENT_DRIVEN=1
export MAME_MPC_PANEL_TIMER_COALESCED=1
export MAME_MPC_V53_BRK88_HLE=1
export MAME_MPC_V53_BRKFD_HLE=1
export MAME_MPC_V53_BRK92_HLE=1
export MAME_MPC_V53_BRK77_HLE=1
export MAME_MPC_V53_DIRECT_DISPATCH=1
export MAME_MPC_V53_DIVIDE_SUPERBLOCK=1
export MAME_MPC_V53_FETCH_WINDOW=1
export MAME_MPC_V53_IDLE_SKIP=1
export MAME_MPC_LCD_SKIP_UNCHANGED=1
export MAME_MPC_STEREO_ONLY=1

# The Maschine input bridge writes MIDI into a snd-virmidi port; the emulator
# reads the same port. PortMidi names ALSA virmidi ports "Virtual Raw MIDI
# <card>-<dev>"; adjust MPC_MIDIIN if the card order differs on real hardware.
MIDIIN=${MPC_MIDIIN:-Virtual Raw MIDI 1-0}

set -- mpc mpc2000xl \
	-rompath "$ROMS" \
	-video none -sound pipewire -samplerate 44100 \
	-midiin1 "$MIDIIN" \
	-skip_gameinfo -nomaximize
[ -f "$PROJECT" ] && set -- "$@" -flop "$PROJECT"

exec chrt -r 20 taskset -c "$CPUS" "$@"
