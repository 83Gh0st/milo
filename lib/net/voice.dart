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
  return n == 0 ? 0 : (math.sqrt(sum / n) * 4).clamp(0.0, 1.0);
}

/// Push-to-talk voice input: 24 kHz mono PCM16 -> gateway -> Muse Voice Transcribe. Audio is never stored on the phone.
class VoiceClient {
  VoiceClient(this.api);
  final MiloApi api;
  final _rec = AudioRecorder();
  WebSocketChannel? _ch;
  StreamSubscription? _a, _w;
  bool active = false;
  Future<bool> requestPermission() => _rec.hasPermission(); // shows the system prompt the first time

  Future<void> start({required void Function(String) onPartial, required void Function(String) onFinal, required void Function(String) onError, void Function(double)? onLevel, String lang = 'English'}) async {
    if (active) return;
    try {
      if (!await _rec.hasPermission()) { onError('mic_denied'); return; }
      final tok = await api.beginVoice(); // ledger first
      active = true;
      final vh = await api.vaultAuth?.call() ?? const {};
      _ch = WebSocketChannel.connect(Uri.parse('${Env.wsBase}/v1/voice'));
      _ch!.sink.add(jsonEncode({'token': tok, 'lang': lang, if (vh.isNotEmpty) 'vault_id': vh['X-Vault-Id'], if (vh.isNotEmpty) 'vault_key': vh['X-Vault-Key']}));
      _w = _ch!.stream.listen((m) {
        final d = jsonDecode(m as String) as Map<String, dynamic>;
        switch (d['type']) {
          case 'partial': onPartial('${d['text']}');
          case 'final': onFinal('${d['text']}'); stop();
          case 'error': onError('${d['code']}'); stop();
        }
      }, onError: (_) { onError('offline'); stop(); });
      final s = await _rec.startStream(const RecordConfig(encoder: AudioEncoder.pcm16bits, sampleRate: 24000, numChannels: 1));
      _a = s.listen((b) { _ch?.sink.add(b); onLevel?.call(micRms(b)); });
    } on CloudDisabled { onError('cloud_off'); } catch (_) { onError('offline'); await stop(); }
  }

  Future<void> stop() async {
    if (!active) return;
    active = false;
    await _a?.cancel();
    try { await _rec.stop(); _ch?.sink.add(jsonEncode({'type': 'end'})); } catch (_) {}
    Future.delayed(const Duration(seconds: 2), () { _w?.cancel(); _ch?.sink.close(); _ch = null; });
  }
}
