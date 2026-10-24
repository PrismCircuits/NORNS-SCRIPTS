# Panspectra

Spectral resynthesis for norns

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

## Filter

A resonant multimode filter on the resynthesized (wet) signal, before the
output and the feedback path. Page 10: cutoff (20 Hz - 20 kHz) and
resonance; page 11: type (lowpass / bandpass / highpass). The default is
lowpass fully open, which is transparent.

## Grid (128)

Main view: the frequency spectrum across all 128 keys (low to high, left to
right), with the resynthesized partials lit brightest.

Hold the bottom-left key to open the menu. While holding it:

- bottom row, keys 2-7: choose a page
  1. main: voices, slice rate, freeze, capture
  2. window: center, bandwidth, threshold, stability, blur
  3. resynthesis: pitch, freq shift, waveform, flatten, glide
  4. output: stereo spread, feedback, dry/wet, input gain, output level
  5. auto snap: snap mode, rate (or division in sync mode), chance
  6. filter: type, cutoff, resonance
- rows 1-7 show that page, one parameter per row

Release after choosing a page (or editing) and the page stays open; tap the
bottom-left key again to go back to the spectrum. Holding and releasing it
without choosing anything also returns to the spectrum.

On a page:

- sliders: keys 1-14 set the value, 15 / 16 nudge it down / up
- choices (filter type, snap mode, division): one key per option
- freeze toggles, capture fires a snapshot

The norns screen briefly shows each parameter's name and value as you
change it on the grid.
