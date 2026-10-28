# Plan completion report — P0/P1 acceptance + P2 (28 Oct 2026)

Branch: `upgrade/plan-gaps` (8 commits, no push). Directive: finish the
build/architecture plan's P0, P1 and P2 on top of Phases 0–5 (all committed
on `upgrade/phase-3`). No new dependencies. No secrets. No paid calls.

## 1. What changed (files, one line each)

P0/P1 acceptance gaps:
- `lib/ui/calm_screens.dart` — check-in counts now opt-in
  (`checkin.counts`, default off) per plan 7.11.
- `lib/ui/trusted_screen.dart` — report extended: This week + All time,
  quiet-week copy, check-in toggle + gated row.
- `lib/ui/home_screen.dart` — pre-reader Settings pictogram button (7.9).
- `lib/ui/progress_screen.dart` — wardrobe tiles wired to real persisted
  looks A/B/C with selection ring (were decorative).
- `gateway/app/safety.py` — `no_new_content` moved here (dep-free).
- `gateway/app/routes.py` — imports the guard; behavior unchanged.
- `gateway/tests/test_wording_units.py` (new) — plan 7.5: 50 cases.
- `gateway/tests/test_gateway.py` — guard import follows the move.
- `test/helpers/harness.dart` — `FakeApi` cloud fakes write one ledger
  entry each; `cutStream` flag for mid-stream failure.
- `test/ledger_test.dart` (new) — 7.10: 100 mixed calls → 100 entries,
  metadata-only; 7.12: mid-stream cut degrades to pocket + resting.
- `test/regression_test.dart` — 7.7 chips-payload test; 7.10 pause test.
- `eval/run_eval.py` — full sizes: 40/20/20/50/20 safety/inject/
  simplify/compose/memory, 20 hi + 20 ml, strategy × 20 pairs.

P2 (plan 12.1):
- `lib/companion/director.dart` — `scanMode`/`scanMs` persisted settings.
- `lib/ui/more_screen.dart` — Accessibility: scanning toggle + speed.
- `lib/ui/express_screen.dart` — board auto-scan (tiles + More + Speak +
  Clear); urgent row always direct; holds during Speaking view.
- `lib/sys/share_in.dart` (new) — `milo/share` channel: late + cold-start.
- `lib/core/providers.dart` — `sharedTextProvider` (consume-once).
- `lib/ui/understand_screen.dart` — consumes shared text like a lookup.
- `lib/main.dart` — arms share-in; cold-start routes to Understand.
- `docs/7_13_NATIVE.md` (new) — exact Android snippets, surface order,
  headless Core API table; iOS/keyboard/a11y marked pending.
- `gateway/app/providers/capabilities.py` — `visual_ground` capability.
- `gateway/app/providers/mock.py` + `mock_adapter.py` — `MockGround`,
  adapter passthrough, probe pass.
- `gateway/app/providers/meta_adapter.py` — `SAM_ENDPOINT_UNVERIFIED`
  (None) + honest refusal + probe skip line.
- `gateway/tests/test_phase3_units.py` — 9-capability shape + ground test.
- `test/agent_test.dart` — scan ×2, report ×2, share-in ×2, check-in
  opt-in update.
- `test/v2_test.dart` — hi/ml greetings across all hour buckets.

## 2. Tests run (real commands, real results)

- `cd gateway && python -m pytest tests\test_wording_units.py
  tests\test_voice_units.py tests\test_phase3_units.py
  tests\test_contract_units.py --noconftest -p no:cacheprovider
  -o addopts='' -q -W ignore` → **44 passed** (exit 0).
- `python -m py_compile eval\run_eval.py` → exit 0; AST count confirms
  40/20/20/50/20/20/20 list sizes.
- `python eval\voice_bakeoff\run.py --list` → exit 0, 5 SKIPPED with
  reasons; `--dry-run` → exit 0 (out/ removed after).
- `flutter analyze` / `flutter test`: NOT RUN (no SDK here). All 19 new
  Dart tests + edited widgets were signature-checked by reading only.
  CI is the verifier after push.

## 3. Acceptance accounting (value + evidence)

P0 (all ship): alive Milo (phases), onboarding skip/replay/airplane
(code-read ✓), Home Stage/Chip (phase 1), Express compose/quick-help/
voices/offline (code-read ✓) + 50 wording tests (ran ✓), Understand
paste/photo/key-points/simple/read-aloud/strategy-switch (code-read ✓),
Do plan/guide/celebrate/Express-handoff (code-read ✓), chat chips +
payload test (new, CI), Voice Transcribe (pre-existing), memory
confirm/viewer/forget/ledger (code-read ✓) + pause test (new, CI),
ladder/failure states (pre-existing) + mid-stream test (new, CI),
a11y basics + scanning (new, CI).
P1 (all ship): Learn word-builder + story, no timers (code-read ✓);
calm space + opt-in counts (new, CI); progress + hide flag (pre-existing,
CI); trusted-adult area, counts-only (reviewed ✓); pre-reader + Settings
pictogram (new, CI); Muse Image explainers (pre-existing route).
P2: sync — pre-existing E2EE, unchanged, CI suite owns it; reports —
built + tested (CI); switch scanning — built + tested (CI); hi/ml —
stack verified (greetings/voice/STT/prompts/TTS) + tests (CI), UI-string
localization needs fluent review; share-in — Dart seam + tests (CI),
native snippets in docs, UNVERIFIED; widget/keyboard/a11y-service/iOS —
docs only (no platform dirs, no SDK: genuinely blocked); SAM — mock +
capability + honest refusal, tested (ran ✓), live use blocked on
docs/key; offline STT — blocked (no model assets offline); Rive —
blocked (no .riv asset; stub + spec exist).

## 4. UNVERIFIED and why

- Everything Dart (analyze + 19 new tests + all widget behavior): no
  local SDK. Pushed branch + CI is the gate.
- Gateway full suite, live provider smoke, eval run, bake-off
  synthesis: no deps/network/keys/device here.
- Share-in/widget/keyboard native halves, iOS everything, TalkBack
  order, 200 ms board speech, fps, STT hi/ml audio, crisis suite on
  device: need hardware + human.
- hi/ml eval lines + greeting lines: written carefully, need the
  plan's fluent-reader spot check.
- iOS `Pods_Runner` link failure (pre-existing on main): untouched.

## 5. Found but not fixed

- Ladder chip reads `offline` after a capability miss (code-based
  mapping); the spoken line is accurate. Cosmetic, noted in 05.
- `analysis_options.yaml` still references uninstallable
  `flutter_lints` (pre-existing CI burden, out of scope).
- `flutter_tts`/`record` plugin upgrade warnings (upstream, CI noise).

## 6. Decisions (defaults; human can override)

- Check-in counts: opt-in, trusted-adult toggle (the plan requires it).
- Wardrobe: looks A/B/C functional; no purchasable cosmetics, ever.
- Keyboard/a11y-service: documented, not built blind (sees all typing;
  needs consent + Play review + a device).
- Offline STT/Rive/live SAM: marked blocked with reasons, not faked.

## 7. Next three moves (human)

1. Push `upgrade/plan-gaps` (never force) and watch CI: `flutter`
   (analyze + the 19 new tests), `gateway` (full pytest incl. eval
   import check), `ios-compile-check`.
2. Sideload the APK artifact: offline first, then AI with
   `--dart-define=API_BASE=<gateway>`; run the 30-min device check.
3. Human gates still open: 2A look, 4A voice, provider keys, fluent
   hi/ml check, legal/crisis review, native 7.13 application.
