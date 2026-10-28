import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_tts/flutter_tts.dart';
import '../net/api.dart';

/// Voice output pipeline (Phase 4B). Three layers:
///
/// - [PlatformVoice]: the phone's own TTS (offline, always available).
///   Verbatim behaviour of the pre-Phase-4 Director speech path.
/// - [NeuralVoice]: gateway `/v1/speak` sentences with envelope lip-sync,
///   prefetch pipelining, a fixed-line cache, and prompt cancellation.
/// - [VoiceRouter]: picks per turn (auto/online/offline + health). Neural
///   failure mid-turn finishes the REMAINING sentences on platform with at
///   most one calm notice; user barge-in cancels everything with no notice.
///
/// Until the 4A bake-off winner lands plus a verified playback package, the
/// shipped sink is [NoopAudioSink] (times audio honestly, emits no sound),
/// so `auto` always resolves to platform: zero behaviour regression. The
/// whole neural path is real and unit-tested behind injected fakes.

enum VoiceEventKind { started, word, ended, failed }

class VoiceEvent {
  const VoiceEvent(this.kind, {this.charOffset = -1, this.error = ''});
  final VoiceEventKind kind;
  final int charOffset; // word-callback char offset (sentence-local)
  final String error;
}

/// Neural fetch failed before any audio: the router re-speaks this sentence
/// on platform.
class VoiceFetchFailed implements Exception {
  const VoiceFetchFailed(this.cause);
  final Object cause;
}

/// Neural playback failed after audio started: the router moves ON (no repeat).
class VoicePlayFailed implements Exception {
  const VoicePlayFailed(this.cause);
  final Object cause;
}

abstract class VoiceOutput {
  Stream<VoiceEvent> get events;
  Future<void> speakSentence(String text,
      {double pitch = 1, double rate = 1, String lang = 'en', String profile = '', Map<String, String> style = const {}, void Function(double)? onMouth});
  Future<void> stopNow();
  Future<void> dispose();
}

/// The phone's TTS engine. Same calls the Director always made: pitch/rate
/// per sentence, completion-awaiting speak, word-progress events.
class PlatformVoice extends VoiceOutput {
  PlatformVoice({FlutterTts Function()? ttsFactory}) : _ttsFactory = ttsFactory ?? FlutterTts.new;
  final FlutterTts Function() _ttsFactory;
  FlutterTts? _tts;
  final _events = StreamController<VoiceEvent>.broadcast();
  @override
  Stream<VoiceEvent> get events => _events.stream;
  bool get ready => _tts != null;

  Future<void> init() async {
    try {
      _tts = _ttsFactory();
      await _tts!.awaitSpeakCompletion(true);
      _tts!.setProgressHandler((t, s, e, w) => _events.add(VoiceEvent(VoiceEventKind.word, charOffset: s)));
    } catch (_) {
      _tts = null;
    } // no TTS engine: visual-only level of the offline ladder
  }

  Future<void> applyVoice({required String lang, required String voice, required String locale, required double pitch, required double rate}) async {
    try {
      await _tts?.setLanguage(lang);
      if (voice.isNotEmpty) await _tts?.setVoice({'name': voice, 'locale': locale});
      await _tts?.setPitch(pitch);
      await _tts?.setSpeechRate(rate);
    } catch (_) {}
  }

  /// Null when there is no engine at all ("default voice only", still
  /// usable); empty list when the engine reports no voices.
  Future<List<Map<String, String>>?> getVoices() async {
    if (_tts == null) return null;
    try {
      final v = await _tts!.getVoices;
      return [for (final e in (v as List?) ?? []) {'name': '${e['name'] ?? ''}', 'locale': '${e['locale'] ?? ''}'}]
          .where((m) => m['name']!.isNotEmpty)
          .toList();
    } catch (_) {
      return [];
    }
  }

  @override
  Future<void> speakSentence(String text,
      {double pitch = 1, double rate = 1, String lang = 'en', String profile = '', Map<String, String> style = const {}, void Function(double)? onMouth}) async {
    _events.add(const VoiceEvent(VoiceEventKind.started));
    try {
      await _tts?.setPitch(pitch);
      await _tts?.setSpeechRate(rate);
      await _tts?.speak(text);
    } catch (_) {
      _events.add(const VoiceEvent(VoiceEventKind.failed, error: 'platform_tts_failed'));
    }
    _events.add(const VoiceEvent(VoiceEventKind.ended));
  }

  @override
  Future<void> stopNow() async {
    try {
      await _tts?.stop();
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    await stopNow();
    await _events.close();
  }
}

/// Device audio output for neural PCM. Only a real sink makes neural
/// eligible; timing-only sinks keep the pipeline testable and honest.
abstract class AudioSink {
  bool get isReal;
  Future<void> play(Uint8List pcm, {List<double> envelope = const [], void Function(double)? onLevel});
  Future<void> stop();
}

/// Times neural audio honestly (drives lip-sync, queue and latency stats)
/// but emits no sound. Shipped default until the 4A winner + a verified
/// playback package (`audioplayers`/`flutter_soloud`/`just_audio` — needs
/// network + device to evaluate) land. Never selected in `auto` mode.
class NoopAudioSink extends AudioSink {
  bool _stop = false;
  Future<void>? _playing;
  @override
  bool get isReal => false;
  @override
  Future<void> play(Uint8List pcm, {List<double> envelope = const [], void Function(double)? onLevel}) {
    _stop = false;
    return _playing = _run(pcm, envelope, onLevel);
  }

  Future<void> _run(Uint8List pcm, List<double> envelope, void Function(double)? onLevel) async {
    final ms = pcm.length ~/ 48; // 24 kHz mono16
    var el = 0;
    while (el < ms && !_stop) {
      final t = ms == 0 ? 1.0 : el / ms;
      final v = envelope.isEmpty ? (t < 1 ? .5 : 0.0) : envelope[(t * (envelope.length - 1)).round().clamp(0, envelope.length - 1)];
      onLevel?.call(v.toDouble());
      await Future.delayed(const Duration(milliseconds: 50));
      el += 50;
    }
    onLevel?.call(0);
  }

  @override
  Future<void> stop() async {
    _stop = true;
    try {
      await _playing; // in-flight play fully exits before a new one starts: never overlapping
    } catch (_) {}
  }
}

class _Fetched {
  _Fetched(this.pcm, this.envelope, this.engine, this.cached);
  final Uint8List pcm;
  final List<double> envelope;
  final String engine;
  final bool cached;
}

class _Job {
  _Job(this.text, this.lang, this.profile, this.pace, this.style, this.onMouth, this.gen);
  final String text, lang, profile;
  final double pace;
  final Map<String, String> style;
  final void Function(double)? onMouth;
  final int gen;
  late Future<_Fetched> fetch;
  final startedAt = DateTime.now();
  final done = Completer<void>();
}

/// Gateway neural voice: sentence fetch (cache, else `/v1/speak`) plus
/// gapless playback. Fetches start EAGERLY at enqueue so sentence N+1 is
/// in flight while N plays; playback stays strictly sequential.
Future<String?> _nullCacheGet(String _) async => null;
Future<void> _nullCachePut(String _, String __) async {}

class NeuralVoice extends VoiceOutput {
  NeuralVoice({this.api, required this.sink, this.cacheGet = _nullCacheGet, this.cachePut = _nullCachePut});
  MiloApi? api; // set by app wiring; null (tests, bare Director) fails fetches to platform honestly
  final AudioSink sink;
  Future<String?> Function(String key) cacheGet; // app wiring: db.get
  Future<void> Function(String key, String json) cachePut; // app wiring: db.put
  final _events = StreamController<VoiceEvent>.broadcast();
  final _pending = <_Job>[];
  final _tokens = <CancelToken>{};
  bool _pumping = false;
  int _gen = 0;
  _Job? _active; // job currently fetching/playing (already out of _pending)

  int lastFirstAudioMs = -1; // fetch-start → play-start, for the Lab
  int queueDepth = 0; // for the Lab
  String lastEngine = ''; // for the Lab

  @override
  Stream<VoiceEvent> get events => _events.stream;

  static String cacheKey(String text, String lang, String profile, double pace) =>
      // Pace rounded to 0.1: the speed slider is continuous, and a <5% tempo
      // difference is inaudible — without this the cache would never hit.
      'voice.cache.${sha256.convert(utf8.encode('$text|$lang|$profile|${pace.toStringAsFixed(1)}')).toString().substring(0, 16)}';

  /// Fetches (and caches) one sentence without playing it. Returns false on
  /// any failure — the caller reports, never throws, during bulk downloads.
  Future<bool> prefetch(String text, {String lang = 'en', String profile = '', double pace = 1, Map<String, String> style = const {}}) async {
    try {
      await _fetch(text: text, lang: lang, profile: profile.isEmpty ? 'milo_warm_en' : profile, pace: pace, style: style);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<_Fetched> _fetch({required String text, required String lang, required String profile, required double pace, required Map<String, String> style}) async {
    final key = cacheKey(text, lang, profile, pace);
    try {
      final hit = await cacheGet(key);
      if (hit != null) {
        final m = jsonDecode(hit) as Map<String, dynamic>;
        return _Fetched(base64Decode(m['pcm'] as String),
            [for (final v in (m['env'] as List)) (v as num).toDouble()], '${m['engine']}', true);
      }
    } catch (_) {} // corrupt cache entry: refetch below
    final a = api;
    if (a == null) throw VoiceFetchFailed('no api');
    final token = CancelToken();
    _tokens.add(token);
    try {
      final s = await a.speakOnline(
          text: text, lang: lang, profile: profile, pace: pace, style: style, cancelToken: token);
      if (s.engine != 'mock') {
        try {
          await cachePut(key, jsonEncode({'pcm': base64Encode(s.pcm), 'env': s.envelope, 'engine': s.engine}));
        } catch (_) {} // cache is best-effort; speech already succeeded
      }
      return _Fetched(s.pcm, s.envelope, s.engine, false);
    } finally {
      _tokens.remove(token);
    }
  }

  @override
  Future<void> speakSentence(String text,
      {double pitch = 1, double rate = 1, String lang = 'en', String profile = '', Map<String, String> style = const {}, void Function(double)? onMouth}) {
    final job = _Job(text, lang, profile.isEmpty ? 'milo_warm_en' : profile, rate, style, onMouth, _gen);
    job.fetch = _fetch(text: text, lang: job.lang, profile: job.profile, pace: job.pace, style: style); // eager: in flight while earlier sentences play
    job.done.future.then((_) {}, onError: (_) {}); // abandoned-after-fallback jobs must not surface unhandled errors
    _pending.add(job);
    unawaited(_pump());
    return job.done.future;
  }

  Future<void> _pump() async {
    if (_pumping) return;
    _pumping = true;
    try {
      while (_pending.isNotEmpty) {
        final job = _pending.removeAt(0);
        _active = job;
        queueDepth = _pending.length;
        _Fetched f;
        try {
          f = await job.fetch;
        } on VoiceCancelled {
          if (!job.done.isCompleted) job.done.complete(); // barge-in: dropped, not failed
          continue;
        } catch (e) {
          if (!job.done.isCompleted) job.done.completeError(VoiceFetchFailed(e));
          _events.add(const VoiceEvent(VoiceEventKind.failed, error: 'fetch'));
          continue;
        }
        if (job.gen != _gen || job.done.isCompleted) continue; // cancelled while fetching
        _events.add(const VoiceEvent(VoiceEventKind.started));
        lastFirstAudioMs = DateTime.now().difference(job.startedAt).inMilliseconds;
        lastEngine = f.engine;
        try {
          await sink.play(f.pcm, envelope: f.envelope, onLevel: job.onMouth);
        } catch (e) {
          if (!job.done.isCompleted) job.done.completeError(VoicePlayFailed(e));
          _events.add(const VoiceEvent(VoiceEventKind.failed, error: 'play'));
          continue;
        }
        if (job.gen != _gen) {
          if (!job.done.isCompleted) job.done.complete(); // cancelled mid-play: no error, no repeat
          continue;
        }
        _events.add(const VoiceEvent(VoiceEventKind.ended));
        if (!job.done.isCompleted) job.done.complete();
      }
    } finally {
      _pumping = false;
      queueDepth = _pending.length;
    }
  }

  /// Barge-in: cancels in-flight fetches + playback + queue. All local and
  /// prompt (≤150 ms); the HTTP calls are cancelled, never left to overlap.
  @override
  Future<void> stopNow() async {
    _gen++;
    for (final t in _tokens.toList()) {
      try {
        t.cancel();
      } catch (_) {}
    }
    _tokens.clear();
    for (final j in _pending) {
      if (!j.done.isCompleted) j.done.complete();
    }
    _pending.clear();
    if (_active != null && !_active!.done.isCompleted) _active!.done.completeError(const VoiceCancelled());
    queueDepth = 0;
    await sink.stop();
  }

  @override
  Future<void> dispose() async {
    await stopNow();
    await _events.close();
  }
}

enum VoiceEngineMode { auto, online, offline }

/// Per-turn engine choice. `auto` uses neural only when the sink is real,
/// the ladder is full and the caller allows online; `online` tries neural
/// and falls back; `offline` is always platform. Read-aloud (word callbacks)
/// always stays on platform: neural engines supply no word timings.
class VoiceRouter {
  VoiceRouter({required this.platform, required this.neural});
  final PlatformVoice platform;
  final NeuralVoice neural;
  VoiceEngineMode mode = VoiceEngineMode.auto;
  bool Function() onlineAllowed = () => true; // wired to ladder==full && cloud on
  String engineInUse = 'platform'; // Lab readout

  static String voiceIdFor(String lang) => 'milo_warm_${const ['en', 'hi', 'ml'].contains(lang) ? lang : 'en'}';

  bool get neuralReady => neural.sink.isReal && onlineAllowed();

  /// Speaks every sentence in order. Returns a notice code when neural
  /// failed and platform covered (`online_voice_failed`,
  /// `online_voice_unavailable`), else null. At most one notice per call;
  /// platform-covered sentences are never repeated.
  Future<String?> speakAll(List<({String text, int wordOffset})> sentences,
      {required double pitch, required double rate, double pace = 1, String lang = 'en', String? tone, bool readAloud = false, void Function(double)? onMouth, Future<void> Function(String sentence)? onSentence}) async {
    var useNeural = switch (mode) {
      VoiceEngineMode.offline => false,
      VoiceEngineMode.online => true,
      VoiceEngineMode.auto => neuralReady,
    } && !readAloud;
    engineInUse = useNeural ? 'neural' : 'platform';
    String? notice;
    if (sentences.isNotEmpty && mode == VoiceEngineMode.online && !neuralReady && !readAloud) notice = 'online_voice_unavailable';
    for (var i = 0; i < sentences.length; i++) {
      final s = sentences[i];
      if (useNeural) {
        try {
          await neural.speakSentence(s.text, rate: pace, lang: lang, profile: voiceIdFor(lang),
              style: tone == null ? const {} : {'emotion': tone}, onMouth: onMouth);
          await onSentence?.call(s.text);
          continue;
        } on VoiceCancelled {
          rethrow; // user barge-in: stop everything, no fallback, no notice
        } on VoicePlayFailed {
          notice ??= 'online_voice_failed';
          useNeural = false;
          await neural.stopNow(); // drain prefetches: nothing neural may play over platform
          continue; // partially heard: move on, never repeat
        } catch (_) {
          notice ??= 'online_voice_failed';
          useNeural = false;
          await neural.stopNow(); // drain prefetches: nothing neural may play over platform
        } // fetch failed: platform speaks this one + the rest
      }
      await platform.speakSentence(s.text, pitch: pitch, rate: rate);
      await onSentence?.call(s.text);
    }
    return notice;
  }

  Future<void> stopNow() async {
    await neural.stopNow();
    await platform.stopNow();
  }

  Future<void> dispose() async {
    await neural.dispose();
    await platform.dispose();
  }
}
