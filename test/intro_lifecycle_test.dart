// Introduction lifecycle: once per lifetime, silent taps/launches, deliberate replay.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/data/secure_store.dart';
import 'package:milo/net/api.dart';
import 'package:milo/ui/more_screen.dart';
import 'package:milo/ui/onboarding.dart';
import 'package:milo/voice/voice_output.dart';

import 'helpers/fake_db.dart';
import 'helpers/harness.dart';

ProviderContainer _c(FakeDb db, Director d) => ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      storeProvider.overrideWithValue(SecureStore()),
      directorProvider.overrideWith((_) => d),
      apiProvider.overrideWithValue(FakeApi(db, SecureStore())),
      connectionCheckProvider.overrideWith((_) => Future.value(const ConnStatus(apiBase: 'http://test', ok: true, provider: 'mock', brainMode: 'json', budgetOk: true, words: 'Connected.'))),
    ]);

// pumpScreen resets the surface to the 800x600 default on return; re-pin an
// explicit size so page math and list layout stay deterministic afterwards.
Future<void> _surface(WidgetTester t, {double w = 360, double h = 640}) async {
  t.view.physicalSize = Size(w * 3, h * 3);
  t.view.devicePixelRatio = 3.0;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  await t.pump();
}

class _Tts extends PlatformVoice {
  final spoken = <String>[];
  @override
  Future<void> speakSentence(String text,
      {double pitch = 1,
      double rate = 1,
      String lang = 'en',
      String profile = '',
      Map<String, String> style = const {},
      void Function(double)? onMouth}) async {
    spoken.add(text);
    await Future.delayed(const Duration(milliseconds: 2));
  }
}

Director _d(_Tts p) {
  final d = Director();
  d.voice = VoiceRouter(platform: p, neural: NeuralVoice(sink: NoopAudioSink()));
  return d;
}

void main() {
  test('fresh companion is unmet; hello motion never speaks', () async {
    final p = _Tts();
    final d = _d(p);
    expect(d.met, isFalse);
    d.helloMotion(); // launches and taps acknowledge silently
    await Future.delayed(const Duration(milliseconds: 50));
    expect(p.spoken, isEmpty);
    expect(d.met, isFalse);
    d.dispose();
  });

  testWidgets('skipped onboarding marks met silently', (t) async {
    final db = FakeDb(), p = _Tts(), d = _d(p);
    final c = _c(db, d);
    var done = false;
    await pumpScreen(t, Onboarding(onDone: () => done = true), container: c);
    await _surface(t);
    await t.tap(find.text('Skip'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(done, isTrue);
    expect(await db.get('onboarded'), '0');
    expect(d.met, isTrue);
    expect(p.spoken, isEmpty); // no ambush speech after Skip
    expect(t.takeException(), isNull);
    c.dispose();
  });

  testWidgets('full onboarding speaks the introduction once', (t) async {
    final db = FakeDb(), p = _Tts(), d = _d(p);
    final c = _c(db, d);
    var done = false;
    Future<void> go(String label) async {
      await t.tap(find.text(label));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300)); // page slide + settle
    }

    await pumpScreen(t, Onboarding(onDone: () => done = true), container: c);
    await _surface(t);
    await go('Get started');
    for (var i = 0; i < 6; i++) {
      await go('Next');
    }
    await go('I understand');
    await go('Next');
    await t.tap(find.text('Start exploring'));
    await t.pump(const Duration(seconds: 8)); // flush the unawaited greeting
    expect(done, isTrue);
    expect(await db.get('onboarded'), '1');
    expect(d.met, isTrue);
    expect(p.spoken.join(' '), contains('your new AI friend')); // playful default first-day line
    expect(t.takeException(), isNull);
    c.dispose();
  });

  testWidgets('Replay introduction speaks exactly once more', (t) async {
    final p = _Tts(), d = _d(p);
    final c = _c(FakeDb(), d);
    d.met = true; // returning user
    await pumpScreen(t, const MiloSettingsScreen(), container: c);
    await _surface(t, h: 3000); // tall surface: the whole lazy list builds, no dragging
    await t.tap(find.text('Replay introduction'));
    await t.pump(const Duration(seconds: 8));
    expect(p.spoken, isNotEmpty); // deliberate replay speaks
    expect(d.met, isTrue);
    expect(t.takeException(), isNull);
    c.dispose();
  });
}
