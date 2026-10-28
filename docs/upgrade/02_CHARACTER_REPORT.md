# Phase 2 report — character v2 and logo (28 Oct 2026)

Branch: `upgrade/phase-2`. No new dependencies. Default look: A (lineage);
human can re-pick with one script flag + one Lab tap.

## 1. What changed

- `lib/companion/v2/frame.dart` (new): `MiloLod`, `DirectorFrame` snapshot,
  `gainFor`/`gazeTravelDesign`/`breathAmpFor`/`browEnds`/`mouthShape`/
  `isPressedShut`/`colorways` (all pure + tested), `LookParams` (A/B/C).
- `lib/companion/v2/look.dart` (new): `MiloLook` enum, dependency-free.
- `lib/companion/v2/renderer.dart` (new): `MiloRenderer` interface,
  `LegacyRenderer` (pixel-identical old painter), `V2Renderer`,
  `MiloPainter2`, `lodForSize` (≥180 full, ≥90 bust, else avatar).
- `lib/companion/v2/milo2.dart` (new): v2 painter — tight 200-unit viewbox,
  full/bust/avatar LODs, motion gain + physical minimums (gaze ≥5/3/2 dp,
  breath ≥2 dp, brow ≥3 dp bust), sclera/iris/pupil/2 highlights, curved
  lids, tapered-arc brows, face patch + cheeks, rim light + subtle outline,
  9 mouth shapes, 2.5D parallax, separate lagging head, two-bone arms +
  hands, shuffling feet (look C: legs), sprout with emotion flare, fx port.
- `lib/companion/v2/rive_stub.dart` (new): throws until a real `.riv` exists.
- `lib/companion/milo_view.dart`: v2 default, Lab `legacyRenderer` toggle,
  explicit/auto LOD, per-renderer sprout zones.
- `lib/companion/emotion.dart`: C3 fixed — happy/curious/thinking/playful
  brows flipped to raised; `curious` gets one-up `browAsym`; `Face.browAsym`.
- `lib/companion/director.dart`: 6 new clips (`tilt_head clap lean_back
  thinking_hmm soft_sigh peek`), 20-behaviour idle library (+ `idleGaze`/
  `idleFull`, `debugFidget`), `MiloReact` handler (rate-limited,
  presence-aware), thinking ladder (1.5 s hmm, 5 s honest offer +
  `choose`/`useOfflineFallback`), speech anticipation + settle, mood
  baseline + `daysTogether`, pooled greetings, 14-cue `_sfx` wiring,
  `look`/`legacyRenderer`/`soundOn`/`soundVol` + settings keys.
- `lib/companion/react.dart`, `greetings.dart` (72 lines en/hi/ml),
  `sounds.dart` (new): reaction hub, deterministic pools, gated sound API
  (no-op backend until a playback package is resolved — see §6).
- `lib/ui/theme.dart`, `chat_screen.dart`: hooks in BigButton/RowCard/
  PastelTile/PillTabs, chat field (watch/type/scroll/send) + controller
  dispose fix; `lib/ui/scaffold.dart`: LODs on Stage/Buddy/Avatar (buddy
  width guarantees ≥120 dp body), dock chips via `choose()`.
- Contract +6 gestures: `contracts/brain_contract.json`,
  `lib/contracts/brain_contract.dart` (gateway/prompts read the JSON).
- `tools/make_sounds.py` + `assets/sounds/*.wav` (14, <600 ms, stdlib,
  deterministic); pubspec gains `assets/sounds/`.
- `tools/make_logo.py`: 3 PIL concept mockups (labeled reference only),
  60 lookdev PNGs (3 looks × 5 expr × 4 sizes) + contact sheet (light/dark/
  coloured + squint + greyscale) in `docs/upgrade/phase2/`, SVG masters,
  finals from `--concept` (default A): icon/icon_fg/**icon_mono**
  (Android 13+ themed)/icon_noti/splash. Pubspec gains
  `adaptive_icon_monochrome`. `make_branding.py` superseded (kept).
- `docs/CHARACTER_RIG_SPEC.md`, `docs/THIRD_PARTY.md` (new, versions read
  from pubspec), `docs/SETUP.md` cmd note, `docs/upgrade/phase2/
  expression_sheet_A.png` + `score_form.md` (blind-test kit).
- `lib/ui/dev/milo_lab.dart`: renderer toggle, look picker, idle fire
  buttons, v2 dp math, mood/days readout.
- `test/v2_test.dart` (new, 15 tests).

## 2. Tests run

- Gateway contract units (real): 6 passed after the gesture add.
- `flutter analyze` / `flutter test`: NOT RUN (no SDK/network). New Dart
  verified by review + API cross-checks; `test/v2_test.dart` is pure-Dart
  (no pumps) plus one guarded `Director.init()` for the reaction test.
- `tools/make_sounds.py`: 14 WAVs written, all <600 ms (asserted).
- `tools/make_logo.py`: 61 PNGs + 6 branding files; contact sheet and
  dark/concerned/curious renders **visually inspected**: dark-bg face bug
  (ImageDraw replace-vs-blend) found and fixed via a soft layer; lids
  re-curved; concerned/curious read warm, never angry.

## 3. Measurements vs acceptance

- Body: buddy ≥120 dp by construction (width rule); stage 38–45% (Phase 1);
  chip 44–56 face-only — implemented, device-UNVERIFIED.
- Angry-brow unit test: all 12 faces pass by construction (test runs in CI).
- Fill ≥85% all LODs (design assertion + test). Golden 12×3×2: need a
  device run (`--update-goldens`) — human.
- Reaction: hub→Director mutation is synchronous (same call; first changed
  frame = next tick, <100 ms at 60 fps) — asserted in test.
- 10 s fake-clock test: breath range ≈2 + gaze retargets — asserted.
- 55 fps / p50/p95: need DevTools on device — human.
- Board <200 ms, reduce-motion/quiet/AAC gates: preserved (renderer gates
  on `aac`/`quiet`; fidget caller gates unchanged).
- Logo legible at 48 px (contact sheet inspected) and matches the v2 Milo.

## 4. UNVERIFIED and why

Everything needing Flutter (analyze, unit/widget tests, goldens, fps,
lip-sync feel, sound audibility) or ears/eyes on device. Playback package
unresolved (no network): sounds queue silently with haptic/visual
equivalents intact. Splash-12 dims + notification-icon dims follow the
previous script's values; Android-doc check still open (no network).

## 5. Found but not fixed

`make_branding.py` has the same replace-vs-blend translucency bug; it is
superseded by `make_logo.py` (kept for history). ProfileCfg `greet` strings
are now unused (pools replaced them) — kept for compat.

## 6. Decisions needed

1. Pick look A/B/C (contact sheet ready; A is the working default).
   Re-pick = `python tools\make_logo.py --concept B` + Lab look switch.
2. Approve the 6 contract gestures (implemented; gateway auto-reads JSON).
3. Audio playback package (provisional: audioplayers) — needs network to
   resolve a version; say the word and it is a one-line backend swap.

## 7. Next: Phase 3 first tasks

1. Gateway `providers/registry.py` + `capabilities.py` + error codes.
2. `openai_compat` + `anthropic` adapters + conformance suite.
3. CLI `connect/list/test/use` + vault migration + SSRF guard.
