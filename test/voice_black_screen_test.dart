import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/data/secure_store.dart';
import 'package:milo/net/api.dart';
import 'package:milo/net/voice.dart';
import 'package:milo/ui/chat_screen.dart';

import 'helpers/fake_db.dart';
import 'helpers/harness.dart';

/// Voice double: captures the screen's callbacks; stop() delivers the final
/// transcript the way the gateway does at end-of-stream (the race that used
/// to pop the screen twice and black out the app on Android).
class FakeVoiceClient extends VoiceClient {
  FakeVoiceClient(super.api);
  void Function(String)? _final;
  int stopCalls = 0;

  @override
  Future<void> start({required void Function(String) onPartial, required void Function(String) onFinal,
      required void Function(String) onError, void Function(double)? onLevel, String lang = 'English'}) async {
    _final = onFinal;
    onPartial('Hello');
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    _final?.call('Hello'); // gateway final arriving during the stop wait
  }
}

void main() {
  testWidgets('voice exit pops exactly once: home survives, one ask, no exception', (t) async {
    final db = FakeDb();
    final api = FakeApi(db, SecureStore());
    final fake = FakeVoiceClient(api);
    final c = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      storeProvider.overrideWithValue(SecureStore()),
      apiProvider.overrideWithValue(api),
      voiceProvider.overrideWithValue(fake),
    ]);
    final asked = <String>[];
    c.read(directorProvider).router = (text) async => asked.add(text); // record asks; no brain/TTS in this test
    await t.pumpWidget(UncontrolledProviderScope(container: c, child: MaterialApp(home: Builder(builder: (ctx) => Scaffold(body: Center(child: TextButton(
        onPressed: () => Navigator.push(ctx, MaterialPageRoute<void>(builder: (_) => const VoiceListenScreen())),
        child: const Text('under-home'))))))));
    await t.pumpAndSettle();
    // Open the voice screen like the chat mic button does.
    final navCtx = t.element(find.text('under-home'));
    Navigator.push(navCtx, MaterialPageRoute<void>(builder: (_) => const VoiceListenScreen()));
    await t.pumpAndSettle();
    expect(find.text('Listening…'), findsOneWidget);
    // Deliberate stop: stop() delivers the final mid-wait; both exit paths race.
    await t.tap(find.byIcon(Icons.stop));
    await t.pumpAndSettle();
    // Exactly one pop: the voice screen is gone, home underneath survives.
    expect(t.takeException(), isNull);
    expect(find.text('under-home'), findsOneWidget);
    expect(find.text('Listening…'), findsNothing);
    // Exactly one ask was sent (no duplicate user turn from the second exit).
    final users = c.read(chatProvider).where((m) => !m.milo && m.text == 'Hello').length;
    expect(users, 1);
    expect(asked, ['Hello']);
    expect(fake.stopCalls, greaterThanOrEqualTo(1));
    await t.pump(const Duration(seconds: 2)); // flush the ask ladder one-shot
    c.dispose(); // cancels the ladder refresh timer before the pending-timer check
  });
}
