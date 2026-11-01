# Milo releases: Android + iOS

How to build, sign, and publish Milo. `ci.yml` (every push) is unchanged and
still produces the debug-signed Android APK plus an unsigned iOS simulator
verification build. **Tagged** releases (`v*`, or manual dispatch) run
`.github/workflows/release.yml`: gateway tests, `dart format` check,
`flutter analyze`, `flutter test`, fresh launcher icons + splash from
`assets/branding`, then the platform builds below.

> Honesty rule: without signing secrets the workflows still run but produce
> **debug-signed Android artifacts** and an **unsigned iOS simulator build**,
> and say so in the job summary. Neither is distributable to a store.

## 1. Versioning

- `pubspec.yaml` `version: 1.0.0+1` is the single source: `1.0.0` is the
  user-visible version (Android `versionName`, iOS `CFBundleShortVersionString`),
  `+1` is the build number (Android `versionCode`, iOS `CFBundleVersion`).
- Bump both for every store upload: stores reject re-uploads of a build number.
- Tag the release commit: `git tag v1.0.1 && git push origin v1.0.1`.

## 2. API endpoint configuration (both platforms)

The gateway URL is **never** hardcoded. `lib/config.dart` reads `API_BASE`
from `--dart-define` (default `http://10.0.2.2:8000`, the Android emulator's
loopback to the developer's machine).

- CI's APK check build bakes the staging gateway URL and a verification step
  fails the job if `api.example.com` is present or the staging host is absent —
  the `milo-android-apk` artifact is a usable staging client.
- The iOS simulator check still uses `--dart-define=API_BASE=https://api.example.com`
  (a placeholder — that build only proves compilation, never distributed).
- `release.yml` uses the `MILO_API_BASE` repository secret when set, else the
  `api_base` manual-dispatch input, else the compiled-in default. Set
  `MILO_API_BASE` to your `https://…modal.run` URL (see `docs/MODAL.md` §4).
- No credentials ever go in `--dart-define`. Provider keys travel only through
  the PIN-gated AI-connections flow (TLS once, sealed server-side).

## 3. Android

### Local build (exact commands)

```cmd
flutter create --platforms=android --project-name milo .
flutter pub get
dart run flutter_launcher_icons
dart run flutter_native_splash:create
flutter build apk --release --dart-define=API_BASE=https://YOUR_API_BASE
flutter build appbundle --release --dart-define=API_BASE=https://YOUR_API_BASE
```

Outputs: `build\app\outputs\flutter-apk\app-release.apk`,
`build\app\outputs\bundle\release\app-release.aab`.

### Play signing (one-time setup)

1. Create a release keystore (keep the file + passwords in a password manager —
   losing them means a new Play listing):
   ```cmd
   keytool -genkeypair -v -keystore milo-release.jks -alias milo -keyalg RSA -keysize 2048 -validity 10000
   ```
2. Add repository secrets (Settings → Secrets and variables → Actions):
   `ANDROID_KEYSTORE_BASE64` (base64 of the `.jks`),
   `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`,
   plus `ANDROID_APPLICATION_ID` (e.g. `com.yourdomain.milo` — replace the
   `com.example.milo` template id; Play rejects `com.example.*`).
3. Push a tag. The workflow decodes the keystore, writes `android/key.properties`,
   wires `signingConfigs.release` via `tools/wire_android_signing.py`, and
   uploads the signed AAB + APK as `milo-android-release`.
4. Upload the AAB to Play Console (new release → upload the `.aab`).

## 4. iOS

> Why not Windows: Apple licenses Xcode and the iOS SDK for macOS only, and
> code signing + App Store upload require Apple tooling. Windows and Linux
> can edit Dart code and review the `ios/` shell, but every compile, sign,
> and upload step runs on the macOS GitHub Actions runners below (or a local
> Mac). The simulator check (§4.3) needs no secrets and no paid membership.

> Plugin integration: this Flutter prefers Swift Package Manager (no
> committed `ios/Podfile`), but five plugins still lack SPM support
> (`flutter_tts`, `google_mlkit_commons`, `google_mlkit_text_recognition`,
> `sensors_plus`, `sqflite_sqlcipher`) — so the tool falls back to
> CocoaPods for those automatically at build time (see the "Running pod
> install" line in CI logs). The workflows intentionally run no explicit
> `pod install`; if SPM ever breaks, regenerate a full CocoaPods shell with
> `FLUTTER_SWIFT_PACKAGE_MANAGER=false flutter create --platforms=ios .`
> (then re-apply the Info.plist + icon work from git).

### Requirements (Apple)

- A paid **Apple Developer Program** membership ($99/yr) — required for
  TestFlight and the App Store (a free Apple ID can only side-load to your own
  tethered devices via Xcode).
- An **App Store Connect** record: create the app (My Apps → +), pick the
  bundle id from §4.1 — the bundle id must match exactly.
- A **Distribution certificate** (Apple Distribution) + an **App Store
  provisioning profile** for the bundle id, OR an **App Store Connect API key**
  (Issuer ID + Key ID + `.p8`) for upload. This repo uses manual signing with
  a `.p12` + profile in CI (below); the API key is only needed at upload time.

### 4.1 Bundle identifier (do this first)

`flutter create` stamps `com.example.milo`. Before the first TestFlight upload,
choose the real id (e.g. `com.yourdomain.milo`), register it at
developer.apple.com → Identifiers, and store it as the `IOS_BUNDLE_ID` secret.
The workflow rewrites the generated Xcode project with it at build time. The
id can never change afterwards for the same App Store listing.

### 4.2 Signing secrets (one-time setup)

Create at developer.apple.com / in Xcode, then add as repository secrets:

| Secret | Contents |
|---|---|
| `IOS_CERTIFICATE_BASE64` | base64 of the exported `.p12` (Apple Distribution cert + private key) |
| `IOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `IOS_PROVISIONING_PROFILE_BASE64` | base64 of the App Store `.mobileprovision` for the bundle id |
| `IOS_TEAM_ID` | your 10-character Team ID |
| `IOS_BUNDLE_ID` | the real bundle id (§4.1) |
| `IOS_PROFILE_UUID` | the profile's UUID (open the `.mobileprovision` in a text editor → `UUID` key) |
| `IOS_KEYCHAIN_PASSWORD` | any random string (ephemeral CI keychain only) |

Export the `.p12` from Keychain Access (right-click the Distribution
certificate → Export). Never commit any of these files.

Then add a repository **variable** (Settings → Secrets and variables →
Actions → Variables tab): `IOS_SIGNING_ENABLED` = `true`. The workflow
cannot test secrets in a job condition, so this variable is the on/off
switch for the signed-IPA job; the job itself fails fast with a clear
message if the variable is on but the secrets are missing.

### 4.3 CI simulator verification (no secrets needed)

Every release tag runs `ios-verify` on `macos-latest`: `flutter create`,
`pod install`, `flutter build ios --simulator --no-codesign`. This proves the
iOS build compiles and links. **It is not installable on devices.**

### 4.4 Signed IPA (needs the §4.2 secrets)

The `ios-ipa` job runs only when the `IOS_SIGNING_ENABLED` repo variable
is `true` (and the §4.2 secrets verify present); otherwise it is skipped and the
summary says no IPA was produced. It imports the identity into an ephemeral
keychain, writes `ExportOptions.plist` (`app-store`, manual signing), runs
`flutter build ipa --release`, and uploads `milo-ios-ipa`.

Local equivalent (on a Mac with Xcode + the profile installed):

```sh
flutter create --platforms=ios --project-name milo .
flutter pub get
dart run flutter_launcher_icons
cd ios && pod install && cd ..
flutter build ipa --release --dart-define=API_BASE=https://YOUR_API_BASE
```

### 4.5 TestFlight upload (exact steps)

1. Download the `milo-ios-ipa` artifact from the release run (a signed `.ipa`).
   Do **not** re-sign or unzip it.
2. Upload with Apple's uploader (macOS, or the Transporter app):
   ```sh
   xcrun notarytool submit build/ios/ipa/milo.ipa --help >/dev/null # sanity: Xcode CLI tools present
   xcrun altool --upload-app -f build/ios/ipa/milo.ipa -t ios \
     --apiKey "$APP_STORE_CONNECT_KEY_ID" --apiIssuer "$APP_STORE_CONNECT_ISSUER_ID"
   ```
   (`--apiKey`/`--apiIssuer` come from an App Store Connect API key with the
   App Manager role; create it at App Store Connect → Users and Access → API Keys.
   Or open Transporter.app, sign in, drag the `.ipa` in, Deliver.)
3. Wait for Apple's automated processing + TestFlight review (minutes to a day).
   Fix any "Missing Compliance" prompt in App Store Connect → TestFlight →
   select the build → answer the encryption questionnaire (Milo uses standard
   HTTPS/crypto only).
4. Add testers: TestFlight tab → Internal Testing (App Store Connect users, no
   review) or External Testing (any email, needs one Beta App Review per
   version). Testers install via the TestFlight app link.
5. First external version needs **Beta App Review**: submit the build with test
   notes ("AI companion for communication support…"), a demo account if login
   existed (it doesn't — Milo has no accounts), and contact info.

### 4.6 App Store submission (after TestFlight)

Version bump in `pubspec.yaml` → tag → signed IPA → upload (§4.5) → App Store
tab → + Version → screenshots, description, age rating questionnaire (answer
honestly: AI chat, no user accounts, parental-gated settings), privacy
nutrition labels (see `docs/DATA_MAP.md` for what leaves the phone) → Submit
for Review.

## 5. Pre-release gate (human checklist)

- [ ] `pubspec.yaml` version bumped, tag pushed, `release.yml` green.
- [ ] Renderer changed? Regenerate + review `test/goldens/*.png` on a
      trusted machine (`flutter test --update-goldens
      --dart-define=MILO_GEN_GOLDENS=true test/renderer_states_test.dart`),
      view every PNG at 1× and 2×, then commit them.
- [ ] Tested the actual artifact on a real phone (APK install / TestFlight):
      onboarding, board speech offline, cloud turn online, sync opt-in.
- [ ] `MILO_API_BASE` points at the production gateway; About → Connection reads
      "Connected to Milo's server…".
- [ ] Android: signed with the release key (`RELEASE_SIGNED=true` in the summary),
      application id is the real one. iOS: bundle id matches App Store Connect.
- [ ] `docs/LAUNCH_CHECKLIST.md` reviewed; helpline numbers verified per country
      (`--dart-define=HELPLINE=…` if shipping calling features).
