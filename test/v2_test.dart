import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/companion/emotion.dart';
import 'package:milo/companion/greetings.dart';
import 'package:milo/companion/react.dart';
import 'package:milo/companion/sounds.dart';
import 'package:milo/companion/v2/frame.dart';
import 'package:milo/companion/v2/milo2.dart';
import 'package:milo/companion/v2/renderer.dart';
import 'package:milo/companion/v2/rive_stub.dart';
import 'package:milo/contracts/brain_contract.dart';

void main() {
  group('angry-brow rule', () {
    test('no valence>=0 face has inner brow ends lower than outer ends', () {
      for (final e in faces.entries) {
        if (e.value.valence < 0) continue;
        final b = browEnds(e.value, 1);
        expect(b.inner, lessThanOrEqualTo(b.outer + 1e-9), reason: e.key);
      }
    });
    test('concerned raises the inner ends; curious raises one brow', () {
      final c = browEnds(faces['concerned']!, 1);
      expect(c.inner, lessThan(c.outer));
      expect(faces['curious']!.browAsym, greaterThan(0));
    });
  });

  group('v2 geometry', () {
    test('character fills its box in every LOD (>= 85%)', () {
      for (final lod in MiloLod.values) {
        expect(designFill(lod), greaterThanOrEqualTo(.85), reason: lod.name);
      }
    });
    test('motion gain clamps to [1, 2.5]', () {
      expect(gainFor(MiloLod.bust, 140), 1);
      expect(gainFor(MiloLod.full, 100), 2.5); // 260/100 clamps
      expect(gainFor(MiloLod.avatar, 48), 1);
      expect(gainFor(MiloLod.avatar, 1000), 1); // never below 1
    });
    test('gaze travel reads on screen in every LOD', () {
      // buddy box 151x200: k=.755; stage 232+: full LOD; chip 48: avatar
      expect(gazeTravelDesign(MiloLod.bust, .755, 1) * .755, greaterThanOrEqualTo(3));
      expect(gazeTravelDesign(MiloLod.full, 1.16, 1) * 1.16, greaterThanOrEqualTo(5));
      expect(gazeTravelDesign(MiloLod.avatar, .4, 1) * .4, greaterThanOrEqualTo(2));
      // tiny boxes get boosted, never shrunk
      expect(gazeTravelDesign(MiloLod.bust, .3, 1) * .3, greaterThanOrEqualTo(3));
    });
    test('breath moves the chest >= 2 dp', () {
      expect(breathAmpFor(0, 148, .755, 1) * 148 * .755, greaterThanOrEqualTo(2));
      expect(breathAmpFor(.5, 148, 1.16, 1) * 148 * 1.16, greaterThanOrEqualTo(2));
    });
    test('mouth shapes cover all nine', () {
      expect(mouthShape(smile: .3, open: 0, tongue: false), MouthShape.smile);
      expect(mouthShape(smile: 0, open: 0, tongue: false), MouthShape.flat);
      expect(mouthShape(smile: -.5, open: 0, tongue: false), MouthShape.frown);
      expect(mouthShape(smile: .8, open: .5, tongue: false), MouthShape.bigSmile);
      expect(mouthShape(smile: .5, open: .8, tongue: false), MouthShape.openA);
      expect(mouthShape(smile: 0, open: .8, tongue: false), MouthShape.openO);
      expect(mouthShape(smile: .5, open: .1, tongue: true), MouthShape.tongue);
      expect(isPressedShut(open: 0, speaking: true), isTrue);
      expect(isPressedShut(open: 0, speaking: false), isFalse);
      expect(MouthShape.values, hasLength(9));
    });
    test('LOD follows box size; colourways derive from one base', () {
      expect(lodForSize(const Size(300, 232)), MiloLod.full);
      expect(lodForSize(const Size(110, 128)), MiloLod.bust);
      expect(lodForSize(const Size(48, 48)), MiloLod.avatar);
      final cws = colorways(const Color(0xFF8E9BFF));
      expect(cws, hasLength(5));
      final ls = [for (final c in cws) HSLColor.fromColor(c).lightness];
      for (var i = 0; i < 5; i++) {
        expect((ls[i] - [.35, .45, .55, .65, .75][i]).abs(), lessThan(.01)); // sRGB round-trip drifts
      }
    });
    test('Rive stub throws until a real asset exists', () {
      expect(() => const RiveRenderer().paint(TestCanvas(), const Size(10, 10),
          DirectorFrame.fromDirector(Director(), lod: MiloLod.full, look: MiloLook.a, renderedDp: 200)),
          throwsUnimplementedError);
    });
  });

  group('idle + reactions', () {
    test('idle library has 20 behaviours; gaze subset is clip-free', () {
      expect(Director.idleFull, hasLength(20));
      expect(Director.idleGaze.every(Director.idleFull.contains), isTrue);
      final d = Director();
      for (final n in Director.idleGaze) {
        d.debugFidget(n);
        expect(d.clips, isEmpty, reason: n);
      }
      for (final n in Director.idleFull) {
        d.debugFidget(n); // every behaviour runs without error
      }
      expect(Director.idleFull.toSet(), hasLength(20));
    });
    test('reactions are synchronous, rate-limited and presence-aware', () async {
      final d = Director();
      await d.init(); // wires MiloReact.handler; platform calls are guarded
      addTearDown(() { MiloReact.handler = null; });
      d.tick(.016);
      MiloReact.notify(const ReactEvent(ReactKind.pressDown, at: Offset(10, 10)));
      expect(d.touch, isNotNull); // eyes snap on the same call (<100 ms = next frame)
      expect(d.sq.v, -1.2); // tiny lean on press
      final until = d.touchUntil;
      MiloReact.notify(const ReactEvent(ReactKind.pressDown, at: Offset(50, 50)));
      expect(d.touchUntil, until); // rate-limited within the window
      d.set(() => d.presenceOverride = Presence.chip);
      d.presence = Presence.chip;
      d.sq.v = 0;
      d.clock += 1; // leave the rate window
      MiloReact.notify(const ReactEvent(ReactKind.pressDown, at: Offset(10, 10)));
      expect(d.sq.v, 0); // gaze-only in Chip
      d.set(() => d.quiet = true);
      d.touch = null;
      d.clock += 1;
      MiloReact.notify(const ReactEvent(ReactKind.pressDown, at: Offset(10, 10)));
      expect(d.touch, isNull); // silent in quiet mode
    });
    test('hub swallows handler errors; bad sounds are ignored', () async {
      MiloReact.handler = (_) => throw StateError('boom');
      addTearDown(() { MiloReact.handler = null; });
      MiloReact.notify(const ReactEvent(ReactKind.sent)); // must not throw
      final s = MiloSounds();
      await s.play('nope', quiet: false, aac: false, presence: 'stage');
      expect(s.playedForTest, isEmpty);
    });
    test('sound gates: quiet/aac/chip/hidden stay silent', () async {
      final rec = _Rec();
      final s = MiloSounds(backend: rec);
      await s.play('success', quiet: true, aac: false, presence: 'stage');
      await s.play('success', quiet: false, aac: true, presence: 'stage');
      await s.play('success', quiet: false, aac: false, presence: 'chip');
      await s.play('success', quiet: false, aac: false, presence: 'hidden');
      expect(rec.calls, isEmpty);
      await s.play('success', quiet: false, aac: false, presence: 'stage');
      expect(rec.calls, ['assets/sounds/success.wav']);
      expect(kSoundNames, hasLength(14));
    });
    test('ten idle seconds always show visible non-blink motion', () {
      final d = Director();
      final brs = <double>[];
      final gazes = <double>{};
      for (var i = 0; i < 600; i++) {
        d.tick(1 / 60);
        brs.add(d.br);
        gazes.add(d.eyeX.t);
      }
      expect(brs.reduce((a, b) => a > b ? a : b) - brs.reduce((a, b) => a < b ? a : b), greaterThan(1));
      expect(gazes.length, greaterThan(1)); // wander + jitter retarget the eyes
    });
  });

  group('mood + greetings + ladder', () {
    test('greetings are deterministic, pooled and guilt-free', () {
      final a = greetingFor(Profile.friendly, 'en', DateTime(2026, 10, 28, 9), 5, 'home');
      final b = greetingFor(Profile.friendly, 'en', DateTime(2026, 10, 28, 9), 5, 'home');
      expect(a, b);
      expect(greetingFor(Profile.playful, 'hi', DateTime(2026, 10, 28), 0, ''), isNotEmpty); // first day
      for (final p in Profile.values) {
        for (final l in ['en', 'hi', 'ml']) {
          final pool = greetingPool(p, l);
          expect(pool, hasLength(8), reason: '$p/$l');
          for (final line in pool) {
            expect(line.toLowerCase(), isNot(contains('streak')));
            expect(line.toLowerCase(), isNot(contains('missed')));
            expect(line.toLowerCase(), isNot(contains('guilt')));
          }
        }
      }
      // the pool is actually used across days
      final seen = {for (var day = 1; day <= 12; day++) greetingFor(Profile.friendly, 'en', DateTime(2026, 1, day, 20), 9, 'chat')};
      expect(seen.length, greaterThan(1));
    });
    test('ladder choices route locally; contract gestures all exist as clips', () {
      final d = Director();
      d.choices = ['Keep waiting', Director.kOfflineChoice];
      d.choose('Keep waiting');
      expect(d.choices, isEmpty);
      expect(kGestures, hasLength(14));
      for (final g in kGestures) {
        expect(Director.clipNames, contains(g), reason: g);
      }
    });
    test('settings round-trip the new fields', () {
      final d = Director();
      d.set(() { d.look = MiloLook.c; d.moodBase = .2; d.soundOn = false; d.soundVol = .5; d.daysTogether = 9; });
      final back = Director()..loadSettings(d.toSettings());
      expect(back.look, MiloLook.c);
      expect(back.moodBase, .2);
      expect(back.soundOn, isFalse);
      expect(back.soundVol, .5);
      expect(back.daysTogether, 9);
    });
  });
}

class _Rec implements SoundBackend {
  final calls = <String>[];
  @override
  Future<void> play(String asset, double volume) async { calls.add(asset); }
}

/// Minimal Canvas stand-in: only used to prove the stub throws first.
class TestCanvas implements Canvas {
  @override
  dynamic noSuchMethod(Invocation i) => throw UnimplementedError('test canvas');
}
