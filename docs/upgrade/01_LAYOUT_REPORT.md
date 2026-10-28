# Phase 1 report — layout system (28 Oct 2026)

Branch: `upgrade/phase-1`. No new dependencies.

## 1. What changed

- `lib/ui/scaffold.dart` (new): window classes, `isWideLayout`, `MiloScaffold`
  (header + content + dock/rail, no overlay positioning), `MiloHeader`,
  `StatusChip` + status sheet, `CompanionDock` (64 dp peek, remembered per
  screen kind, auto-peek on keyboard/large text), `CompanionRail` (280–360 dp),
  `MiloStage`/`MiloBuddy`/`MiloAvatar` (size from space), `ladderWords`.
- `lib/main.dart`: Shell rebuilt — per-tab scaffolds, `NavigationBar` compact /
  `NavigationRail` otherwise (side follows handedness), status chip replaces
  banners + top row, Milo speaks once per ladder change (Shell-level,
  quiet-aware), OS×in-app text scale clamped [0.85, 2.4].
- `lib/ui/screen.dart`: `MiloScreen` reimplemented on `MiloScaffold` (same
  params; `noHeader` now means "no back button"); `Overlays` deleted;
  `export 'scaffold.dart'` so all screens get the presence widgets.
- `lib/ui/theme.dart`: `ScreenHeader` deleted (replaced by `MiloHeader`).
- `lib/companion/milo_view.dart`: `buddy` flag, tab-scope + route visibility
  checks, inline-always-wins gaze registration, re-measure on scroll end (L7).
- `lib/companion/director.dart`: `registerMilo`, `peeked` set persisted as
  `local.peeked` (never synced).
- `lib/core/providers.dart`: `miloScopeProvider`; `LadderNotifier.dispose`
  cancels its timer/subscription (also fixes a prod leak on rebuild).
- `lib/data/db.dart` + `progress_screen.dart`: new `weekCounts()` moves the
  last raw-SQL call out of UI (behavior-identical) so tests can use the fake.
- Screens migrated (mechanical): home, explore, chat (header→button row,
  full-width input + mic + send), progress, more, do, understand, calm,
  failure, onboarding. Deleted: 4 in-list headers, 12 magic spacers, 19
  fixed-size Milo boxes, chat `right: 120`. Kept deliberately: calm breathing
  circle + `BreakOverlay` (deliberate circular crops, not overlay bugs).
- `lib/ui/calm_screens.dart`: check-in taps record `progress('checkin')`
  (wireframe 9.1 "counts only"; answers still never stored).
- `test/helpers/fake_db.dart` (new): in-memory `MiloDb` (exact signatures).
- `test/helpers/harness.dart`: `kMatrixSizes` (8), connectivity mocks,
  `FakeApi` (no network), `screenOverrides`, `pumpScreen` (bounded pumps).
- `test/layout_test.dart` (new): tab matrix (5×8×2×2 crowded pumps), pushed
  matrix (8×4×2 + left-handed spot), crowded-controls presence, dock/rail vs
  header non-overlap, tap-target guidelines ×2, keyboard-peek test.

## 2. Tests run

- Gateway contract units (real): `cd gateway; python -m pytest
  tests/test_contract_units.py --noconftest -p no:cacheprovider
  -o addopts='' -q -W ignore` → **6 passed**.
- `flutter analyze`, `flutter test`: NOT RUN — no Flutter SDK or network in
  this environment. New/changed Dart verified by review + leftover searches
  (`Overlays`/`ScreenHeader`/`right: 120`/fixed Milo boxes: zero matches).
  CI runs both when the human pushes. Layout tests were designed to be
  deterministic (canned providers, mocked channels, bounded pumps).

## 3. Measurements vs acceptance

- Zero-overflow matrix, non-overlap asserts, tap targets, keyboard peek:
  implemented in `test/layout_test.dart`, UNVERIFIED until CI/human runs it
  (see §6). Before/after screenshots: need a device run (human).
- Dock/content separation is structural now (Column/Row, no `Positioned` for
  content) — verified by reading every screen's new tree.
- Existing tests untouched and unaffected (settings round-trip gains one
  inert `local.peeked` key).
- Justified deviation: "wide when short side < 480" is landscape-only in
  `isWideLayout`, else every portrait phone would classify as wide.
- Justified deviation: `MiloAvatar` is the full drawing at 48 dp until the
  Phase 2 face-only LOD; matrix runs representative sizes/scales for pushed
  screens (full 8×3×2 available in the helper).

## 4. UNVERIFIED and why

Everything needing Flutter: analyze, widget/layout tests, goldens (no
reference PNGs yet — human runs `--update-goldens` once), screenshots,
device matrix, keyboard/viewInsets behavior, labeled-tap-target pass,
`connectivity_plus` channel names (isolated in `mockConnectivity`; CI
fails loudly with a one-line fix if renamed).

## 5. Found but not fixed

iOS `Pods_Runner` link failure on `main` (diagnostic step committed, output
pending). Pre-existing unlabeled tappables outside More may fail the labeled
guideline — fix by adding tooltips where CI points.

## 6. Decisions needed

None blocking. Note: pushed-screen matrix is a representative subset; say
the word if you want the full 8×3×2 everywhere (slower CI).

## 7. Next: Phase 2 first tasks

1. V2 renderer behind `MiloRenderer` (direction A default) + LODs + motion gain.
2. Brow/mouth/eye upgrades + idle library + shared-widget reaction hooks.
3. Sounds script + playback package pick; gestures ×6 through the contract.
