# Phase 4 report - Natural voice (bake-off harness + neural pipeline)

Branch: `upgrade/phase-3` (Phase 4 work; push per task when the human has
network). Brief §4 (4A–4C). No new dependencies.

## 1. What changed (files and one line each)

4A bake-off (human-ears gate; artifacts ready, listening pending):
- `eval/voice_bakeoff/run.py` - harness: 12 fixed Milo lines (en+hi+ml),
  engine adapters (OpenAI + Piper real, Azure/Google/ElevenLabs loud stubs),
  blind letters, `RESULTS.md` + `scores.csv` + `key.json`. Honest by
  construction: no engine runs without its key/model AND recorded
  terms_url+terms_date; everything else is SKIPPED with the reason.
- `eval/voice_bakeoff/engines.json` - all engines disabled, terms UNVERIFIED.

Gateway TTS (4B server):
- `gateway/app/voicecore.py` (new, stdlib-only) - wire format (sideband JSON
  line + raw PCM16 mono 24 kHz), 30 Hz peak-normalised envelopes, linear
  resample, WAV parse (stereo fold, honest ValueError), `MockSpeakEngine`
  (deterministic labelled placeholder), `PiperSpeakEngine` (local, no key),
  `OpenAISpeakEngine` (UNVERIFIED shape, isolated), `resolve_engine`
  (vault tts routes + family creds → deployer key → Piper → mock-in-dev →
  honest 503 `no_voice_engine`; chat-model ids never used as TTS models).
- `gateway/app/speak.py` (new) - `POST /v1/speak` (one sentence; ledger is
  client-side; hosted deployer synthesis metered once `speak_price_per_1k`
  is priced, default 0 = unmetered).
- `gateway/app/models.py` - `SpeakReq` (text/lang/profile/voice_id/style/
  sentence_id); `gateway/app/config.py` - `speak_engine/speak_api_key/
  speak_model/piper_voice/speak_price_per_1k`; `gateway/app/main.py` -
  router mount.

App voice pipeline (4B client):
- `lib/voice/normalize.dart` (new, pure) - abbreviations, native-digit
  mapping, en integers→words, emoji strip; lexicon hook with NO invented
  pronunciations; `splitSentences` with word offsets (10/14/20 by profile).
- `lib/voice/voice_output.dart` (new) - `PlatformVoice` (verbatim old
  behaviour), `AudioSink` + `NoopAudioSink` (times honestly, silent),
  `NeuralVoice` (eager prefetch, sequential play, db-backed fixed-line
  cache - mock never cached -, CancelToken barge-in, Lab stats),
  `VoiceRouter` (auto/online/offline; fetch-fail → platform covers incl.
  current; play-fail → skip ahead, never repeat; at most one notice;
  barge-in rethrows with no notice; read-aloud always platform).
- `lib/net/api.dart` - `speakOnline` (+`SpokenSentence`, ledger-before-send,
  sideband parse), `_send` `cancelToken` support, `VoiceCancelled` (cancel
  rethrown, never mapped), `ApiError.detail` (Phase 3, reused).
- `lib/companion/director.dart` - `speak` routes through the router
  (read-aloud keeps ORIGINAL text + single call so highlight indices are
  exact; AAC neutral; `!` → emphasis nod; spoken one-notice fallback);
  `feedMouth` envelope → mouth with tick decay (silence shuts it);
  `CState.endpointing` + `notePartial` + `attenLive` (gaze/head/rings/
  live-dot follow); 25 s stuck-listening self-exit; `clearSpeech`,
  `voiceEngine` (+`vengine`/`clear` settings); `cacheFixedLines`
  (4 greetings + 5 fixed lines, never throws); style preset renamed
  `voice`→`voiceStyle` (settings key `'voice'` unchanged).
- `lib/core/providers.dart` - neural api/cache/`onlineAllowed`
  (ladder==full) wiring.
- `lib/ui/more_screen.dart` - Online voice chips + honest not-yet note,
  clear-speech toggle, offline-lines download button with progress.
- `lib/ui/dev/milo_lab.dart` - live voice card (engine/mode/sink/ready/
  first-audio/queue/mouth) + speak/listen/partial/stop/barge-in buttons.
- `lib/ui/chat_screen.dart` - `notePartial` on STT partials, `attenLive`
  live-dot; `lib/companion/painter.dart`, `lib/companion/v2/frame.dart` -
  `attenLive` rings/frame flag; `lib/ui/express_screen.dart`,
  `lib/ui/widgets.dart`, `lib/ui/onboarding.dart` - `voiceStyle` rename.

Tests:
- `gateway/tests/test_voice_units.py` (new, dep-free) - 10 tests: envelope
  silence/sine/empty, frame round-trip, resample, stereo fold + garbage
  rejection, mock determinism/bounds/shape, resolution (auto→mock,
  3 honest 503s), family-creds-but-settings-model, profile stability.
- `gateway/tests/test_gateway.py` - `/v1/speak` CI test (401/422/200 +
  sideband↔PCM consistency + vault-without-key 409).
- `test/voice_test.dart` (new) - 17 tests: normalizer (4), router
  (auto/offline platform, online+prefetch, read-aloud, fetch/play
  fallback, barge-in ≤150 ms stopNow + no stuck, 100 interruptions with
  maxActive≤1, voice identity), cache (hit + mock never cached), director
  (headless speak, endpointing, mouth envelope+silence, stuck-listening
  exit, AAC <200 ms regression, settings round-trip).
- `test/helpers/harness.dart` - `FakeApi.speakOnline` (call log, delay +
  fail + engine knobs).

## 2. Tests run, real commands and results

- `python -m pytest tests/test_voice_units.py tests/test_phase3_units.py
  tests/test_contract_units.py --noconftest -p no:cacheprovider
  -o addopts='' -q -W ignore` (from `gateway/`) → **42 passed in 0.23 s**
  (10 new voice units; 3 of my first assertions were wrong and fixed -
  silence-window count, envelope shape, ms-rounding).
- `python -m py_compile` over every touched gateway/eval file → exit 0.
- `python eval/voice_bakeoff/run.py --list` → 5 engines SKIPPED with
  reasons, exit 0. `--dry-run` → 12 lines + scores.csv, exit 0. Full run
  with no engines ready → “nothing synthesized”, exit 2. `out/` removed.
- Full gateway suite, `flutter analyze`, `flutter test`: **NOT RUN
  locally** (no fastapi/httpx/SQLAlchemy, no Flutter SDK, no network) -
  CI must run them. The Dart side got a careful static review instead
  (4 real bugs found that way and fixed: num-vs-double pace, missing
  `VoiceRouter.dispose`, `voice`/`voice` field collision, lexicon
  self-overlap; plus 4 design races in the neural queue fixed before
  writing tests: stranded in-flight job, fallback overlap, unobserved
  errors, sink stop-await).
- No listening, no device, no provider keys: every sound/latency/timing
  claim below is UNVERIFIED past unit level.

## 3. Measurements against the acceptance list

- Bake-off samples + results: HARNESS DELIVERED, samples PENDING (needs
  keys/models + the human's machine; decision file when ears have voted).
- p50 first-audio ≤1.2 s: UNVERIFIED (no network/device). Design helps:
  sideband-first framing, eager prefetch, fixed-line cache.
- Barge-in ≤150 ms: stopNow is local-only; the widget-free unit test
  asserts stopNow returns in <150 ms and 100 interruptions leave no
  overlap and no stuck state. DEVICE TIMING PENDING.
- Network cut mid-sentence: TESTED at unit level (fetch-fail →
  platform finishes incl. current, one notice, no repeats; play-fail →
  skip ahead). Real-network behaviour PENDING.
- Lip-sync drift ≤80 ms: design (30 Hz sideband envelope, 50 ms feeds,
  10/s decay, mouth shuts in silence - all unit-tested) PENDING device.
- Board speech <200 ms: REGRESSION TEST ADDED (tap→first-platform-audio
  <200 ms with fakes). Device timing PENDING.
- Same voice across brain changes: TESTED (`voiceIdFor` pure +
  ladder-gating independent of identity).

## 4. What is UNVERIFIED and why

- Everything needing ears, a device, keys, or the network: bake-off
  synthesis + winner, hosted request shapes, TTS terms/prices, real
  first-audio/RTF, barge-in ms on hardware, lip-sync drift, Stage fps
  with voice, understand-screen word-drift (design keeps platform
  callbacks there, but nobody ran it).
- The shipped sink is `NoopAudioSink`: `auto` always resolves to the
  phone voice today. Neural audio needs (a) the 4A winner, (b) ONE
  verified playback package - `audioplayers`/`flutter_soloud`/
  `just_audio` could not be version-checked offline, and a wrong pin
  would break every build. This is the deliberate pending step, not an
  oversight; the pipeline up to the sink is real and tested.
- `speak_model` default (`gpt-4o-mini-tts`) and the OpenAI TTS request
  shape are first hypotheses; the first keyed run confirms or corrects.
- Piper CLI shape (`--model/--output_file`) likewise unverified here.

## 5. Found but not fixed

- `_fetch` registers prefetch CancelTokens in the same set as playback
  fetches: a barge-in during an offline-lines download cancels the
  download (progress shows it; retry works). Rare + visible; accepted.
- `speak_price_per_1k` defaults 0 (unmetered) until the human prices it
  from the winning engine's terms.
- Ladder wording for `no_voice_engine`/TTS outages still falls through
  to generic resting words (same bucket as Phase 3's auth/unsupported
  codes - one future wording pass can cover all).
- Azure/Google/ElevenLabs bake-off adapters are loud stubs awaiting a
  verified API shape + a contributor; the harness lists them as such.

## 6. Decisions needed from the human

1. 4A LISTENING GATE: run the bake-off on your machine (keys + terms in
   `engines.json`), score blind, record the winner in
   `docs/upgrade/phase4/DECISION.md` (per-language winners allowed).
   Dev default meanwhile: platform voice (unchanged behaviour).
2. Approve the one playback package once versions are resolvable
   (recommends re-evaluating `audioplayers` vs `flutter_soloud` then).
3. Price `speak_price_per_1k` from the winner's terms; re-check data
   terms (still `unknown` in `datapolicy.py`).
4. iOS `Pods_Runner` diagnostic from the next CI run (unchanged).

## 7. Next phase's first three tasks (Phase 5 + original-plan gaps)

1. Closed tool registry: `read_aloud(span)`, `break_into_steps(text)`,
   `lookup_word(word)` through the existing contract + validator, with
   visible confirmations; capability-aware vision routing (blind brain →
   vision route or honest degrade).
2. Chat camera “show Milo” button → existing Understand route (EXIF
   stripped, ledger shows it); never claim unseen/unheard/unremembered.
3. Original-plan gap sweep from `00_AUDIT.md` §3: onboarding/session/
   trusted-adult/logout flows, crisis-suite review, permission
   denial/grant paths, backup-exclusion + platform data-protection
   verification, missing ledger/sync edge tests.
