import 'package:flutter/services.dart';

/// P2 share-in target (plan 7.13): the first system surface after the hackathon.
/// Android delivers ACTION_SEND text here; Understand picks it up once, like a
/// lookup word. Until the native side lands (platform dirs are CI-generated —
/// see docs/7_13_NATIVE.md), the channel never fires and this file is inert.
const _ch = MethodChannel('milo/share');
bool _armed = false;

/// Late shares (the app is already open): hand the text to the caller, which
/// stashes it in [sharedTextProvider] and routes to Understand.
void armShareIn(void Function(String) onText) {
  if (_armed) return;
  _armed = true;
  _ch.setMethodCallHandler((call) async {
    if (call.method == 'sharedText' && call.arguments is String) {
      final t = (call.arguments as String).trim();
      if (t.isNotEmpty) onText(t);
    }
  });
}

/// Cold start: the text the app was launched with, or '' (also '' when the
/// native side is missing, e.g. headless tests and iOS for now).
Future<String> fetchInitialSharedText() async {
  try {
    final t = await _ch.invokeMethod<String>('initialSharedText');
    return (t ?? '').trim();
  } catch (_) {
    return '';
  }
}
