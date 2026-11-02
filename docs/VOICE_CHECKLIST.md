# Speech + lip-sync: lifecycle, tests, device checklist

The mouth is driven by the **audio lifecycle**, not by animation timers.
`Director.speak()` (`lib/companion/director.dart`) owns these invariants:

1. **No speech, no speaking state.** Empty/whitespace text returns before any
   state change. `voiceOn == false` shows captions with the mouth at baseline.
2. **No overlap.** Every `speak()` stops previous output first
   (`VoiceRouter.stopNow()` + a router generation guard), so rapid taps,
   barge-in, and back-to-back turns never layer audio or fight over state.
3. **Mouth follows proven audio.** `_speechStarted` is set only by a real
   signal - a platform TTS `started`/`word` event or a non-silent neural
   envelope feed. Estimated word timing (`_est`) and envelope feeds are gated
   on it; non-speech clips (giggle, hum, thinking-hmm) never pulse the mouth.
4. **Failure shuts the mouth.** No engine, platform error, fetch/play failure,
   cancellation, or interruption returns to the turn's resting state
   (`listening` when listening, else `idle`) with mouth, pulse, and envelope
   cleared. A failed turn speaks no notice over silence.
5. **Stale callbacks are dropped.** Platform events are subscribed per speak
   with the captured generation; envelope feeds and sentence callbacks check
   the generation too. A superseded request never touches a newer request's
   state.
6. **Lifecycle-safe.** Backgrounding the app (`paused`/`inactive`/`detached`)
   cancels speech; disposal cancels subscriptions, timers, and output.

What this is **not**: phoneme/viseme lip-sync. Neither Android nor iOS TTS
exposes phoneme timing to Flutter (`flutter_tts` gives word-range callbacks on
some engines, nothing on others). The mouth is conservative speech-aware
movement: word pulses where callbacks exist, estimated timing otherwise, the
neural amplitude envelope for gateway voice. Captions always carry the exact
words.

## Automated tests

- `test/voice_test.dart` (existing): router selection, neural prefetch/failover,
  barge-in, 100-interruption soak, cache rules, headless settle, endpointing,
  envelope-follows-mouth, AAC promptness, settings round-trip.
- `test/speech_lifecycle_test.dart` (new): empty/whitespace text, no-engine
  failure, platform failure mid-utterance, cancellation, rapid repeated taps,
  overlapping speaks, stale envelope feeds, giggle-without-speech,
  `voiceOn == false`, cancel-while-idle, dispose-mid-speech.
- Run: `flutter test` (CI runs the full suite on every push).

## Manual Android device checklist

On a real phone (not the emulator), with a release or debug build:

- [ ] **Tap says hi.** Idle → tap Milo → Milo says the greeting aloud, mouth
      moves with the words, caption matches. Tap 5× fast → one greeting, no
      stacked audio, settles to idle.
- [ ] **Silent tap paths.** Discreet profile / Quiet presence → tap only
      blinks (no TTS, no mouth). Sprout tap → wiggle + sparkle, mouth still.
- [ ] **Barge-in.** While Milo speaks a long answer, tap → speech stops
      immediately, Milo listens; no residual audio, no stuck speaking face.
- [ ] **No engine.** Disable/remove TTS data (or revoke nothing - just test on
      a device with TTS disabled if available) → Milo stays silent with the
      caption up, mouth still, returns to idle. (Emulator without Google TTS
      also exercises this.)
- [ ] **Offline board.** Airplane mode → communication board speaks instantly
      via platform TTS; Speaking view waveform follows; Again/Done work.
- [ ] **Background.** Start a long read-aloud → switch apps → speech stops, no
      audio in background; return → idle, no stuck state.
- [ ] **Voice picker.** Milo settings → pick a voice → preview plays in that
      voice; missing voice falls back honestly to the default.
- [ ] **Captions.** With sound muted, every spoken turn still shows its exact
      words; read-aloud highlights track the spoken word (engine permitting).

## Platform limitations (documented, not fixable in-app)

- Word-range callbacks: available on Android (Google TTS, most engines) and
  iOS 16+ (`AVSpeechSynthesizer.willSpeakRange`), but some OEM engines never
  call back - estimated timing covers those, with visibly coarser sync.
- `flutter_tts.speak()` return values are inconsistent across platforms, so
  success is defined as "no exception + completion callback". A lying engine
  (reports success, plays nothing) is indistinguishable from success; captions
  stay the source of truth.
- Neural gateway voice needs the `audioplayers`-class sink that is not yet
  integrated (`NoopAudioSink` times honestly but is silent, so `auto` mode
  always resolves to platform - see `lib/companion/sounds.dart` and §4A in
  `docs/upgrade/`). Until then, online-voice lip-sync is envelope-driven in
  tests only.
- Background audio is intentionally cancelled (see invariant 6): Milo never
  speaks from the background.
