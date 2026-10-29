import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/data/secure_store.dart';
import 'package:milo/net/api.dart';
import 'package:milo/voice/normalize.dart';
import 'package:milo/voice/voice_output.dart';

import 'helpers/fake_db.dart';
import 'helpers/harness.dart';

// ---------- fakes ----------

class FakePlatform extends PlatformVoice {
  final spoken = <String>[];
  @override
  Future<void> speakSentence(String text,
      {double pitch = 1, double rate = 1, String lang = 'en', String profile = '', Map<String, String> style = const {}, void Function(double)? onMouth}) async {
    spoken.add(text);
    await Future.delayed(const Duration(milliseconds: 2));
  }
}

class FakeSink extends AudioSink {
  @override
  bool isReal = true;
  int active = 0, maxActive = 0;
  final played = <int>[];
  final levels = <double>[];
  bool failPlay = false;
  Duration playTime = const Duration(milliseconds: 10);
  bool _stop = false;
  Future<void>? _playing;

  @override
  Future<void> play(Uint8List pcm, {List<double> envelope = const [], void Function(double)? onLevel}) {
    _stop = false;
    return _playing = _run(pcm, envelope, onLevel);
  }

  Future<void> _run(Uint8List pcm, List<double> envelope, void Function(double)? onLevel) async {
    active++;
    if (active > maxActive) maxActive = active;
    played.add(pcm.length);
    try {
      if (failPlay) throw StateError('sink exploded');
      var el = 0;
      while (el < playTime.inMilliseconds && !_stop) {
        final t = playTime.inMilliseconds == 0 ? 1.0 : el / playTime.inMilliseconds;
        final v = envelope.isEmpty ? .5 : envelope[(t * (envelope.length - 1)).round().clamp(0, envelope.length - 1)];
        levels.add(v.toDouble());
        onLevel?.call(v.toDouble());
        await Future.delayed(const Duration(milliseconds: 2));
        el += 2;
      }
      onLevel?.call(0);
    } finally {
      active--;
    }
  }

  @override
  Future<void> stop() async {
    _stop = true;
    try {
      await _playing;
    } catch (_) {}
  }
}

({FakeDb db, FakeApi api, FakePlatform platform, FakeSink sink, Map<String, String> cache, NeuralVoice neural, VoiceRouter router}) rig() {
  final db = FakeDb();
  final api = FakeApi(db, SecureStore());
  final platform = FakePlatform();
  final sink = FakeSink();
  final cache = <String, String>{};
  final neural = NeuralVoice(api: api, sink: sink, cacheGet: (k) async => cache[k], cachePut: (k, v) async => cache[k] = v);
  return (db: db, api: api, platform: platform, sink: sink, cache: cache, neural: neural, router: VoiceRouter(platform: platform, neural: neural));
}

List<({String text, int wordOffset})> parts(List<String> ss) => [for (var i = 0; i < ss.length; i++) (text: ss[i], wordOffset: i)];

// ---------- normalizer ----------

void main() {
  group('normalize', () {
    test('abbreviations, digits, numbers, emoji', () {
      expect(normalizeForSpeech('Dr. Milo read 12 pages, e.g. this one! 🎉', 'en'),
          'Doctor Milo read twelve pages, for example this one!');
      expect(normalizeForSpeech('OK, call Mr. Rao', 'en'), 'okay, call Mister Rao');
    });
    test('native digits map to latin, other scripts survive', () {
      expect(normalizeForSpeech('पेज १२ पढ़ो', 'hi'), 'पेज 12 पढ़ो');
      expect(normalizeForSpeech('വായന ൩', 'ml'), 'വായന 3');
      expect(normalizeForSpeech('बहुत बढ़िया!', 'hi'), 'बहुत बढ़िया!');
    });
    test('Milo keeps its name; lexicon is a hook, not a guess', () {
      expect(normalizeForSpeech('Hello, I’m Milo.', 'en'), 'Hello, I’m Milo.');
      expect(normalizeForSpeech('Hello, I’m Milo.', 'en', lexicon: {'Milo': 'My low'}), 'Hello, I’m My low.');
    });
    test('splitSentences chunks long sentences with word offsets', () {
      final out = splitSentences('One two three. Four five six seven eight nine ten eleven twelve.', 4);
      expect([for (final s in out) s.text], ['One two three.', 'Four five six seven', 'eight nine ten eleven', 'twelve.']);
      expect([for (final s in out) s.wordOffset], [0, 3, 7, 11]);
      expect(splitSentences('', 10), isEmpty);
      expect(splitSentences('Hi!', 10).single, (text: 'Hi!', wordOffset: 0));
    });
  });

  group('router', () {
    test('auto with a silent sink stays on platform; offline forces platform', () async {
      final r = rig();
      r.sink.isReal = false; // ship state: NoopAudioSink
      expect(await r.router.speakAll(parts(['hi']), pitch: 1, rate: 1), isNull);
      expect(r.router.engineInUse, 'platform');
      expect(r.platform.spoken, ['hi']);
      expect(r.api.speakCalls, 0); // no network touched
      r.router.mode = VoiceEngineMode.offline;
      expect(await r.router.speakAll(parts(['hey']), pitch: 1, rate: 1), isNull);
      expect(r.platform.spoken, ['hi', 'hey']);
    });

    test('online mode uses neural and prefetches; read-aloud stays platform', () async {
      final r = rig();
      r.router.mode = VoiceEngineMode.online;
      expect(await r.router.speakAll(parts(['one', 'two', 'three']), pitch: 1, rate: 1), isNull);
      expect(r.router.engineInUse, 'neural');
      expect(r.sink.played.length, 3);
      expect(r.api.speakCalls, 3);
      expect(r.platform.spoken, isEmpty);
      // Read-aloud keeps word callbacks: platform even in online mode.
      expect(await r.router.speakAll(parts(['read me']), pitch: 1, rate: 1, readAloud: true), isNull);
      expect(r.platform.spoken, ['read me']);
    });

    test('fetches start eagerly while earlier sentences play', () async {
      final r = rig();
      r.api.speakDelay = const Duration(milliseconds: 30);
      final f1 = r.neural.speakSentence('one');
      final f2 = r.neural.speakSentence('two');
      await Future.delayed(const Duration(milliseconds: 5));
      expect(r.api.speakCalls, 2); // both in flight...
      expect(r.sink.played, isEmpty); // ...before either plays
      await Future.wait([f1, f2]);
      expect(r.sink.played.length, 2); // ...yet playback stays sequential
    });

    test('fetch failure mid-turn: platform finishes, one notice, no repeats', () async {
      final r = rig();
      r.router.mode = VoiceEngineMode.online;
      r.api.failSpeak = true;
      final notice = await r.router.speakAll(parts(['a', 'b', 'c']), pitch: 1, rate: 1);
      expect(notice, 'online_voice_failed');
      expect(r.platform.spoken, ['a', 'b', 'c']); // failed sentence re-spoken (nothing was heard), rest covered
      expect(r.sink.played, isEmpty);
    });

    test('play failure after audio started: skip ahead, never repeat', () async {
      final r = rig();
      r.router.mode = VoiceEngineMode.online;
      r.sink.failPlay = true;
      final notice = await r.router.speakAll(parts(['a', 'b']), pitch: 1, rate: 1);
      expect(notice, 'online_voice_failed');
      expect(r.platform.spoken, ['b']); // 'a' was partially heard: move on
    });

    test('barge-in cancels everything with no notice and no stuck state', () async {
      final r = rig();
      r.router.mode = VoiceEngineMode.online;
      r.sink.playTime = const Duration(milliseconds: 200);
      var cancelled = false;
      final f = r.router.speakAll(parts(['a', 'b', 'c']), pitch: 1, rate: 1).then((_) {}, onError: (e) { cancelled = e is VoiceCancelled; });
      await Future.delayed(const Duration(milliseconds: 30));
      final t0 = DateTime.now();
      await r.router.stopNow();
      expect(DateTime.now().difference(t0).inMilliseconds, lessThan(150));
      await f;
      expect(cancelled, isTrue);
      expect(r.neural.queueDepth, 0);
      // Router works again immediately after.
      r.sink.playTime = const Duration(milliseconds: 5);
      expect(await r.router.speakAll(parts(['d']), pitch: 1, rate: 1), isNull);
    });

    test('100 interruptions: never overlapping audio, never stuck', () async {
      final r = rig();
      r.router.mode = VoiceEngineMode.online;
      for (var i = 0; i < 100; i++) {
        final f = r.router.speakAll(parts(['x', 'y']), pitch: 1, rate: 1).then((_) {}, onError: (_) {});
        await Future.delayed(const Duration(milliseconds: 3));
        await r.router.stopNow();
        await f;
      }
      expect(r.sink.maxActive, lessThanOrEqualTo(1));
      expect(r.neural.queueDepth, 0);
      expect(await r.router.speakAll(parts(['ok']), pitch: 1, rate: 1), isNull);
    });

    test('voice identity is stable and independent of the brain', () {
      expect(VoiceRouter.voiceIdFor('en'), 'milo_warm_en');
      expect(VoiceRouter.voiceIdFor('hi'), 'milo_warm_hi');
      expect(VoiceRouter.voiceIdFor('ml'), 'milo_warm_ml');
      expect(VoiceRouter.voiceIdFor('xx'), 'milo_warm_en');
      final a = rig().router..onlineAllowed = () => true;
      final b = rig().router..onlineAllowed = () => false; // resting ladder
      expect(VoiceRouter.voiceIdFor('en'), VoiceRouter.voiceIdFor('en'));
      expect(a.neuralReady, isTrue);
      expect(b.neuralReady, isFalse); // ladder gates neural, never the identity
    });
  });

  group('neural cache', () {
    test('second play is served from cache; mock audio is never cached', () async {
      final r = rig();
      await r.neural.speakSentence('hello', lang: 'en', profile: 'milo_warm_en');
      expect(r.api.speakCalls, 1);
      expect(r.cache.keys.single, startsWith('voice.cache.'));
      await r.neural.speakSentence('hello', lang: 'en', profile: 'milo_warm_en');
      expect(r.api.speakCalls, 1); // cache hit: no refetch
      expect(r.sink.played.length, 2);

      r.api.speakEngine = 'mock'; // placeholder audio must not poison the cache
      await r.neural.speakSentence('other', lang: 'en', profile: 'milo_warm_en');
      expect(r.cache.length, 1);
    });
  });

  group('director speech', () {
    test('bare director speaks headless and settles to idle', () async {
      final d = Director();
      await d.speak('Hello world');
      expect(d.state, CState.idle);
      expect(d.speaking, isFalse);
      d.dispose();
    });

    test('endpointing: partials hold listening, a pause endpoints', () {
      final d = Director();
      d.setListening(true);
      for (var i = 0; i < 10; i++) {
        d.notePartial();
        for (var j = 0; j < 30; j++) {
          d.tick(0.033);
        }
        expect(d.state, CState.listening); // words keep coming: still listening
      }
      for (var j = 0; j < 60; j++) {
        d.tick(0.033);
      }
      expect(d.state, CState.endpointing); // 2 s of silence: endpointed, still attentive
      expect(d.attenLive, isTrue);
      d.setListening(false);
      expect(d.state, CState.idle);
      d.dispose();
    });

    test('mouth follows the envelope and shuts in silence', () async {
      final d = Director();
      d.voice = VoiceRouter(platform: FakePlatform(), neural: rig().neural);
      d.feedMouth(1.0); // not speaking: ignored
      expect(d.mouth, 0);
      d.tick(0.016);
      final base = d.mouth;
      final f = d.speak('Hello there friend');
      d.feedMouth(0.8);
      d.tick(0.016);
      expect(d.mouth, greaterThan(base + 0.3));
      for (var j = 0; j < 60; j++) {
        d.tick(0.033);
      }
      expect((d.mouth - base).abs(), lessThan(0.05)); // no more feeds: decayed to baseline
      await f;
      d.dispose();
    });

    test('listening with a dead server self-exits instead of sticking', () {
      final d = Director();
      d.setListening(true);
      for (var j = 0; j < 800; j++) {
        d.tick(0.033); // 26 s of total silence, no partials, no final
      }
      expect(d.state, CState.idle);
      d.dispose();
    });

    test('aac board speech starts promptly (regression: <200 ms to first audio)', () async {
      final d = Director();
      final platform = FakePlatform();
      d.voice = VoiceRouter(platform: platform, neural: rig().neural);
      final t0 = DateTime.now();
      final f = d.speakAac('I want water');
      while (platform.spoken.isEmpty) {
        await Future.delayed(const Duration(milliseconds: 5));
      }
      expect(DateTime.now().difference(t0).inMilliseconds, lessThan(200));
      await f;
      d.dispose();
    });

    test('voice settings round-trip through persistence', () {
      final d = Director();
      d.loadSettings({'vengine': 'online', 'clear': '1'});
      expect(d.voiceEngine, VoiceEngineMode.online);
      expect(d.voice.mode, VoiceEngineMode.online);
      expect(d.clearSpeech, isTrue);
      final s = d.toSettings();
      expect(s['vengine'], 'online');
      expect(s['clear'], '1');
      d.dispose();
    });
  });
}
