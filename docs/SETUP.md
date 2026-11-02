# Milo: detailed setup

> Windows `cmd` note: the bash snippets below use `export`/`source`; in `cmd`
> use `set VAR=value`, `docker compose ...`, `python -m ...`. venv activate:
> `.venv\Scripts\activate.bat`. Asset regeneration (all `cmd`-ready):
> `python tools\make_sounds.py`, `python tools\make_logo.py [--concept A|B|C]`,
> then `dart run flutter_launcher_icons` and
> `dart run flutter_native_splash:create`.

Milo is two deployable pieces plus an optional sync channel:

```
 Flutter app (iOS + Android)  ──HTTPS/SSE/WSS──▶  Gateway (FastAPI)  ──▶  Meta Model API (Spark, Voice Transcribe, Image)
   local encrypted SQLite                           holds the API key        └▶ PostgreSQL (spend, picture cache, E2EE sync blobs)
   character, board, memory, TTS
```
* **Frontend** (`/lib`, Flutter): works offline for the board, routines, memory, read-aloud and all animation.
* **Backend** (`/gateway`, FastAPI): the only place the deployer key lives. Stateless for user content. Stores only opaque encrypted sync blobs.
* **Cloud sync** is optional, end-to-end encrypted, and a separate permission from cloud AI (see `SYNC_DESIGN.md`).
* **AI choice:** Milo hosted (the gateway's model, no sync needed) or the
  family's own providers (Trusted adult → AI connections; needs sync as the
  family identity). See `BYOK.md` and `lib/core/ai_provider.dart`.
* **Releases:** `RELEASE.md` (Android + iOS builds, signing, TestFlight),
  `VOICE_CHECKLIST.md` (speech lifecycle + device checks), `MODAL.md`
  (serverless hosting + cost controls).

## 0. Prerequisites
| Need | For | Notes |
|---|---|---|
| Python 3.12 | gateway | |
| Flutter stable (3.24+) | app | `flutter doctor` must be green for Android |
| Android Studio + SDK 34 | Android builds | free |
| A Mac with Xcode 15+ | iOS builds | free simulator; free Apple ID runs on your own iPhone for 7 days; App Store needs the $99/yr programme |
| Meta Model API key | real AI | dev.meta.ai (hackathon credits). Not needed for mock mode |
| Docker + a domain | production | or a Cloudflare Tunnel for a demo |

## 1. Gateway, local (mock mode, no key needed)
```bash
cd gateway
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
python -m pytest -q                       # 18+ tests, all offline
PROVIDER=mock JWT_SECRET=$(python -c "import secrets;print(secrets.token_urlsafe(48))") \
  uvicorn app.main:app_factory --factory --port 8000 --reload
curl localhost:8000/v1/health
```
Mock mode returns deterministic turns so the whole app works end to end with no credits.

## 1b. Windows (`cmd`) + a physical phone

The gateway commands work in `cmd` with small changes (`set` instead of
`export`, `python` instead of `python3`):

```cmd
cd gateway
python -m venv .venv
.venv\Scripts\activate
pip install -r requirements-dev.txt
python -m pytest -q
set PROVIDER=mock
set JWT_SECRET=PASTE_48_RANDOM_CHARS_HERE
python -m uvicorn app.main:app_factory --factory --port 8000
```

Make the secret with `python -c "import secrets;print(secrets.token_urlsafe(48))"`.
Check it answers: open `http://localhost:8000/v1/health` in a browser
(`curl` also ships with Windows 10+).

Three ways to point a phone at that gateway (all match the app's `API_BASE`
wiring in `lib/config.dart`; confirm on your own phone):

a) **USB + adb** (no Wi-Fi needed): `adb reverse tcp:8000 tcp:8000`, then
   `flutter run --dart-define=API_BASE=http://127.0.0.1:8000`
b) **Same Wi-Fi**: run `ipconfig`, take the PC's IPv4 address, then
   `flutter run --dart-define=API_BASE=http://<pc-ip>:8000`
   (debug builds allow cleartext HTTP per §3; never ship cleartext).
c) **Anywhere via tunnel**: `cloudflared tunnel --url http://localhost:8000`,
   then `flutter run --dart-define=API_BASE=https://<random>.trycloudflare.com`

Mock first, then Meta: start with `PROVIDER=mock` (deterministic turns, no
key) and confirm the About → Connection row reads "Connected". Then set
`PROVIDER=meta` + `MODEL_API_KEY` and re-run the smoke test (§2).

Docker: `deploy/docker-compose.yml` is the VPS/production stack (Caddy on
80/443; the gateway service publishes no ports, so a phone cannot reach the
compose stack over your LAN). For a local Docker mock instead:

```cmd
docker build -f gateway/Dockerfile -t milo-gateway .
docker run --rm -p 8000:8000 -e PROVIDER=mock -e JWT_SECRET=PASTE_48_RANDOM_CHARS_HERE -e DATABASE_URL=sqlite+aiosqlite:////tmp/milo.db milo-gateway
```

then (a) or (b) above. (Compose file verified by reading 28 Oct 2026;
containers not run here - no Docker in this environment.)

## 1c. Gateway on Modal (serverless, no PC needed)

To run the gateway without Docker or a PC that stays on, deploy the same
code to Modal: see **`docs/MODAL.md`** (security audit, Windows `cmd`
runbook, secrets, health checks, rollback, teardown). The Flutter side needs
no code change - build the APK with
`--dart-define=API_BASE=https://<your-modal-url>` per `MODAL.md` §5.

## 2. Gateway, real Meta models (26 Oct onward)
```bash
cd gateway && cp .env.example .env
# edit .env:  ENV=dev  PROVIDER=meta  MODEL_API_KEY=...  JWT_SECRET=...  (keep DATABASE_URL sqlite for dev)
python scripts/smoke_test.py --image worksheet.jpg --pcm child_24khz_mono.pcm     # the 12 checks from plan section 9.6
cat smoke_report.json
```
Read the report before relying on anything:
* **03_t3** fails -> streaming and strict `json_schema` do not combine: set `BRAIN_MODE=lines` (the line-protocol fallback is implemented and tested).
* **06_t6** fails -> the file-transcription endpoint differs; Milo only needs the realtime socket, so this is informational.
* **11_t11** shows first-token latency from your location against the 1.5 s target.
* **12_t12** must show no `-contributor` model in use. The gateway refuses to start if any configured model ID ends in `-contributor` (those variants train on your data).
Then run the AI evaluation (rule checks; add a local Glimmer judge for quality):
```bash
python ../eval/run_eval.py --gateway http://localhost:8000
JUDGE_BASE_URL=http://localhost:11434/v1 JUDGE_MODEL=glimmer python ../eval/run_eval.py     # optional, Ollama serving Muse Glimmer
```
Note: when pointed at **mock** mode the `strategy_switch` check fails by design (the mock returns the same text for every strategy). Run it against the real model.

## 2b. Gateway, family AI connections (Phase 3, Windows `cmd`)

The gateway is a multi-provider router now: Meta first, plus OpenAI-compatible
endpoints (GPT, Ollama, LM Studio, vLLM), Anthropic, and mock. Families connect
their own keys in the app (Trusted adult → AI connections), but everything is
also doable from this terminal, coding-agent style. Keys are never command-line
arguments: hidden prompt, `--key-env NAME`, or `--key-stdin`.
```cmd
cd gateway
docker compose up -d --build
docker compose exec gateway python -m app.cli vault-new
set VID=<id from above>& set VKEY=<key from above>
docker compose exec -e VAULT_ID=%VID% -e VAULT_KEY=%VKEY% gateway python -m app.cli connect openai
docker compose exec -e VAULT_ID=%VID% -e VAULT_KEY=%VKEY% gateway python -m app.cli list
docker compose exec -e VAULT_ID=%VID% -e VAULT_KEY=%VKEY% gateway python -m app.cli test openai
docker compose exec -e VAULT_ID=%VID% -e VAULT_KEY=%VKEY% gateway python -m app.cli use brain openai/gpt-4o-mini --fallback mock/mock
docker compose exec -e VAULT_ID=%VID% -e VAULT_KEY=%VKEY% gateway python -m app.cli status
```
(Omit the `-e` flags and the CLI prompts for the vault id + key instead.)
Local models (Ollama on this PC, dev only): allow LAN endpoints in `gateway/.env`
with `ALLOW_LAN_PROVIDERS=true`, then `connect custom --base-url http://<pc-ip>:11434/v1 --no-key`
(data never leaves your network). Production refuses non-https, LAN, and
cloud-metadata addresses. Without docker, run from `gateway/` with the env set:
`set VAULT_ID=...& set VAULT_KEY=...& python -m app.cli ...`.
Families should prefer the app UI; the CLI is for setup and support.
See `docs/BYOK.md` for the trust model. `python scripts/smoke_providers.py`
probes every configured provider when keys are present (skips cleanly without).

## 3. Flutter app
```bash
cd milo                                   # repo root (has pubspec.yaml and lib/)
flutter create --platforms=android,ios --project-name milo --org com.yourorg .     # generates android/ and ios/
flutter pub get
dart run flutter_launcher_icons && dart run flutter_native_splash:create      # Milo app icon + splash from assets/branding
flutter test
```
(Re-draw the branding any time with `python tools/make_branding.py`; needs `pip install pillow`.)
**Android** (`android/app/src/main/AndroidManifest.xml`), inside `<manifest>`:
```xml
<uses-permission android:name="android.permission.INTERNET"/>
<uses-permission android:name="android.permission.ACCESS_NETWORK_STATE"/>
<uses-permission android:name="android.permission.RECORD_AUDIO"/>
<uses-permission android:name="android.permission.CAMERA"/>
<queries>
  <intent><action android:name="android.intent.action.TTS_SERVICE"/></intent>
  <intent><action android:name="android.intent.action.VIEW"/><data android:scheme="tel"/></intent>
</queries>
```
On `<application>` add `android:allowBackup="false"` and `android:fullBackupContent="false"` (the encrypted database and keys must not be copied to cloud backups). In `android/app/build.gradle` set `minSdkVersion 24`. For local HTTP testing only, add `android:usesCleartextTraffic="true"` in `android/app/src/debug/AndroidManifest.xml` (never in release).

**iOS** (`ios/Runner/Info.plist`):
```xml
<key>NSMicrophoneUsageDescription</key><string>Milo listens only when you tap the microphone.</string>
<key>NSCameraUsageDescription</key><string>Milo reads a page when you take a photo of it.</string>
<key>NSPhotoLibraryUsageDescription</key><string>Pick a photo of a page for Milo to read.</string>
<key>LSApplicationQueriesSchemes</key><array><string>tel</string></array>
```
In `ios/Podfile` set `platform :ios, '15.5'` (ML Kit minimum). To keep the database out of iCloud backups add to `AppDelegate.swift` in `didFinishLaunchingWithOptions`, before `return`:
```swift
if var dir = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
  var v = URLResourceValues(); v.isExcludedFromBackup = true; try? dir.setResourceValues(v)
}
```
(sqflite_sqlcipher stores in the app's `Documents`/databases directory; also exclude that directory the same way, or call `setResourceValues` on the `getDatabasesPath()` folder from a method channel. Verify on a device with `Settings > iCloud > Manage backups`.)

**Run**
```bash
# Android emulator talking to the gateway on your machine
flutter run --dart-define=API_BASE=http://10.0.2.2:8000
# real phone on the same Wi-Fi
flutter run --dart-define=API_BASE=http://192.168.1.20:8000
# against production
flutter run --release --dart-define=API_BASE=https://api.yourdomain.com --dart-define=HELPLINE=<verified number>
```
First launch shows onboarding (about 90 seconds, every step skippable). The `HELPLINE` define is empty by default so that no unverified number is ever shown; set the verified national helpline for each release region.

## 4. Where each Meta model is used
| Model (gateway env var) | Used for | Code |
|---|---|---|
| `muse-spark-1.3` (`SPARK_MODEL`) | chat turns, explanations, worksheet photos (vision), plans, wording help | `providers/meta.py` `MetaReasoning`, `routes.py` |
| `muse-voice-transcribe-1.0` (`VOICE_MODEL`) | push-to-talk voice (realtime socket, zero-data-retention flag on) | `providers/meta.py` `MetaVoice`, `routes.py` `/v1/voice` |
| `muse-image-1.0` (`IMAGE_MODEL`) | on-demand explainer pictures from a concept allow-list, cached by concept | `providers/meta.py` `MetaImage`, `routes.py` `/v1/visual` |
| Muse Glimmer (self-hosted) | evaluation judge only, never user-facing | `eval/run_eval.py` |
| SAM 3.1 | **not built** (plan marks it stretch) | |

## 5. Troubleshooting
* *App says "Offline" on an emulator*: use `10.0.2.2`, not `localhost`.
* *SSE feels delayed*: a proxy is buffering. Caddy config here disables it (`flush_interval -1`); test every host.
* *503 budget_exhausted*: the daily spend guard tripped (`DAILY_BUDGET_USD`). The app drops to the pocket brain and says so.
* *Mic does nothing on iOS simulator*: use a device.
