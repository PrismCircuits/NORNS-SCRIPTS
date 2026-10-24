# Panspectra

Spectral resynthesis for norns, inspired by the Rossum Panharmonium.

The input is analysed with an FFT; each "slice", spectral peaks inside a
frequency window are tracked and played back on a bank of up to 33
wavetable voices.

## Install

Install this folder as:

    /home/we/dust/code/panspectra/

Main script:

    /home/we/dust/code/panspectra/panspectra.lua

Engine:

    /home/we/dust/code/panspectra/lib/Engine_PanSpectra.sc

Restart norns (SYSTEM > RESTART) after installing so the new engine is compiled.

## Controls

- E1: page
- E2 / E3: adjust
- K2: freeze
- K3: capture slice (while frozen)

## Auto snap

While frozen, Panspectra can capture new slices on its own, like an LFO
pressing K3 for you. Set it on page 9 (or in PARAMS > auto snap):

- snap mode: off / free / sync
- rate: in free mode, 0.1-20 Hz; in sync mode, a clock division (4 bars to 1/16)
- snap chance (PARAMS only): probability that each tick actually captures

While frozen (and only then), blur becomes the morph time between frozen
states: each capture (K3 or auto snap) crossfades from the held sound to the
new one. Partials that carry over glide in pitch, new ones fade in, gone ones
fade out. The blur readout shows the time in seconds while frozen: 0 is
instant, 50% is 2 s, 99% is about 8 s. When live, blur smooths the spectrum
as before.

A small square blinks next to FROZEN when a snap fires. Captures happen on
the engine's next slice, so very slow slice rates delay them.
