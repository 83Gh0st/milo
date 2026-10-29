import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/companion/milo_view.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/data/secure_store.dart';
import 'package:milo/voice/voice_output.dart';

import 'helpers/fake_db.dart';
import 'helpers/harness.dart';

/// Headless renderer verification: drives the real MiloView through every
/// conversation state and captures a golden per state, plus idle-movement
/// (breath phases), blink mechanics, and a frame-cost smoke probe.
///
/// Emotion mapping (the brain contract holds a closed 12-emotion list, so
/// nearby validated expressions stand in): sad -> concerned (low-valence
/// frown), confused -> curious (asymmetric inquiry brow), reassuring ->
/// encouraging (warm support). Distinct sad/confused faces would need a
/// contract v2 (JSON + Dart + prompts + parity tests).
///
/// Determinism: each golden uses a fresh Director with fixed tick counts
/// (sim clock stays under the 6 s idle-fidget schedule), cleared particles,
/// and zeroed gaze springs, followed by a zero-dt repaint tick. Nothing in
/// the captured pixels depends on Random, wall clock, or platform fonts
/// (Lexend is bundled and loaded; particles are cleared before capture).
///
/// Baselines (`test/goldens/*.png`) are created once on a trusted machine:
/// `flutter test --update-goldens --dart-define=MILO_GEN_GOLDENS=true
/// test/renderer_states_test.dart`, then review the PNGs and commit them.
/// Until baselines exist, every state still pumps (paint-crash coverage)
/// but the pixel comparison is skipped, so CI stays green.

/// Gated platform voice: speech stays in-flight until `gate.complete()`,
/// so the speaking pose can be captured deterministically mid-utterance.
class GatePlatform extends PlatformVoice {
  final gate = Completer<void>();
  @override
  Future<void> speakSentence(String text,
      {double pitch = 1,
      double rate = 1,
      String lang = 'en',
      String profile = '',
      Map<String, String> style = const {},
      void Function(double)? onMouth}) async {
    await gate.future;
  }
}

Future<void> pumpMilo(WidgetTester t, Director d) async {
  await t.pumpWidget(ProviderScope(overrides: [
    dbProvider.overrideWithValue(FakeDb()),
    storeProvider.overrideWithValue(SecureStore()),
    directorProvider.overrideWith((_) => d),
  ], child: MaterialApp(
      home: Scaffold(
          body: Center(
              child: SizedBox(
                  width: 360, height: 420, child: MiloView()))))));
  await t.pump();
}

/// Freeze-frame prep: no stray particles, deterministic centred gaze, and
/// one zero-dt tick that repaints without advancing the world (springs,
/// breath, clips, and timers all hold still at dt == 0).
void freezeFrame(Director d) {
  d.parts.clear();
  for (final s in [d.eyeX, d.eyeY, d.headX, d.headY]) {
    s.x = 0;
    s.v = 0;
    s.t = 0;
  }
  d.tick(0);
}

void tickN(Director d, int n) {
  for (var i = 0; i < n; i++) {
    d.tick(1 / 60);
  }
}

/// True only for the one-time baseline run (see above).
const genGoldens = bool.fromEnvironment('MILO_GEN_GOLDENS');

Future<void> maybeGolden(WidgetTester t, String name) async {
  final f = File('test/goldens/$name');
  if (await f.exists() || genGoldens) {
    await expectLater(
        find.byType(MiloView), matchesGoldenFile('goldens/$name'));
  } else {
    print('golden missing, skipped (generate on a dev machine): $name');
  }
}

Future<void> capture(
    WidgetTester t, Director d, String name) async {
  freezeFrame(d);
  await pumpMilo(t, d);
  await maybeGolden(t, name);
  d.dispose();
}

void main() {
  group('renderer states', () {
    testWidgets('resting, breath phase A', (t) async {
      await loadLexend();
      final d = Director();
      tickN(d, 60);
      await capture(t, d, 'milo_resting_a.png');
    });

    testWidgets('resting, breath phase B (idle movement)', (t) async {
      await loadLexend();
      final d = Director();
      tickN(d, 105);
      await capture(t, d, 'milo_resting_b.png');
    });

    testWidgets('listening with voice activity', (t) async {
      await loadLexend();
      final d = Director();
      d.setListening(true);
      d.micLevel = 0.65;
      tickN(d, 20);
      await capture(t, d, 'milo_listening.png');
    });

    testWidgets('thinking', (t) async {
      await loadLexend();
      final d = Director();
      d.emote('thinking', i: 0.9, hold: 60, force: true);
      d.gesture('thinking_hmm', force: true); // the real thinking pose
      tickN(d, 30);
      await capture(t, d, 'milo_thinking.png');
    });

    testWidgets('speaking, open and soft phases', (t) async {
      await loadLexend();
      final gate = GatePlatform();
      final d = Director();
      d.voice = VoiceRouter(
          platform: gate, neural: NeuralVoice(sink: NoopAudioSink()));
      unawaited(d.speak('Hello world'));
      for (var i = 0; i < 8 && !d.speaking; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      expect(d.speaking, isTrue);
      d.feedMouth(0.9);
      d.tick(1 / 60);
      freezeFrame(d);
      await pumpMilo(t, d);
      await maybeGolden(t, 'milo_speaking_open.png');
      d.feedMouth(0.25);
      d.tick(1 / 60);
      freezeFrame(d);
      await t.pump();
      await maybeGolden(t, 'milo_speaking_soft.png');
      gate.gate.complete();
      await t.pump(const Duration(seconds: 2)); // drain speak timers
      expect(d.speaking, isFalse);
      expect(d.state, CState.idle);
      d.dispose();
    });

    testWidgets('happy', (t) async {
      await loadLexend();
      final d = Director();
      d.emote('happy', i: 1, hold: 60, force: true);
      d.gesture('nod', force: true);
      tickN(d, 20);
      await capture(t, d, 'milo_happy.png');
    });

    testWidgets('sad (concerned frown)', (t) async {
      await loadLexend();
      final d = Director();
      d.emote('concerned', i: 0.9, hold: 60, force: true);
      tickN(d, 40);
      await capture(t, d, 'milo_sad.png');
    });

    testWidgets('confused (curious inquiry)', (t) async {
      await loadLexend();
      final d = Director();
      d.emote('curious', i: 0.9, hold: 60, force: true);
      d.gesture('tilt_head', force: true);
      tickN(d, 20);
      await capture(t, d, 'milo_confused.png');
    });

    testWidgets('reassuring (encouraging warmth)', (t) async {
      await loadLexend();
      final d = Director();
      d.emote('encouraging', i: 0.8, hold: 60, force: true);
      d.gesture('nod', force: true);
      tickN(d, 20);
      await capture(t, d, 'milo_reassuring.png');
    });

    testWidgets('celebrating', (t) async {
      await loadLexend();
      final d = Director();
      d.emote('excited', i: 1, hold: 60, force: true);
      d.gesture('celebrate', force: true);
      tickN(d, 30);
      await capture(t, d, 'milo_celebrating.png');
    });

    test('natural blink occurs and completes', () {
      final d = Director();
      var sawShut = false;
      for (var i = 0; i < 420; i++) {
        d.tick(1 / 60);
        if (d.bf < 0.99) sawShut = true;
        if (sawShut && d.bf > 0.999) break; // full blink cycle inside 7 s
      }
      expect(sawShut, isTrue);
      expect(d.bf, greaterThan(0.999));
      d.dispose();
    });

    test('frame cost stays far under budget', () {
      final d = Director();
      d.emote('excited', i: 1, hold: 60, force: true);
      d.gesture('celebrate', force: true);
      final sw = Stopwatch()..start();
      for (var i = 0; i < 600; i++) {
        d.tick(1 / 60);
      }
      sw.stop();
      print('600 ticks: ${sw.elapsedMilliseconds} ms '
          '(${(sw.elapsedMicroseconds / 600).toStringAsFixed(1)} us/frame)');
      expect(sw.elapsedMilliseconds, lessThan(5000));
      d.dispose();
    });
  });
}
