# Milo screenshots

## What lives here

`test/screenshots_test.dart` pumps real screens with the standard test fakes
and saves **widget-tree renders** (PNG, 786x1704) into this directory. They
show real widgets, real layout, and real brand assets - but no device chrome,
no status bar, and no live backend. Every capture below states its backend;
anything marked *fixture* or *mock* must never be presented as a live run.

Files (`screenshots/*.png`) are build output: gitignored, produced locally via
`flutter test test/screenshots_test.dart` or downloaded from the CI
`milo-screenshots` artifact. This README and the index are the committed part.

## Capture index

| File | Screen and state | Backend |
|---|---|---|
| `01-intro.png` | Intro veil mid-animation (mascot + wordmark) | none (local) |
| `02-home.png` | Home with companion stage | mock |
| `03-chat.png` | Chat thread: question + answer + steps | mock |
| `04-understand.png` | Understand screen, empty state | mock |
| `05-express.png` | Offline communication board | none (local) |
| `06-accessibility.png` | Text/font/contrast/motion settings | none (local) |
| `07-connections.png` | AI Connections (provider tiles) | mock |
| `08-about.png` | About + brand lockup | none (local) |
| `09-genui-panel.png` | Generative panel: text + checklist + genimage pre-create | fixture spec |
| `10-segment-fixture.png` | Segmentation overlay, 2 fixture regions, 1 selected | fixture (SAM unverified) |
| `11-offline.png` | Board with the ladder forced offline | forced offline |

## Not capturable in the tester (need a device)

- Voice interaction + live transcription (needs mic + Meta key).
- Image understanding with a real photo (needs camera/gallery + vision).
- Loaded generated picture (needs Meta Image key + Create tap).
- Real provider-error and timeout states (needs staging).
- Native splash → intro handoff (needs a real launch).
- iOS anything (needs macOS + simulator).

## Manual device runbook

```bash
# Emulator (or a USB device with USB debugging)
emulator -avd Pixel_8_API_34 &
adb wait-for-device
flutter build apk --debug --dart-define=API_BASE=<staging-url>
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

Consistency: Pixel 8, 393x852 logical, light mode, text scale 1.0, Do Not
Disturb on, clock fixed (`adb shell settings put global ...` is optional;
note if the status bar differs). Dismiss the keyboard before each shot
(tap outside the field), keep hands off during animation frames, and never
include keys, personal data, or real children's content:

```bash
adb exec-out screencap -p > screenshots/device-01-home.png
```

Walk every row of the index above plus the device-only list; rename honestly
(`device-…` prefix) and record live-vs-mock per shot.

## Device-driver sketch (optional, needs `integration_test`)

Not committed (keeps `flutter analyze` green without the package). To automate
device shots, add `integration_test` to `dev_dependencies`, save the sketch
below as `integration_test/screenshot_driver.dart`, and run
`flutter test integration_test/screenshot_driver.dart` with a device attached:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:milo/main.dart' as app;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('device screenshots', (t) async {
    app.main();
    await t.pumpAndSettle();
    await binding.takeScreenshot('device-01-home');
    // TODO: tap through tabs with t.tap + pumpAndSettle, one takeScreenshot each.
  });
}
```

## Promotional art (separate, optional)

Muse Image concept compositions are welcome for slides/socials, but they live
outside this directory, are never named like captures, and are always labeled
"concept art - not a screenshot".
