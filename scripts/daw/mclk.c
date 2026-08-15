/* Minimal ALSA-seq MIDI clock sender for the Phase 2 sync PoC.
 *
 * Emits MIDI Start (0xFA) then a continuous 24 PPQN clock (0xF8) on a seq
 * queue so timing comes from the kernel timer, not usleep. PipeWire's
 * Midi-Bridge exposes the port to the JACK graph, where the harness links
 * it to Ardour's "MIDI Clock in".
 *
 *   gcc -O2 -o mclk mclk.c -lasound
 *   ./mclk [bpm] [start_delay_s]   (default 120, 0; runs until killed)
 *
 * start_delay_s: create the port, then wait before emitting Start. Ardour's
 * MIDI Clock master only rolls after it sees Start/Continue, so the harness
 * needs time to link the port before the Start goes out.
 */
#include <alsa/asoundlib.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
	double bpm = argc > 1 ? atof(argv[1]) : 120.0;
	int start_delay = argc > 2 ? atoi(argv[2]) : 0;
	snd_seq_t *seq;
	if (snd_seq_open(&seq, "default", SND_SEQ_OPEN_OUTPUT, 0) < 0) {
		perror("snd_seq_open");
		return 1;
	}
	snd_seq_set_client_name(seq, "mclk");
	int port = snd_seq_create_simple_port(seq, "clock",
		SND_SEQ_PORT_CAP_READ | SND_SEQ_PORT_CAP_SUBS_READ,
		SND_SEQ_PORT_TYPE_MIDI_GENERIC | SND_SEQ_PORT_TYPE_APPLICATION);
	int queue = snd_seq_alloc_named_queue(seq, "mclk");
	if (port < 0 || queue < 0) {
		fprintf(stderr, "port/queue alloc failed\n");
		return 1;
	}

	/* 24 clocks per quarter note; schedule in ticks with the queue tempo
	 * set so one tick == one clock. */
	snd_seq_queue_tempo_t *tempo;
	snd_seq_queue_tempo_alloca(&tempo);
	snd_seq_queue_tempo_set_tempo(tempo, (unsigned)(60e6 / bpm));
	snd_seq_queue_tempo_set_ppq(tempo, 24);
	snd_seq_set_queue_tempo(seq, queue, tempo);
	if (start_delay > 0) {
		fprintf(stderr, "mclk: port up, starting in %d s\n", start_delay);
		poll(NULL, 0, start_delay * 1000);
	}
	snd_seq_start_queue(seq, queue, NULL);
	snd_seq_drain_output(seq);

	snd_seq_event_t ev;
	snd_seq_ev_clear(&ev);
	snd_seq_ev_set_source(&ev, port);
	snd_seq_ev_set_subs(&ev);

	ev.type = SND_SEQ_EVENT_START;
	snd_seq_ev_schedule_tick(&ev, queue, 0, 0);
	snd_seq_event_output(seq, &ev);

	/* Keep ~2 s of clocks queued ahead; top up twice a second. */
	unsigned tick = 0;
	for (;;) {
		snd_seq_queue_status_t *st;
		snd_seq_queue_status_alloca(&st);
		snd_seq_get_queue_status(seq, queue, st);
		unsigned now = snd_seq_queue_status_get_tick_time(st);
		while (tick < now + (unsigned)(2.0 * bpm / 60.0 * 24.0)) {
			ev.type = SND_SEQ_EVENT_CLOCK;
			snd_seq_ev_schedule_tick(&ev, queue, 0, tick++);
			snd_seq_event_output(seq, &ev);
		}
		snd_seq_drain_output(seq);
		poll(NULL, 0, 500);
	}
}
