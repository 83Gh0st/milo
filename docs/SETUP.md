# Milo: detailed setup

Milo is two deployable pieces plus an optional sync channel:

```
 Flutter app (iOS + Android)  ──HTTPS/SSE/WSS──▶  Gateway (FastAPI)  ──▶  Meta Model API (Spark, Voice Transcribe, Image)
   local encrypted SQLite                           holds the API key        └▶ PostgreSQL (spend, picture cache, E2EE sync blobs)
   character, board, memory, TTS
```
* **Frontend** (`/lib`, Flutter): works offline for the board, routines, memory, read-aloud and all animation.
* **Backend** (`/gateway`, FastAPI): the only place the Meta key lives. Stateless for user content. Stores only opaque encrypted sync blobs.
* **Cloud sync** is optional, end-to-end encrypted, and a separate permission from cloud AI (see `SYNC_DESIGN.md`).

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
