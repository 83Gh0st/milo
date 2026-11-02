# Phase 0 audit - evidence before change (28 Oct 2026)

Branch: `upgrade/phase-0`. Scope: brief §2 re-verification, original-plan gap map
(§0.1), connection check, Milo Lab, layout harness. No new dependencies
(`docs/THIRD_PARTY.md` unchanged - nothing to record).

## 1. What changed (files, one line each)

- `lib/net/api.dart`: `healthDetails()` + `connectionCheck()` + `ConnStatus` +
  pure `connectionWords()` (About row data; never throws, no secrets).
- `lib/core/providers.dart`: `connectionCheckProvider` (refreshable health check).
- `lib/ui/more_screen.dart`: About gains Connection section + `ConnectionCheckRow`;
  version long-press opens the Lab (debug only).
- `lib/ui/dev/milo_lab.dart` (new): 12-expression × 3-size previews, 13 clip
  buttons, gaze pad, text-scale + motion-gain sliders, quiet/reduce/left-hand
  toggles, live Director readout, layout-derived dp per preview.
- `lib/companion/director.dart`: `motionGain` (default 1.0, never persisted)
  multiplied into `amp`; `clipNames` getter (single source `_dur`).
- `test/helpers/harness.dart` (new): `kHarnessSizes`, Lexend `FontLoader`,
  `pumpAtSizes()`, `expectNoOverlap()`.
- `test/lab_test.dart` (new): `connectionWords` unit tests; Lab widget tests;
  Lab at harness sizes without overflow.
- `docs/SETUP.md`: §1b Windows `cmd` gateway + 3 phone-connection ways + Docker
  mock note (compose has no published ports - VPS-oriented).

## 2. Section-2 verification (every item re-read in code)

Layout: L1 CONFIRMED (`screen.dart:43-50` exact), L2 ✓ (`main.dart:102-111`,
`more_screen:20`, `chat_screen:27`), L3 ✓ (150/120/150/80 exact), L4 ✓
(`chat_screen:43` `right: 120`), L5 ✓ (16 `SizedBox(height)` MiloViews + 56×56
Do + 40×40 Chip ≈ brief's "~20"; all 5 cited examples exact), L6 ✓
(`main.dart:31` replaces OS scale), L7 ✓ code / runtime UNVERIFIED
(`milo_view:17-21` + `IndexedStack` `main.dart:110`), L8 ✓ (0 `LayoutBuilder`
in `lib/ui`; `test/` = 2 logic files; CI has no layout check).

Character: C1 ✓ (buddy k=0.42 → body ≈55×58, eye ≈7, gaze ±1.9/±1.5,
breath ±0.9 dp - recomputed, matches), C2 ✓ (ink ovals+dot, straight 3.5
brows, one-path mouth, static side ovals, belly oval only), C3 ✓ (brow
geometry hand-verified: happy/curious/thinking/playful have inner-ends-low;
pocket fallback is curious), C4 ✓, C5 ✓ (13 clips, fidget 12–25 s), C6 ✓ (no
audio dep; chirps "not built"), C7 COUNT DIFFERS - 36 call lines / 40 matches
across 10 files, not 18 - substance ✓ (zero hooks in shared `widgets.dart` /
`theme.dart`; no scroll/typing/focus hooks), C8 ✓ (8 contract gestures, 13
clips), C9 ✓ (`milo_view:37` direct `MiloPainter`).

AI: B1 ✓ (default `10.0.2.2`, resting banner, pocket fallback; the
"screenshot was pocket brain" claim itself needs the human's screenshot),
B2 ✓ (`main.py:44-49` mock/meta, OpenAI SDK, empty registry, muse-/sam- +
`PROVIDER=meta` enforcement), B3 ✓ (single Fernet key per vault, 401/409 no
fallback `sync.py:102-159`, hardcoded `'meta'` `trusted_screen:122`,
no-OAuth statement in `BYOK.md`), B4 ✓ (SSE + validator, `LINES`,
ledger-first, rate/budget).

Voice: V1 ✓ (`flutter_tts` only, presets `director:178-188`), V2 ✓ (progress
handler + `_est` fallback, no envelope), V3 ✓ (`voice.dart` WS + `micRms`,
`routes.py:226` `/v1/voice`), V4 ✓ (`performStream`/`pump`, no server TTS or
audio package), V5 ✓ (plan §2: "text out only … speech is a separate
free TTS").

## 3. Per-workstream: exists / partial / missing

- Layout: exists - 5 tabs + 10 pushed screens, overlays, banners. Partial -
  presence boxes (fixed sizes), text scale (replaces OS), left-handed (chat
  input wrong). Missing - scaffold with reserved space, window classes,
  landscape/tablet/fold, widget tests. Change plan (Phase 1):
  `screen.dart` (MiloScaffold), `main.dart` (chrome→status chip, scaler fix,
  L7 fix), all screens (spacers→dock, fixed Milo boxes→MiloStage/Buddy/Avatar).
- Character: exists - Director engine (springs, 13 clips, fidgets, gaze,
  drowse, barge-in), 12 faces, CustomPainter. Partial - motion below
  visibility at shipped sizes, 4 faces share angry brow geometry. Missing -
  renderer interface, LODs, idle library, shared-widget hooks, sounds, logo
  match. Change plan (Phase 2): `companion/v2/`, `emotion.dart` brow fix,
  `director.dart` idle/hooks, `tools/make_sounds.py`, `assets/branding/*`.
- AI: exists - ledger-first SSE contract, mock+meta adapters, budget/rate
  guards, single-key BYOK, pocket brain. Partial - provider hardcoded,
  one key. Missing - registry, discovery/probe, routing/failover, connections
  UI, data policies. Change plan (Phase 3): `gateway/app/providers/*`,
  `vault_connections`, `app/cli.py`, `trusted_screen.dart` connections.
- Voice: exists - platform TTS + presets + voice picker, word-pulse mouth,
  cloud STT with live levels. Partial - read-aloud highlight (callback
  dependent). Missing - neural TTS, `/v1/speak`, envelope lip-sync,
  barge-in ≤150 ms proof. Change plan (Phase 4): bake-off, `VoiceOutput`
  split, gateway speak, turn-taking machine.
- Original plan (§0.1) gaps → phases: crop box → Phase 5 or cut (needs
  decision); check-in counts → Phase 1 (small); wardrobe → Phase 2D
  (daysTogether); time-of-day, biometric, photo tiles → cut unless human
  decides; Rive → 2F stub; SAM/offline-STT/switch/P2-system → cut (plan
  stretch/P2); Drift→sqflite, in-memory limiter stay (documented).

## 4. Tests run (real commands, real output)

- `cd gateway; python -m pytest -q` → exit 4, collection error:
  `ModuleNotFoundError: No module named 'httpx'` (deps not installed, no
  network to install). Full gateway suite UNVERIFIED here.
- `cd gateway; python -m pytest tests/test_contract_units.py --noconftest
  -p no:cacheprovider -o addopts='' -q -W ignore` → **6 passed in 0.04s**.
- `flutter analyze`, `flutter test`: NOT RUN - no Flutter SDK and no network
  in this environment. New Dart code verified by review only; CI runs both
  when the human pushes (brief forbids pushing from here).

## 5. Measurements vs Phase 0 acceptance

- Audit written: yes (this file). Lab runs / connection on phone / baselines
  saved: UNVERIFIED (need SDK + phone + human `--update-goldens` run).
- No behaviour change elsewhere: by construction (additive UI; `motionGain`
  1.0 = identical `amp`; Lab `kDebugMode`-only) - review-verified, CI pending.
- C1 dp (analytic, Lab will show live): stage(200h)→body≈90, buddy→body 55×58
  eye 7.1 gaze ±1.9 breath ±0.9, chip(40)→body ≈17. Matches brief.
- Vendor/doc rule: no new vendor claims. Riverpod `overrideWith` /
  `overrideWithValue` used from knowledge in tests only - isolated, CI
  confirms. Compose/Docker statements verified against repo files, 28 Oct.

## 6. UNVERIFIED and why

Flutter analyze/test, Lab visuals, connection row on a phone, mock-over-Docker
(one-liner in SETUP §1b), full-screen goldens (additionally blocked on a
MiloDb test seam - `MiloDb._` is private, so screens touching `dbProvider`
cannot pump in tests; Phase 1 needs a `DbPort` seam), L7 last-writer logging.

## 7. Found but not fixed (out of phase)

iOS `Pods_Runner` link failure on `main` (diagnostic step committed, output
pending next CI run); check-in answers uncounted; `analysis_options.zip` +
`.gitignore` edit in working tree (user's, untouched); `_plan_extract.tmp`
removed after reading.

## 8. Decisions needed from the human

None blocking Phase 1. Later: crop box (build/cut), time-of-day behaviour,
ARASAAC vs emoji, biometric unlock, Phase 2A look + 4A voice gates (brief §5).

## 9. Next phase's first three tasks

1. `DbPort` seam behind `dbProvider` + first full-screen pump test (More).
2. `MiloScaffold` skeleton + window classes on one tab; delete its spacers.
3. Human: push `upgrade/phase-0` → read CI analyze/test → run
   `flutter test --update-goldens` once to bless Lab baselines.
