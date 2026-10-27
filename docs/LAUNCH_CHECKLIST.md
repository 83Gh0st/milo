# Launch checklist: what code cannot do for you

**Verified in this repository:** gateway behaviour (tests incl. the real Meta adapters against a local fake of Meta's documented API), the Dart pure-logic modules (run on a real Dart VM), and the syntax of every Dart file.
**Not verified here:** a Flutter build and device run (no Flutter SDK in the build environment), real Meta API calls (no key), real children's speech accuracy.

## Before any real user
- [ ] Run `gateway/scripts/smoke_test.py` with your key; act on `smoke_report.json` (BRAIN_MODE, latency, model list).
- [ ] `flutter pub get && flutter analyze && flutter test` and fix anything the first compile reports (pin newer package versions if pub complains).
- [ ] Read Meta's Model API terms for the **standard** tier: retention, training, and any rule on children's data. Confirm Voice's zero-data-retention override is honoured on your account.
- [ ] Legal review (India DPDP Act 2023 verifiable parental consent for under-18s, COPPA, GDPR/UK AADC as applicable) and a written privacy policy. The code gives the technical basis (local-first, consent log, ledger, erasure); it does not make you compliant by itself.
- [ ] Fluent speakers review the crisis patterns (`gateway/app/safety.py`, `lib/core/safety.dart`) and the hand-written Hindi/Malayalam support lines. Add every language you ship.
- [ ] Verify the national helpline number for each region and set `--dart-define=HELPLINE=`.
- [ ] Test with volunteer adults first; pilot with children only with consent, a teacher or therapist present, and counsel's sign-off.
- [ ] Grow `eval/run_eval.py` cases to the plan sizes (20/20/20/50/20/40/20/20) and keep the safety, injection, memory and wording-help categories at 100%.
- [ ] Accessibility pass with TalkBack and VoiceOver on a real device; verify 200% text, high contrast and 64 dp targets.
- [ ] ARASAAC symbols are CC BY-NC-SA: this build uses emoji. If you add ARASAAC, show attribution and stay non-commercial, or switch to a commercial-friendly set.
- [x] Fonts (Lexend, Atkinson Hyperlegible, OpenDyslexic; SIL OFL) are bundled with their licence files. Show the licences on an About page before release.
- [ ] See `docs/DESIGN_MAP.md` for the few wireframe details not built (crop box, biometric unlock, photo tiles, tremor and left-handed options).

## Known gaps vs. the plan (honest list)
* **Not built:** Rive renderer swap, SAM 3.1 highlighting, synthesised chirps, switch/scanning access, offline speech recognition, widget/keyboard/share-in/screen-help, personal-photo tiles and photo sync, Play Integrity / App Attest (the gateway refuses `ATTESTATION_MODE=enforce` until a verifier is wired in, so it cannot silently pass).
* **Deviation:** local storage uses `sqflite_sqlcipher` (raw SQL, same schema, SQLCipher-encrypted, key in Keychain/Keystore) instead of Drift, because Drift needs code generation I could not run here. The `MiloDb` class isolates this so Drift can replace it.
* **Rate limiting** is per-process memory; move to Redis before running several replicas.
* **Photo EXIF removal** relies on re-encoding through the `image` package; confirm on a device that GPS tags are gone.
