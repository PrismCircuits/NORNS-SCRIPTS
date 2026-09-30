# Stereo Comb Delay v3.5

IMPORTANT:
Install this folder exactly as:

    /home/we/dust/code/stereo_comb_delay/

Main script:

    /home/we/dust/code/stereo_comb_delay/stereo_comb_delay.lua

Engine:

    /home/we/dust/code/stereo_comb_delay/lib/Engine_StereoCombDelay.sc

Delete/rename any older duplicate folders such as:
- /home/we/dust/code/Stereo Comb Delay/
- /home/we/dust/code/Comb Filter/

The running screen displays `v3.5` in the upper-right so you can verify Norns is loading this exact build.

v3.5 verified behavior:
- Both L/R modulation depths are forced to 0% after params:bang().
- The DSP engine itself is explicitly sent modDepthL=0 and modDepthR=0 at startup.
- Footer uses normal 8px font at full brightness:
  K2 LINK                  K1+K2 RESET


## v3.6

- Removed K1 + E1 spread adjustment completely. Spread remains E3 on the Delay / Spread page.
- Key help now reads, in order:
  - K1+K2 RESET
  - K2 LINK
  - K3 L/R EDIT
- Key help uses the normal 8px interface font.
- Header and page content moved inward for a safer top border.
- Bottom key help is split across two rows so none of the requested wording is compressed off-screen.
- Running screen displays v3.6 in the upper-right for build verification.


## v3.7

- Shortened the K3 footer label from `K3 L/R EDIT` to `K3 L/R` to reduce screen clutter.
- Running screen displays v3.7 in the upper-right.


## v3.8

- All K-function hints moved into one dedicated bottom row.
- Footer order:
  `K1+K2 RESET    K2 LINK    K3 L/R`
- Parameter area is left uncluttered above the footer.
- Running screen displays v3.8 in the upper-right.


## v3.9

- Spread readout moved down slightly for more even vertical spacing.
- Removed the on-screen version number.
- Upper-right corner now displays only the active stereo mode:
  `LINK`, `SEP L`, or `SEP R`.


## v4.0

- Separate edit mode labels changed from `SEP L` / `SEP R` to `EDIT L` / `EDIT R`.
- Spread readout moved lower for more even spacing.


## v4.1

- Spread range increased from 0–40 ms to 0–120 ms.
- Spread now matches the script's full maximum delay-time range.


## v4.2

Modulation waveform selector added.

On the MODULATION page only:
- Hold K1 to open the waveform list.
- While holding K1, turn E1 to highlight:
  Sine, Saw, Ramp, Square, Random Step, or Random Smooth.
- Release K1 to commit the highlighted waveform and return to the normal modulation page.
- K1 + E1 has no waveform function on any other page.

The waveform parameter is also available in PARAMS as `mod waveform`.
Both channels use the selected waveform while retaining their independent L/R depth and rate settings.
Random Step and Random Smooth generate independently for left and right.


## v4.3

- On the MODULATION page, pressing and holding K1 now opens the waveform list immediately.
- E1 is only needed to move through the waveform choices.
- Releasing K1 still commits the highlighted waveform and returns to the normal modulation display.


## v4.4

- Startup/help text simplified to controls and pages only.
- Added `Written by Skyler King`.
- Header lines shortened and spaced to fit comfortably inside the norns help screen.


## v4.5

- Added extra top margin to the startup/help screen so the first title line is fully visible.
