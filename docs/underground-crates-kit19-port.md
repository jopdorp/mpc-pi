# Parked port: Underground Crates Kit 19 to MPC3000/MPC60

## Status

Parked after audition. The rendered `UC Kit 19` preview sounded good enough to
keep, but the supplied project targets the MPC500/1000/2500/5000 generation and
is not directly readable by the MPC3000, MPC60, or MPC2000XL.

Source archive:

```text
/home/jopdorp/Downloads/underground-crates-free.zip
```

The archive passed `unzip -t`. Its relevant native files identify themselves
as `MPC1000 PGM 1.00` and `MPC1000 SEQ 4.00`:

```text
Legacy MPC/MPC1000-5000-2500-500/Underground Crates Free Edition/
  Kits/UC Kit 19.PGM
  Sequences/UC Kit 19.SEQ
```

The archive also contains a 12.8-second rendered reference:

```text
Standalone MPC-Akai Force/The Underground Crates - Free Edition/
  [Previews]/UC Kit 19.mpcpattern.wav
```

## Why this needs a port

An MPC2500 can save a sequence as Standard MIDI File, but it cannot export a
complete pre-MPC1000 project. It does not write MPC3000/MPC60 SND files or the
older PGM/ALL formats. The practical bridge is therefore:

```text
MPC1000/2500 SEQ -> Standard MIDI File
MPC1000 PGM      -> pad/sample mapping
WAV samples      -> short-name SND samples
MIDI + PGM + SND -> MPC3000 project, then reduced MPC60 variant
```

## Source sample references

`UC Kit 19.PGM` references these sixteen WAV sample names in pad order:

```text
UC kik 030
UC snr 049
UC chh 015
UC ohh 023
UC cwb 001
UC clp 021
UC shk 015
UC crs 021
UC kik 031
UC snr 050
UC tmb 015
UC rid 019
UC bass 019 A
UC chord 026 A
UC chord 027 D
UC chord 029 A
```

All sixteen corresponding WAV files are present. Their combined size is too
large for one 1.44 MB floppy and likely too large for an untrimmed MPC60
project, so the MPC3000 port should be completed first.

## Port procedure

1. Extract `UC Kit 19.PGM`, `UC Kit 19.SEQ`, and the sixteen referenced WAVs
   into an ignored work directory under `.cache/free-projects/`.
2. Convert the sequence to Format 1 Standard MIDI File:
   - Preferred reference route: load `UC Kit 19.SEQ` on an MPC1000/2500 and use
     **Save a Sequence**, selecting `MID` rather than `SEQ`.
   - Offline route: implement or verify an `MPC1000 SEQ 4.00` to SMF converter,
     then compare its event count, tempo, bars, tracks, note numbers, velocity,
     and timing against the rendered preview.
3. Determine which pads are actually triggered by the sequence. Do not carry
   unused samples into the memory-constrained MPC60 version.
4. Assign FAT-safe names of at most eight characters before building floppy
   images. Keep one checked name map for the WAV filename, SND internal name,
   and legacy PGM reference; DOS aliases such as `UCCHOR~1` will otherwise
   break program references.
5. Convert each used WAV to signed 16-bit PCM at the target rate, then convert
   it to Akai SND with the cached MPC2000 File Converter:

   ```bash
   sox input.wav -b 16 output.wav rate -v 44100
   .cache/tools/MPC2000-File-Converter/build/mpc2000 wav2snd output.wav
   ```

6. Rebuild an old-format PGM with the original MIDI-note-to-pad assignments,
   tuning, level, pan, and mute-group settings. This can be done either with a
   verified format converter or interactively on the emulated MPC3000 after
   loading the SND files from multiple floppy images.
7. Import the Standard MIDI File as a sequence, select the rebuilt program on
   its drum track, and save a native MPC3000 project (`ALL + PGM + SND`).
8. Capture playback and compare it with `UC Kit 19.mpcpattern.wav`. The port is
   accepted only when arrangement, tempo, swing/timing, pad choices, and loop
   boundary agree by ear and by waveform timing.
9. Create the MPC60 version from the accepted MPC3000 project using Vimana
   3.15/3.10-compatible firmware. Reduce it to the samples actually triggered,
   convert stereo material to mono where appropriate, trim tails, and use
   20 kHz compression only as needed to fit MPC60 memory. Re-audition rather
   than assuming the reduced version sounds equivalent.

## Resume point

The next concrete task is the sequence bridge: obtain a trusted SMF export or
write and validate an `MPC1000 SEQ 4.00` parser. The samples, program reference
list, preview, conversion utility, and legacy MAME targets are already present.
