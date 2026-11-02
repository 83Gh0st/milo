# Plan 7.13 - system surfaces (share-in first, the rest in order)

Status: Dart side landed (`lib/sys/share_in.dart`, `sharedTextProvider`,
`UnderstandScreen` consume-once, `main.dart` arming). Native sides below are
**UNVERIFIED**: no device here. (An older revision of this note said
`android/` and `ios/` do not exist - they are committed now; CI refreshes
them with `flutter create`.) Apply, then run the
human 30-minute check per surface. Order is the plan's: share-in, widget,
keyboard, accessibility service.

Privacy rule for all four: no personal content on shared surfaces. The widget
shows Milo + counts-shape actions only; the keyboard and a11y service see
everything typed, so they ship last and say so on their consent screen.

## 1. Share-in (Android now, iOS later)

Dart contract: `MethodChannel('milo/share')`, method `sharedText` with a
String argument (late share), method `initialSharedText` returning the
launch text or null (cold start). Both flows are widget-tested with a fake
messenger; only this native half is missing.

`AndroidManifest.xml`, inside the main `<activity>`:

```xml
<intent-filter>
  <action android:name="android.intent.action.SEND" />
  <category android:name="android.intent.category.DEFAULT" />
  <data android:mimeType="text/plain" />
</intent-filter>
```

`MainActivity.kt` (FlutterFragmentActivity or FlutterActivity):

```kotlin
import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
  private var launchText: String? = null
  private val CH = "milo/share"

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    launchText = intent?.takeIf { it.action == Intent.ACTION_SEND }?.getStringExtra(Intent.EXTRA_TEXT)
    MethodChannel(flutterEngine!!.dartExecutor.binaryMessenger, CH).setMethodCallHandler { call, res ->
      if (call.method == "initialSharedText") { res.success(launchText); launchText = null }
      else res.notImplemented()
    }
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    intent.getStringExtra(Intent.EXTRA_TEXT)?.takeIf { it.isNotBlank() }?.let { text ->
      MethodChannel(flutterEngine!!.dartExecutor.binaryMessenger, CH).invokeMethod("sharedText", text)
    }
  }
}
```

iOS share extension: needs a new Xcode extension target + App Group to pass
text in. Not written: hand-editing `project.pbxproj` blind would risk the
already-fragile iOS build. Do it in Xcode on a Mac, then post the text to
`milo/share` via the same two-method contract.

## 2. Home widget (second)

Android `AppWidgetProvider` + `res/xml/milo_widget.xml` + layout with Milo
face, one "Talk" button (opens the app), one "Quick help" button (opens
Express). No names, no transcripts, no counts on the widget. Taps route via
the existing `openScreen` deep-link table; add the provider entry to the
manifest. iOS WidgetKit equivalent after Android is verified on-device.

## 3. Custom keyboard (third)

Biggest native surface and the most sensitive (it sees everything typed).
Headless API it calls is ready: `CoreRouter.explain` (understand),
`MiloApi.compose` (wording help), `MiloApi.plan` (step guides) - see table
below. Ships only with its own consent screen and a Play Data-Safety entry.

## 4. Accessibility service (last)

TalkBack-order audit first (acceptance 7.9), then a service only if Play
policy allows the declared purpose. No code until legal/Play review.

## Headless Core API (what future surfaces call)

| Call | Input | Output | Notes |
|---|---|---|---|
| `CoreRouter.explain(d, text, {strategy, imageB64})` | text or photo | speaks + fills Understand state | ledger-first via `MiloApi` |
| `MiloApi.compose(strip, presentation, lang)` | AAC words | ≤3 rephrasings | `no_new_content` guard server-side |
| `MiloApi.plan(goal, presentation, lang)` | goal text | steps | confirmation stays in Do UI |
| `MiloApi.visual(concept)` | allow-list word | PNG bytes | allow-list enforced both ends |
| `summarizeBody` / ledger | every call | metadata-only row | never message text |
