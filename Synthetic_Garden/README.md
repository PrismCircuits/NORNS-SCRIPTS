# Synthetic Garden v0.89
## Four Track Scanning Looper for Monome Norns
**Written by Skyler King**

Synthetic Garden is a four-track mono looper built around a scanning mixer. Four recorded loops are arranged across a virtual garden from left to right. The scanner moves through them, crossfading between neighboring loops according to the current **Scan Position** and **Width**.

Each loop can be recorded, imported, trimmed, pitched, panned, reversed or ping-ponged. A stereo delay sits after the scanner.

---

# QUICK START

1. Go to **RECORD**.
2. Select Loop 1.
3. Press **K2** to record.
4. Press **K2** again to stop recording. The loop begins playing.
5. Record additional loops the same way.
6. Go to **GARDEN**.
7. Turn **E1** to manually scan between the four loops.
8. Press **K2** to enable Auto Scan.
9. Press **K3** to cycle the scanner motion.
10. Adjust **E2** for Width and **E3** for Rate.

Hold **K1 + turn E1** from any page to choose:

**GARDEN / RECORD / TRIM / RANGE / DELAY**

---

# 1. GARDEN

The GARDEN page is the main performance page.

The scanner travels through:

**Silence → Loop 1 → Loop 2 → Loop 3 → Loop 4 → Silence**

## Norns controls

| Control | Function |
|---|---|
| E1 | Manual Scan Position when Auto Scan is off |
| E2 | Scan Width |
| E3 | Scan Rate |
| K2 | Auto Scan On / Off |
| K3 | Cycle Scan Mode |

### Scan modes

- **Forward**
- **Reverse**
- **Ping Pong**
- **Step Random**
- **Smooth Random**

### Width

Width determines how much neighboring loops overlap.

A narrow Width gives more isolated loop regions.  
A wider Width creates broader crossfades between loops.

### Rate

Auto Scan ranges from approximately:

**0.005 Hz – 10 Hz**

The encoder uses finer steps at slow rates and progressively larger steps at faster rates.

---

# 2. RECORD

The RECORD page manages the four loop slots.

Each loop is mono, with independent:

- Pan
- Pitch
- Play / Stop state
- Recording

Maximum recording length is approximately **30 seconds per loop**.

## Norns controls

| Control | Function |
|---|---|
| E1 | Select Loop 1–4 |
| E2 | Pan selected loop |
| E3 | Pitch selected loop, ±12 semitones |
| K2 | Record / Stop Recording |
| K3 | File / Play / Stop |

### Recording

On an empty loop:

**K2** starts recording.

While recording:

**K2** stops recording and begins playback.

### Playback

When a loop contains audio:

**K3** toggles Play / Stop.

### Importing audio

When the selected loop is empty:

**K3** opens the file selector.

### Pitch

Pitch changes use tape-style varispeed.

Range:

**-12 to +12 semitones**

Changing pitch also changes playback speed.

---

# 3. TRIM

TRIM is the detailed loop editor.

The OLED shows the recorded waveform, Start point, End point, active loop length and moving playhead.

## Norns controls

| Control | Function |
|---|---|
| E1 | Select Loop 1–4 |
| E2 | Adjust Start / move established window |
| E3 | Adjust End |
| K2 | Copy loaded loop / Paste into empty loop |
| K3 | Delete loaded loop / Record into empty loop |
| Hold K2 + K1 | Toggle ZX / FREE |
| Hold K2 + E3 | Select Forward / Reverse / Ping Pong |
| Hold K2 + K3 | Toggle BOUND / CHASE |

The trim encoders use adaptive acceleration: slow turns provide fine adjustment while faster turns move farther.

Minimum trim length is approximately **5 ms**.

## BOUND

BOUND keeps playback constrained to the currently selected Start and End points.

When the trim region is changed, playback is brought directly into the new valid loop region.

## CHASE

CHASE lets the playhead move naturally toward newly edited loop boundaries rather than immediately forcing it inside them.

This is useful when changing loop points during playback and you want a smoother transition.

## ZX

**ZX = Zero Crossing**

Start and End edits search near the requested position for a nearby zero crossing. This can reduce clicks when looping tonal or sustained material.

## FREE

FREE places trim boundaries directly at the requested position without zero-crossing correction.

## Loop direction

Each loop can independently play:

- **Forward**
- **Reverse**
- **Ping Pong**

## Copy / Paste

On a loaded loop:

**K2 = Copy**

On an empty loop:

**K2 = Paste**

The internal clipboard holds one copied loop.

---

# 4. RANGE

RANGE provides precise control of the scanner travel limits.

## Norns controls

| Control | Function |
|---|---|
| E1 | Scan Mode |
| E2 | Scan Start |
| E3 | Scan End |

Start and End determine the region through which Auto Scan travels.

The range includes the silence zones before Loop 1 and after Loop 4.

---

# 5. DELAY

Synthetic Garden includes a stereo delay after the four-loop scanner.

Use:

- **E1** to select a parameter bank
- **E2** to select one of the three parameters
- **E3** to change the selected value

## CORE

| Parameter | Range / Function |
|---|---|
| Time | 30–2000 ms |
| Feedback | 0–92% |
| Mix | Dry / Wet |

## CHARACTER

| Parameter | Function |
|---|---|
| Tone | Dark ↔ Bright |
| Wow | Slow delay-time modulation |
| Flutter | Faster delay-time modulation |

## STEREO

| Parameter | Function |
|---|---|
| Spread | Separates left and right delay times |
| Ping Pong | Cross-feeds delay feedback between channels |
| Stereo Width | Controls stereo placement of the delay |

---

# GRID 128 MANUAL

Synthetic Garden supports a standard **16 × 8 Monome Grid / compatible Grid 128**.

Rows are numbered from **top to bottom**.  
Columns are numbered **1–16 from left to right**.

The bottom-left five buttons always select pages:

```text
ROW 8

[x1] [x2] [x3] [x4] [x5]
 GAR  REC  TRM  RNG  DLY
```

Selected page = bright.  
Other page buttons = dim.

---

# GRID — GARDEN PAGE

```text
ROW 1   SCAN RANGE
[01][02][03][04][05][06][07][08][09][10][11][12][13][14][15][16]

ROW 2   MANUAL SCANNER POSITION
[01][02][03][04][05][06][07][08][09][10][11][12][13][14][15][16]

ROW 3   SCAN WIDTH
[01][02][03][04][05][06][07][08][09][10][11][12][13][14][15][16]

ROW 7   SCAN RATE
[01][02][03][04][05][06][07][08][09][10][11][12][13][14][15][16]

ROW 8                              SCAN MODES                  AUTO
[PG][PG][PG][PG][PG].....[FWD][PP][REV][STEP][SMTH][AUTO]
 1   2   3   4   5         11   12   13   14    15    16
```

## Row 1 — Scan Range

Hold one button for the first range point, then press a second button for the other range point.

Example:

**Hold x4 → press x13**

The scanner range becomes x4 through x13.

A single tap does not change the range.

If the scanner is outside the newly selected range, it smoothly catches up to the nearest valid point.

## Row 2 — Scanner Position

Press any button to immediately place the scanner at that position.

- x1 = far left
- x16 = far right

This also works while Auto Scan is running. Auto Scan continues from the newly selected location.

## Row 3 — Width

Direct 16-step Width control.

- x1 = 0%
- x16 = 100%

## Row 7 — Rate

Direct logarithmic Rate control.

- x1 ≈ 0.005 Hz
- x16 = 10 Hz

This gives more useful resolution at slow scanner speeds.

## Row 8 — Scanner Modes

| Button | Mode |
|---|---|
| x11 | Forward |
| x12 | Ping Pong |
| x13 | Reverse |
| x14 | Step Random |
| x15 | Smooth Random |
| x16 | Auto / Manual |

The mode LEDs animate to preview the motion type.

---

# GRID — RECORD PAGE

```text
ROW 1   PITCH  -12 ......................................... +12
[01][02][03][04][05][06][07][08][09][10][11][12][13][14][15][16]

ROW 2   PAN     LEFT ....................................... RIGHT
[01][02][03][04][05][06][07][08][09][10][11][12][13][14][15][16]

ROW 8
[PG][PG][PG][PG][PG] .. [T1][T2][T3][T4] . [REC][PLAY][STOP][DEL]
 1   2   3   4   5        8   9  10  11      13   14    15   16
```

## Row 1 — Pitch

The whole row covers **-12 to +12 semitones**.

Single buttons provide anchor pitches:

| Grid | Pitch |
|---|---:|
| x1 | -12 |
| x2 | -10 |
| x3 | -9 |
| x4 | -7 |
| x5 | -6 |
| x6 | -4 |
| x7 | -3 |
| x8 | -1 |
| x9 | +1 |
| x10 | +3 |
| x11 | +4 |
| x12 | +6 |
| x13 | +7 |
| x14 | +9 |
| x15 | +10 |
| x16 | +12 |

Adjacent two-button combinations fill the missing semitones:

| Hold + Press | Pitch |
|---|---:|
| x1 + x2 | -11 |
| x3 + x4 | -8 |
| x5 + x6 | -5 |
| x7 + x8 | -2 |
| x8 + x9 | 0 |
| x9 + x10 | +2 |
| x11 + x12 | +5 |
| x13 + x14 | +8 |
| x15 + x16 | +11 |

## Row 2 — Pan

- x1 = hard left
- x16 = hard right

The illuminated button shows the current pan position.

## Row 8 — Track / Transport

| Button | Function |
|---|---|
| x8 | Track 1 |
| x9 | Track 2 |
| x10 | Track 3 |
| x11 | Track 4 |
| x13 | Record |
| x14 | Play |
| x15 | Stop |
| x16 | Delete |

When a selected loop contains audio, **Delete flashes quickly** as a warning.

---

# GRID — TRIM PAGE

The first four rows represent all four recordings simultaneously.

```text
ROW 1   LOOP 1 TIMELINE
[01][02][03][04][05][06][07][08][09][10][11][12][13][14][15][16]

ROW 2   LOOP 2 TIMELINE
[01][02][03][04][05][06][07][08][09][10][11][12][13][14][15][16]

ROW 3   LOOP 3 TIMELINE
[01][02][03][04][05][06][07][08][09][10][11][12][13][14][15][16]

ROW 4   LOOP 4 TIMELINE
[01][02][03][04][05][06][07][08][09][10][11][12][13][14][15][16]

ROW 6
[BOUND][CHASE] . [ZX][FREE]

ROW 7
.............................. [FWD][PP][REV] . [COPY][PASTE]
                                  11  12  13       15    16

ROW 8
[PG][PG][PG][PG][PG] .. [T1][T2][T3][T4] . [REC][PLAY][STOP][DEL]
 1   2   3   4   5        8   9  10  11      13   14    15   16
```

## Rows 1–4 — Loop Timelines

Each row represents the complete recorded length of one loop:

- Row 1 = Loop 1
- Row 2 = Loop 2
- Row 3 = Loop 3
- Row 4 = Loop 4

The active trim region is brighter than the unused area.

Start and End points are brightest.

Each row also shows that loop's moving playback position.

### Establish or redefine a trim region

Hold the desired **Start** position and press an **End** position on the same row.

You can continue holding the original Start button and press additional End destinations. Each new End press immediately redefines the range.

Example:

**Hold x3 → press x10 → press x12 → press x8**

The original x3 anchor remains active until you release it.

### Move an established trim window

Once a trim window has been established, a single tap moves the entire fixed-length window.

The tapped position becomes the new Start location.

The loop length remains unchanged.

If moving the window would extend beyond the end of the recording, it is clamped to the furthest valid position.

### ZX and FREE apply to Grid trim edits

In **ZX**, requested Grid positions are adjusted toward nearby zero crossings.

In **FREE**, positions are used directly.

## Row 6 — Trim Behavior

| Button | Function |
|---|---|
| x1 | BOUND |
| x2 | CHASE |
| x4 | ZX |
| x5 | FREE |

The active option is bright.

## Row 7 — Direction / Clipboard

| Button | Function |
|---|---|
| x11 | Forward |
| x12 | Ping Pong |
| x13 | Reverse |
| x15 | Copy |
| x16 | Paste |

Direction buttons use animated LED previews.

Paste works when the destination loop is empty.

## Row 8 — Track / Transport

| Button | Function |
|---|---|
| x8 | Track 1 |
| x9 | Track 2 |
| x10 | Track 3 |
| x11 | Track 4 |
| x13 | Record |
| x14 | Play |
| x15 | Stop |
| x16 | Delete |

Delete flashes when the selected track contains audio.

---

# GRID — RANGE PAGE

The RANGE page currently uses the Norns encoders for editing.

The Grid still provides the five permanent page-select buttons on Row 8:

```text
x1 GARDEN
x2 RECORD
x3 TRIM
x4 RANGE
x5 DELAY
```

---

# GRID — DELAY PAGE

The DELAY page currently uses the Norns encoders for editing.

The Grid still provides the five permanent page-select buttons on Row 8.

---

# LED BRIGHTNESS GUIDE

Synthetic Garden uses several LED levels to communicate state:

- **Bright** — selected value, endpoint, active control or active page
- **Medium** — active range / clipboard state
- **Dim** — available control or guide
- **Flashing x16 Delete** — selected track contains audio and can be deleted

---

# PERFORMANCE WORKFLOW

A useful basic workflow:

1. Record four different textures on the RECORD page.
2. Set each track's Pitch and Pan.
3. Use TRIM to isolate useful regions of each recording.
4. Choose Forward, Reverse or Ping Pong independently for each loop.
5. Return to GARDEN.
6. Set the scanner Start / End range.
7. Adjust Width to control how much neighboring loops blend.
8. Choose an Auto Scan mode.
9. Increase Rate for rhythmic scanning or slow it down for evolving textures.
10. Add DELAY for spatial movement and feedback.

Because the scanner extends into silence before Loop 1 and after Loop 4, the system can naturally fade completely out at either end of its travel.

---

# NOTES

- Four mono loop tracks.
- Maximum recording length: approximately 30 seconds per track.
- Pitch range: ±12 semitones.
- Scan Rate: approximately 0.005–10 Hz.
- Delay Time: 30–2000 ms.
- Delay Feedback: up to 92%.
- TRIM minimum loop length: approximately 5 ms.
- Audio trimming is non-destructive: the original recorded buffer remains intact while playback Start and End points are changed.
