# The timer clock topology (quantum 32)

Every hardware device on the appliance was measured as graph driver and
disqualified: the phantom I2S card (no DAC wired) cannot promise a
726us period and its EPIPE recovery kills the session; the USB gadget's
cycle follows the connected computer's pull cadence (Ardour at 1000%
load under a default arecord). This pair of fragments makes PipeWire's
own timer the driver instead:

  * `95-mpcpi-clock.conf` -> /etc/pipewire/pipewire.conf.d/
    a null-audio-sink named mpcpi-clock, priority.driver 5000,
    node.group mpcpi-audio, always processing.
  * `97-mpcpi-driver-group.conf` -> /etc/wireplumber/wireplumber.conf.d/
    REPLACES the stock 97-mpcpi-driver.conf: every ALSA node joins
    node.group mpcpi-audio, so driver election happens in one group and
    the clock wins it.

Measured on 2026-08-16, armed lp0 + emulator at quantum 32: Ardour's
own xrun counter ZERO across five consecutive reports, driver-late
count zero. The graph is clean at 32 on this topology.

NOT yet the default, for two reasons, both honest:
  * the board dropped off the network during the first long run under
    this topology and the crash is unattributed;
  * the delivered-audio certification over the gadget did not complete -
    the host-side capture EIO'd (f_uac2 has wedged before after many
    graph restarts; a gadget bounce cured it that time).

Promote only after: a survived 10-minute armed q32 soak, a clean 60s
continuity capture, and an attributed or absolved crash.
