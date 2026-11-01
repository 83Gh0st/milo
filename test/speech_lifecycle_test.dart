import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/voice/voice_output.dart';

/// Speech-lifecycle invariants: the mouth moves only with proven audio,
/// and every failure, cancellation, and overlap returns to a clean
/// resting state. See docs/VOICE_CHECKLIST.md for the matching device
/// checklist.
class OkPlatform extends PlatformVoice {
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

class FailPlatform extends PlatformVoice {
  final spoken = <String>[];
  final int failAfter; // ok sentences before failing (-1 = fail at once)
  FailPlatform({this.failAfter = -1});
  @override
  Future<void> speakSentence(String text,
      {double pitch = 1,
      double rate = 1,
      String lang = 'en',
      String profile = '',
      Map<String, String> style = const {},
      void Function(double)? onMouth}) async {
    if (failAfter >= 0 && spoken.length < failAfter) {
      spoken.add(text);
      await Future.delayed(const Duration(milliseconds: 2));
      return;
    }
    throw VoicePlayFailed(StateError('tts exploded'));
  }
}

class SlowPlatform extends PlatformVoice {
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
    await Future.delayed(const Duration(milliseconds: 200));
  }
}

Director speakingDirector(PlatformVoice platform) {
  final d = Director();
  d.voice =
      VoiceRouter(platform: platform, neural: NeuralVoice(
        sink: NoopAudioSink()));
  return d;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    // tapMilo() vibrates: swallow haptics in tests (no platform handler).
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform,
            (call) async => null);
  });

  group('speech lifecycle', () {
    test('empty and whitespace text never enter the speaking state',
        () async {
      final p = OkPlatform();
      final d = speakingDirector(p);
      await d.speak('');
      await d.speak('   ');
      expect(d.state, CState.idle);
      expect(d.speaking, isFalse);
      expect(p.spoken, isEmpty);
      d.dispose();
    });

    test('no TTS engine: silent caption, still mouth, clean idle',
        () async {
      // Default platform voice, never initialised: no engine.
      final d = Director();
      await d.speak('Hello world');
      expect(d.state, CState.idle);
      expect(d.speaking, isFalse);
      for (var j = 0; j < 30; j++) {
        d.tick(0.033);
      }
      expect(d.pulse, 0);
      // Baseline only: no estimated pulses over silence.
      expect(d.mouth, d.face.mouth);
      d.dispose();
    });

    test('platform failure mid-utterance: mouth shuts, turn ends idle',
        () async {
      final p = FailPlatform(failAfter: 1);
      final d = speakingDirector(p);
      await d.speak('One two. Three four.');
      // First sentence heard, second failed.
      expect(p.spoken.length, 1);
      expect(d.state, CState.idle);
      expect(d.speaking, isFalse);
      expect(d.pulse, 0);
      d.dispose();
    });

    test('cancellation mid-speech returns to idle with no stuck state',
        () async {
      final p = SlowPlatform();
      final d = speakingDirector(p);
      final f = d.speak('Hello there friend');
      await Future.delayed(const Duration(milliseconds: 20));
      expect(d.speaking, isTrue);
      d.cancelSpeech();
      expect(d.speaking, isFalse);
      expect(d.state, CState.idle);
      await f; // the cancelled speak resolves without touching state
      expect(d.state, CState.idle);
      expect(d.pulse, 0);
      d.dispose();
    });

    test('barge-in tap stops speech and listens; settling is clean',
        () async {
      final p = SlowPlatform();
      final d = speakingDirector(p);
      final f = d.speak('Hello there friend, this is a long line');
      await Future.delayed(const Duration(milliseconds: 20));
      d.tapMilo(); // barge-in
      expect(d.speaking, isFalse);
      expect(d.state, CState.listening);
      // Settle before teardown (disarms the 8 s fallback timer).
      d.setListening(false);
      await f;
      expect(d.state, CState.idle);
      d.dispose();
    });

    test('rapid taps: first tap speaks, the rest are motion only',
        () async {
      final p = OkPlatform();
      final d = speakingDirector(p);
      d.tapMilo();
      // The greeting speaks, then the caption hold settles: wait for the
      // turn to finish rather than assuming a fixed 50 ms.
      final t0 = DateTime.now();
      while (d.speaking &&
          DateTime.now().difference(t0) < const Duration(seconds: 5)) {
        await Future.delayed(const Duration(milliseconds: 25));
      }
      expect(p.spoken, isNotEmpty); // the advertised action: Milo says hi
      expect(d.speaking, isFalse);
      final n = p.spoken.length;
      for (var i = 0; i < 4; i++) {
        d.tapMilo(); // debounced: bounce and blink, never stacked speech
      }
      await Future.delayed(const Duration(milliseconds: 50));
      expect(p.spoken.length, n);
      expect(d.state, CState.idle);
      d.dispose();
    });

    test('overlapping speaks: the newest wins, both settle, nothing throws',
        () async {
      final p = SlowPlatform();
      final d = speakingDirector(p);
      final a = d.speak('First long line here');
      await Future.delayed(const Duration(milliseconds: 20));
      final b = d.speak('Second line here');
      await Future.wait([a, b]);
      expect(d.speaking, isFalse);
      expect(d.state, CState.idle);
      d.dispose();
    });

    test('stale envelope feeds after speech ends are ignored', () async {
      final p = OkPlatform();
      final d = speakingDirector(p);
      await d.speak('Hi');
      final base = d.face.mouth;
      d.feedMouth(0.9); // late neural callback for a finished utterance
      d.tick(0.016);
      expect(d.mouth, base);
      d.dispose();
    });

    test('giggle and hum move the body, never the mouth', () async {
      final d = speakingDirector(OkPlatform());
      for (final clip in ['giggle', 'hum', 'thinking_hmm']) {
        d.gesture(clip, force: true);
        for (var j = 0; j < 40; j++) {
          d.tick(0.033);
        }
        expect(d.pulse, 0, reason: clip);
        expect(d.mouth, d.face.mouth, reason: clip);
      }
      d.dispose();
    });

    test('voice off: captions without mouth movement or audio', () async {
      final p = OkPlatform();
      final d = speakingDirector(p);
      d.voiceOn = false;
      await d.speak('Hello world');
      expect(p.spoken, isEmpty);
      expect(d.pulse, 0);
      expect(d.mouth, d.face.mouth);
      expect(d.state, CState.idle);
      d.dispose();
    });

    test('cancel while idle and dispose mid-speech are safe', () async {
      final d = speakingDirector(OkPlatform());
      d.cancelSpeech(); // idle: no-op, no state change
      expect(d.state, CState.idle);
      final p2 = SlowPlatform();
      final d2 = speakingDirector(p2);
      final f = d2.speak('Hello world');
      await Future.delayed(const Duration(milliseconds: 20));
      // Disposal mid-utterance must not throw or notify after dispose.
      d2.dispose();
      await f;
      d.dispose();
    });
  });
}
