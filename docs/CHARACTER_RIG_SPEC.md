# Milo character rig spec (for a future Rive asset)

The shipped Milo is the code-drawn v2 renderer (`lib/companion/v2/milo2.dart`).
This spec exists so a Rive asset can replace it later **without touching the
Director**: the `.riv` state machine must accept the same inputs the v2
renderer reads from `DirectorFrame`, and `RiveRenderer`
(`lib/companion/v2/rive_stub.dart`) becomes the adapter. Do not add the
`rive` dependency until a real, properly licensed `.riv` file exists.

## Layer names

`shadow | legs | feet | armL | armR | body | bodyOcclusion | bodySheen |
sproutShadow | sproutStem | leafL | leafR | cheekL* | cheekR* | eyeL | eyeR |
lidUpL | lidUpR | lidLoL | lidLoR | browL | browR | mouth | fx | particles`
(`cheek*` = three nested soft layers per cheek: outer/mid/core diffused blush.)

There is deliberately **no** `head` disc and no `facePatch`: the face sits
directly on the body volume. Arms are single-piece curved limbs in the body
colour, drawn behind the body so the shoulders melt into the volume; the
sprout is one smooth stem with a single pair of plump tip leaves.

Eyes are nested artboards: `eye` contains `sclera | iris | pupil | hi1 | hi2`.
Brows are soft short rounded arcs (reduced alpha) with skewable inner/outer
ends — expressive, never harsh wedges.

## State-machine inputs (1:1 with DirectorFrame channels)

| Input | Type | Range | Source |
|---|---|---|---|
| `gazeX`, `gazeY` | number | -1..1 | `eyeX`, `eyeY` |
| `headX`, `headY` | number | design units | `headX`, `headY` |
| `eyeOpen` | number | 0.05..1.4 | `blinkOpen` (+ listening widen) |
| `browInnerL/R`, `browOuterL/R` | number | design units | `browEnds(face)` + curious asym on R |
| `mouthOpen` | number | 0..1.2 | `mouth` (audio envelope in Phase 4) |
| `mouthSmile` | number | -1..1 | `face.smile` |
| `mouthShape` | number (enum 0..8) | `MouthShape` order | `mouthShape()` |
| `breath` | number | -1..1 | `breath` |
| `lean` | number | radians | `lean` |
| `armL`, `armR` | number | radians | `armL`, `armR` + clip channels |
| `sprout1..3` | number | radians | `s1..s3` |
| `hop`, `squash` | number | design units | `hop`, `squash` |
| `clipTilt/Dip/Zoom/Jig/Yawn/Lean` | number | mixed | `ch*` channels |
| `fx` | text | `dots/arcs/zzz/spark/''` | `fx` |
| `listening`, `happyEyes`, `tongue` | boolean | — | same names |
| `micLevel` | number | 0..1 | `micLevel` |
| `bodyColor` | color | — | `color` (3 tones derived by lightness ±) |
| `lod` | number (enum 0..2) | full/bust/avatar | `lod` |

## Clips (names + durations, seconds)

`wave 1.2, nod .6, shrug .9, point 1.0, lean_in 1.0, think 1.6, celebrate 2.2,
giggle .9, yawn 2.0, stretch 1.8, hum 1.5, dizzy 1.2, pet 1.5, tilt_head 1.0,
clap 1.1, lean_back 1.2, thinking_hmm 1.8, soft_sigh 1.6, peek 1.2`
(Director `_dur` is the single source; keep in sync.)

## Mouth and eye shape sets

Mouth: rest, smile, big smile, open A, open O, closed M/B/P, small frown,
flat, tongue — interpolated by (`mouthSmile`, `mouthOpen`).
Eyes: open (sclera/iris/pupil/2 highlights), happy-squint arcs, lidded
(upper + lower lids by `eyeOpen`), blink (160 ms, ±40 ms asymmetry).

## Export settings and budgets

Rive runtime (not Rive Lite); 60 fps; vector only, no embedded raster;
state machine on the main artboard. File-size budget: ≤ 300 KB. Colourways:
re-tint `bodyColor` only (see `colorways()`). Licence: the `.riv` must be
commissioned or created in-house with full rights; record the grant in
`docs/THIRD_PARTY.md`. Never ship AI-generated raster art as the character.
