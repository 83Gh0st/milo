# Phase 5 report - safe multimodal agent + §0.1 leftovers (28 Oct 2026)

Branch: `upgrade/phase-3` (uncommitted). No new dependencies. No secrets.
Rule: the model proposes, the app disposes - every tool is a closed,
validated `ui` action; nothing new can send, call, buy, or change the device.

## 1. What changed (files, one line each)

- `contracts/brain_contract.json` - `ui.action` enum +3: `read_aloud`,
  `break_into_steps`, `lookup_word`, with `span`/`steps`/`word` shapes.
- `gateway/app/safety.py` - Assembler validates the three tools (span
  `w\d{1,4}`, steps ≤8×140ch cleaned, word letters-only); invented tools
  and malformed args are dropped. Fixed clean-then-cap (junk entries no
  longer eat the 8-step budget).
- `gateway/app/contract.py` - `brain_schema()` ui items carry the
  `steps`/`word` properties schema-strategy providers need.
- `gateway/app/prompts.py` - `UI_ACTIONS` + advertised arg shapes in
  JSON + LINES prompts ("Never invent other actions or tools").
- `gateway/tests/test_contract_units.py` - 8-action assertion + new fields.
- `gateway/tests/test_gateway.py` - assembler tools test; vision-fallback
  test (blind primary skipped for image turns, kept for text).
- `lib/contracts/brain_contract.dart` - `kActions` + `BrainTurn`
  readAloud/steps/lookupWord + identical validation (incl. collapse).
- `lib/companion/director.dart` - `onReadAloud/onSteps/onLookupWord`
  callbacks, fired from batch and streamed turns.
- `lib/core/providers.dart` - `ChatMsg.steps/imageB64`, `addSteps`,
  `userPhoto`, `lookupWordProvider`, callback wiring (lookup navigates
  to Understand); blind-model image failure speaks the honest line
  instead of opening `unreachable`.
- `lib/media/photo.dart` (new) - shared `preparePhoto`: resize, EXIF
  wipe, original deleted.
- `lib/ui/chat_screen.dart` - `_StepsCard` checklist with check-off
  and "Save to Do" visible confirmation (Do-shape compatible);
  photo thumbnails with semantic label; camera button kept.
- `lib/ui/understand_screen.dart` - `_listenFrom` read-aloud entry,
  lookup prefill (consume-once), photo path reuses `preparePhoto`.
- `test/contract_test.dart` (new) - 6 tests: tool accept/drop/trim/cap,
  kActions mirror, batch + streamed callback firing.
- `test/agent_test.dart` (new) - 4 widget tests: steps save-to-Do,
  blind-model honesty (no `unreachable` navigation), check-in count,
  lookup prefill.
- `test/helpers/harness.dart` - `FakeApi.understand` stub + `blindError`
  flag.

## 2. Tests run (real commands, real output)

- `cd gateway; python -m pytest tests\test_voice_units.py
  tests\test_phase3_units.py tests\test_contract_units.py --noconftest
  -p no:cacheprovider -o addopts='' -q -W ignore` → **42 passed**
  (exit 0). The contract test first failed honestly (schema lacked the
  new fields); fixed `contract.py`, green.
- Scratch probe of the two new `test_gateway.py` bodies (dep-free
  modules, loop-free driver, no-op `_timeout`): tools gate OK
  (3 ui events, junk dropped, 8 capped steps); vision fallback OK
  (`seeing` for image turns, `blind` primary for text, 93 pieces).
  `asyncio.run` is sandbox-blocked (socket); CI runs the real loop.
- `python -m py_compile` on edited gateway files → exit 0.
- `flutter analyze` / `flutter test`: NOT RUN locally (no SDK); every
  new Dart call site was signature-checked by reading. CI verifies.

## 3. Measurements vs acceptance

- Capability-aware turns: image understand passes `need="vision"`
  (pre-existing link, now tested); all-blind degrades to a spoken
  honest line naming AI connections (tested, no wrong-screen nav).
- Closed registry: 3 read-only tools, validated twice (gateway +
  Dart), prompts forbid invention; save-to-Do needs the visible tap.
- Multimodal: camera → shared photo prep → existing Understand route;
  ledger records the send (pre-existing `_ledger` path).
- No false claims: blind models never get the picture (router skips);
  failures name the cause, never "offline" for a capability miss.
- §0.1: check-in counts locked by test; time-of-day greetings verified
  present (`greetingFor` hour buckets + daysTogether); crop box and
  wardrobe documented as deferred (see §6).

## 4. UNVERIFIED and why

- Flutter analyze/test incl. the 10 new Dart tests (no local SDK).
- Gateway full suite + live provider smoke (no deps/keys/network).
- Camera/OCR/photo send, spoken honest line, lookup navigation, and
  the steps card on a real phone (needs device + human eyes/ears).
- iOS `Pods_Runner` link failure still open on main (diagnostic added).

## 5. Found but not fixed

- Ladder shows `offline` after a capability miss (mapping is
  code-based); the spoken line is accurate, the chip is approximate.
- Wardrobe/accessory slots were never stubbed (no `accessory` symbol
  in `lib/companion`); cosmetic, deferred, not started.

## 6. Decisions made (defaults, human can override)

- Crop box: CUT - full resized photo, EXIF stripped, original deleted.
  Say the word and a crop UI goes in front of `preparePhoto`.
- Wardrobe: DEFERRED - no slots, no UI, until the product meaning
  (unlock? settings?) is decided.
- Time-of-day/biometric/photo-tiles: stay cut per 00_AUDIT §3.

## 7. Next: the human's three moves

1. On `upgrade/phase-3`: commit per task (named files only), push,
   watch CI (`flutter`, `ios-compile-check`, `gateway`).
2. Sideload the APK artifact; test offline first, then AI with
   `--dart-define=API_BASE=<gateway>`.
3. Human gates still open: 2A character look, 4A voice winner, live
   provider keys, legal/crisis review.
