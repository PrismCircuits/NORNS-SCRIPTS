# Speculation

Polyphonic granular synth for norns, with a grid 128 keyboard

Record or load a sample, then play it as clouds of grains from MIDI, the
grid, or a held drone. The screen shows the waveform with every grain the
engine plays drawn on top: where it landed, how it moves through the sample,
its envelope, and its stereo pan.

## Install

Install this folder as:

    /home/we/dust/code/speculation/

Main script:

    /home/we/dust/code/speculation/speculation.lua

Engine:

    /home/we/dust/code/speculation/lib/Engine_Grainery.sc

Restart norns (SYSTEM > RESTART) after installing so the new engine is compiled.

If you have an older `grainery` folder in `dust/code`, delete it first. Both
contain `Engine_Grainery`, and two engines with the same name stop
SuperCollider from starting.

## Controls

- K2 tap: record on / off
- K2 hold (0.5 s): browse and load a sample from `dust/audio`
- K3: drone on / off
- K1 hold + E2 / E3: position / scan speed
- E1: open the menu, then change page
- E2 / E3 (in the menu): select / adjust

The menu returns to the sample screen after 5 seconds without input.

## Sample screen

The full screen shows the sample and its grains:

- each grain is a line that starts where it landed and grows as it reads
  through the sample, brightening and fading with the grain envelope
- height is the grain's pan: left at the top, right at the bottom
- the dim band around each playhead is the spray range
- the tall line is the position setting; ticks at the top and bottom are
  each voice's playhead

## Recording

Recording stops exactly when you press K2 again; the take is trimmed to what
was recorded, loaded and saved to `dust/audio/grainery/`. `rec length` (PLAY /
REC page) is the maximum length. In looping mode a take that runs past it
keeps the last `rec length` seconds, oldest audio first.

## Grains

GRAIN page: position, scan speed, spray, grain size, density, pitch spray,
sides and tilt (grain shape), pan, pan spray, spawn random, scan mode and
scan key sync.

- sides: how much of each grain is fade in / out (100% smooth bell, 0%
  almost square)
- tilt: where the grain peaks (-1 early and plucky, +1 late and swelling)
- spawn random: grain timing, from evenly spaced (0%) to fully random (100%),
  at the same average density

## Drone

K3 holds a drone at the drone root (PLAY / REC page). It starts on unison;
changing the chord, root or velocity while it plays updates it straight away,
without restarting the notes.

## Grid (128)

A LinnStrument-style keyboard: each pad to the right is a semitone higher,
each row up a fourth. Grid notes play just like MIDI notes, through the
amp and filter envelopes, at a fixed grid velocity. Root and scale notes are
lit; a held note lights every pad with the same pitch, as do drone and MIDI
notes.

The GRID page appears in the menu when a grid is connected (and disappears
when it is unplugged). The grid is found on any of ports 1-4.

- grid keyboard: on / off
- lowest note: note of the bottom-left pad (default C2)
- row interval: semitones per row (default a fourth)
- key / scale lights: which notes are lit
- grid velocity: level of grid notes
- note > pos: higher notes play later parts of the sample, like key
  tracking that moves through the sample instead of pitch
- pos span: semitones that cover the whole sample (default 24), then it wraps
- pitch: fixed (every note at the sample's pitch) or tracks

## Also

- 8-slot mod matrix (LFOs, envelopes, velocity, modwheel, aftertouch, crow
  CV, keytrack, random) to position, scan, spray, size, density, pitch, pitch
  spray, cutoff, resonance, pan, amp and spawn random
- multimode filter with envelope, two LFOs with cross mod
- distortion, bit reducer, ping-pong delay, reverb
- three keyboard zones with their own pitch and position offsets
- MIDI in (notes, modwheel, aftertouch, sustain, pitch bend), crow CV in and
  gate out
