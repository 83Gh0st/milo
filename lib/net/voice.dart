import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:record/record.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import '../config.dart';
import 'api.dart';

/// RMS amplitude of 24 kHz mono PCM16 bytes, scaled to 0..1 for the live
/// waveform. Pure math over the chunk in flight; nothing is kept.
double micRms(Uint8List b) {
  if (b.length < 2) return 0;
  final bd = b.buffer.asByteData(b.offsetInBytes, b.length);
  var sum = 0.0, n = 0;
  for (var i = 0; i + 1 < b.length; i += 2) {
    final v = bd.getInt16(i, Endian.little) / 32768;
    sum += v * v;
    n++;
  }
  return n == 0 ? 0 : (math.sqrt(sum / n) * 4).clamp(0.0, 1.0).toDouble();
}

/// Minimum streamed audio for a real utterance (0.1 s of 24 kHz PCM16).
/// Shorter is a tap or silence, reported as too_short - never sent as speech.
const kMinVoiceBytes = 4800;

/// Push-to-talk voice input: 24 kHz mono PCM16 -> gateway -> Muse Voice
/// Transcribe (speech-to-text only; Milo's spoken replies use the existing
/// phone TTS / neural voice path, never the transcriber). Audio is never
/// stored on the phone. The final transcript is delivered via onFinal and
/// the caller passes it straight into the conversation - no manual copy.
class VoiceClient {
  VoiceClient(this.api);
  final MiloApi api;
  final _rec = AudioRecorder();
  WebSocketChannel? _ch;
  StreamSubscription? _a, _w;
  bool active = false;
  int _sentBytes = 0;
  bool _gotSpeech = false;
  Completer<void>? _finalWait;
  Future<bool> requestPermission() => _rec.hasPermission(); // shows the system prompt the first time

  Future<void> start({required void Function(String) onPartial, required void Function(String) onFinal, required void Function(String) onError, void Function(double)? onLevel, String lang = 'English'}) async {
    if (active) return;
    _sentBytes = 0;
    _gotSpeech = false;
    _finalWait = Completer<void>();
    try {
      if (!await _rec.hasPermission()) { onError('mic_denied'); return; }
      final tok = await api.beginVoice(); // ledger first
      active = true;
      final vh = await api.vaultAuth?.call() ?? const {};
      _ch = WebSocketChannel.connect(Uri.parse('${Env.wsBase}/v1/voice'));
      _ch!.sink.add(jsonEncode({'token': tok, 'lang': lang, if (vh.isNotEmpty) 'vault_id': vh['X-Vault-Id'], if (vh.isNotEmpty) 'vault_key': vh['X-Vault-Key']}));
      _w = _ch!.stream.listen((m) {
        if (m is! String) return;
        final d = jsonDecode(m) as Map<String, dynamic>;
        switch (d['type']) {
          case 'partial':
            if ('${d['text']}'.trim().isNotEmpty) _gotSpeech = true;
            onPartial('${d['text']}');
          case 'final':
            {
              final t = '${d['text']}'.trim();
              if (t.isNotEmpty) _gotSpeech = true;
              if (!(_finalWait?.isCompleted ?? true)) _finalWait?.complete();
              onFinal(t);
              stop();
            }
          case 'error':
            {
              if (!(_finalWait?.isCompleted ?? true)) _finalWait?.complete();
              onError('${d['code']}');
              stop();
            }
        }
      }, onError: (_) { onError('offline'); stop(); }, onDone: () {
        if (!(_finalWait?.isCompleted ?? true)) _finalWait?.complete();
      });
      final s = await _rec.startStream(const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 24000, numChannels: 1));
      _a = s.listen((b) {
        _sentBytes += b.length;
        _ch?.sink.add(b);
        onLevel?.call(micRms(b));
      });
    } on CloudDisabled {
      onError('cloud_off');
    } catch (_) {
      onError('offline');
      await stop();
    }
  }

  /// Stops capture and gives the gateway a bounded window to deliver the
  /// last final transcript before closing (the old fixed 2 s close raced
  /// slow finals and truncated them).
  Future<void> stop() async {
    if (!active) return;
    active = false;
    await _a?.cancel();
    var short = false;
    try {
      await _rec.stop();
      short = _sentBytes < kMinVoiceBytes && !_gotSpeech;
      _ch?.sink.add(jsonEncode({'type': 'end'}));
    } catch (_) {}
    if (short) {
      // Nothing audible was captured: close promptly; the gateway answers
      // too_short and the caller words it. No transcript is invented.
      await _close();
      return;
    }
    try {
      await _finalWait?.future.timeout(const Duration(seconds: 3));
    } catch (_) {}
    await _close();
  }

  Future<void> _close() async {
    await _w?.cancel();
    try {
      await _ch?.sink.close();
    } catch (_) {}
    _ch = null;
  }
}
