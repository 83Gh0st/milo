# Milo development guide

Setup, testing, builds, and contribution workflow. Install/run instructions
for users live in [`docs/SETUP.md`](docs/SETUP.md); system design in
[`ARCHITECTURE.md`](ARCHITECTURE.md); releases in [`docs/RELEASE.md`](docs/RELEASE.md).

## 1. Repository layout

```
lib/  test/          Flutter app + suites (unit, widget, regression)
gateway/             FastAPI app, provider adapters, tests/, scripts/, modal_*.py
contracts/           brain_contract.json + ui_contract.json (sources of truth)
assets/branding/     icon/splash/mascot masters (generated platform art derives from these)
android/ ios/        committed platform shells (CI refreshes via flutter create)
deploy/              Docker Compose VPS stack        eval/  AI eval harness
tools/               signing helper, legacy art scripts (see hygiene notes below)
docs/                this guide map (see README for the full list)
```

The `.sdk-probe/` directory (gitignored) holds a local Flutter SDK and
throwaway verification scripts - never commit it.

## 2. First-time setup

```bash
# Gateway
cd gateway
python -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
cp .env.example .env   # dev defaults work; mock mode needs no keys

# App (repo root)
flutter pub get
dart run flutter_launcher_icons && dart run flutter_native_splash:create
```

Windows PowerShell: replace `source …/activate` with
`.venv\Scripts\Activate.ps1` and `export` with `$env:NAME = '…'`.
`flutter doctor` must be green for Android; iOS builds need a Mac.

## 3. Everyday commands

```bash
cd gateway && python -m pytest -q          # gateway suite (fast, offline)
flutter analyze                             # must be clean
flutter test                                # needs loopback; CI always runs it
flutter run --dart-define=API_BASE=http://10.0.2.2:8000   # app vs local gateway
PROVIDER=mock JWT_SECRET=$(python -c "import secrets;print(secrets.token_urlsafe(48))") \
  python -m uvicorn app.main:app_factory --factory --port 8000   # local gateway (from gateway/)
```

Regenerate brand art after editing a master in `assets/branding/`:

```bash
dart run flutter_launcher_icons && dart run flutter_native_splash:create
```

Commit the regenerated `android/app/src/main/res` and
`ios/Runner/Assets.xcassets` so local builds match CI.

## 4. Testing policy

- Gateway: `pytest` covers contracts, safety screening, routing/failover,
  providers (fake transports), spend guards, streaming parsers, and the UI
  validator. Async tests need an event loop - plain `pytest` on any desktop
  OS; locked-down sandboxes without sockets can only run the sync subset.
- App: `flutter test` covers validators, router/pocket logic, provider
  switching, connections UI, GenUI panels, intro timing, and regressions.
  Widget tests use the `test/helpers/` fakes (never real network/keys).
- Dart/contract parity: `contracts/*.json` mirror into Dart and Python with
  tests that fail on drift - change the JSON first, then both sides.
- Device ladders before any release claim: `docs/PHONE_CHECKLIST.md`,
  `docs/VOICE_CHECKLIST.md`. Never claim a device verification that was not run.
- CI (`ci.yml`, every push): gateway tests, analyze, full flutter suite,
  staging APK (with baked-URL verification), iOS simulator build.

## 5. Builds

```bash
# Debug APK against staging (installable for testing)
flutter build apk --debug \
  --dart-define=API_BASE=https://arjun3314508--milo-gateway-staging-web.us-east.modal.run
# Release (Play signing needs secrets; without them the APK is debug-signed)
flutter build apk --release --dart-define=API_BASE=<gateway-url>
flutter build appbundle --release --dart-define=API_BASE=<gateway-url>
# iOS simulator (Mac only): unsigned compile+link check
flutter build ios --simulator --no-codesign --dart-define=API_BASE=<gateway-url>
```

Tagged releases (`v*`) run `release.yml`: checks, fresh brand art, platform
builds, optional Play signing and signed-IPA jobs (both secret-gated with
honest summaries when secrets are absent). Never commit keystores,
certificates, provisioning profiles, or API keys - they arrive via GitHub
secrets, Modal secrets, or the in-app vault only.

## 6. Endpoint probes (need keys or local servers; never in CI)

```bash
python gateway/scripts/probe_sam.py photo.jpg --concept heart   # MODEL_API_KEY=... ; exit 0 + JSON = SAM verified
ollama run muse-glimmer:30b                                     # ~24 GB VRAM, then connect as Custom/local endpoint
JUDGE_BASE_URL=http://localhost:11434/v1 JUDGE_MODEL=glimmer python eval/run_eval.py --gateway http://localhost:8000
python tools/smoke_providers.py                                 # every configured provider, when keys exist
```

Probes print sanitized summaries only - keys never appear in output.

## 7. Modal workflow

```bash
modal deploy gateway/modal_staging.py   # staging: deploy freely, then run the docs/MODAL.md ladder
modal deploy gateway/modal_app.py       # production: only after staging passes
```

Or dispatch `modal-deploy.yml` (production needs `confirm_prod=DEPLOY-PROD`).
Never edit production secrets to test an idea - prove it on staging first.
The Shared Endpoint itself is dashboard-managed; nothing here deploys weights.

## 8. Contribution workflow

1. Read `ARCHITECTURE.md` §1–2 and the doc for the area you touch.
2. Keep the contracts closed: new model powers need contract + validator +
   tests on both sides, or they do not ship.
3. Preserve the non-negotiables: ledger-before-send, offline board, no silent
   provider switching, no training on user data, no credentials in the client.
4. Run `flutter analyze`, `flutter test`, and `python -m pytest -q` before
   pushing; CI re-runs all three plus builds.
5. Docs ship with behaviour: user-facing changes update the README section or
   the owning doc; cross-link instead of duplicating.

## 9. Hygiene notes (do not "fix" these blindly)

- `tools/make_branding.py` draws the pre-rebrand identity (marked stale in
  its docstring) - the shipped path is `assets/branding/` masters.
- The pre-hackathon blueprint ships as `Milo_Architecture_and_Build_Plan.pdf`
  in the root (the `.docx` source is intentionally not committed).
- CI log captures (`error.txt`, `log.txt`) and pytest tmp dirs are not
  committed; `.gitignore` covers their patterns.
- `generated_images/` holds the AI master renders behind `assets/branding/`
  (inputs to the gitignored `.sdk-probe/brand_gen.dart` pipeline); keep them.
- `ios/` uses full CocoaPods mode: `ios/Podfile` is committed (platform
  15.5, ML Kit's floor), CI sets `FLUTTER_SWIFT_PACKAGE_MANAGER=false` and
  runs an explicit `pod install`. Five plugins lack SPM support and the
  default hybrid SPM+Pods setup fails to link, so do not remove the flag
  or the Podfile. (SPM-only template ships no Podfile; ours is the stock
  `flutter_tools` `Podfile-ios` template with the platform line set.)
