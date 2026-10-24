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
