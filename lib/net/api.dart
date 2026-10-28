import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:dio/dio.dart';
import 'package:package_info_plus/package_info_plus.dart';
import '../config.dart';
import '../contracts/events.dart';
import '../core/payload.dart';
import '../data/db.dart';
import '../data/secure_store.dart';

class CloudDisabled implements Exception {}
class ApiError implements Exception { final String code; final Map<String, dynamic>? detail; ApiError(this.code, [this.detail]); @override String toString() => 'ApiError($code)'; }

/// User barge-in (or turn change) cancelled an in-flight request: drop
/// silently — no failure mapping, no fallback, no notice.
class VoiceCancelled implements Exception { const VoiceCancelled(); }

/// One synthesised sentence: sideband metadata + raw PCM16 mono 24 kHz.
class SpokenSentence {
  const SpokenSentence(this.engine, this.envelope, this.pcm, this.durationMs, this.sentenceId);
  final String engine;
  final List<double> envelope; // 30 Hz amplitude, 0..1, peak-normalised
  final Uint8List pcm;
  final int durationMs;
  final String sentenceId;
}

/// Every cloud call goes through [_ledger] FIRST: the entry is written by the same code that makes the request,
/// built from the exact body being sent. If it is not in the ledger, it was not sent.
class MiloApi {
  MiloApi(this.db, this.store);
  final MiloDb db;
  final SecureStore store;
  /// Vault headers for family-keyed (BYOK) inference, or empty for the
  /// deployer key. Wired by the app; the provider key itself is never here.
  Future<Map<String, String>> Function()? vaultAuth;
  final Dio _dio = Dio(BaseOptions(baseUrl: Env.apiBase, connectTimeout: const Duration(seconds: 8), sendTimeout: const Duration(seconds: 15), receiveTimeout: const Duration(seconds: 15)));
  String? _tok;
  DateTime _exp = DateTime(2000);
  Future<String>? _pending; // a refresh in flight: concurrent callers share it instead of stampeding /v1/session

  Future<String> token({bool force = false}) async {
    if (!force && _tok != null && DateTime.now().isBefore(_exp)) return _tok!;
    final p = _pending;
    if (!force && p != null) return p;
    final fut = _issue();
    if (!force) _pending = fut;
    try {
      return await fut;
    } finally {
      if (!force) _pending = null;
    }
  }

  Future<String> _issue() async {
    try {
      final info = await PackageInfo.fromPlatform();
      final r = await _dio.post('/v1/session', data: {'install_id': await store.installId(), 'app_version': info.version, 'platform': Platform.isIOS ? 'ios' : 'android'});
      _tok = r.data['token'] as String;
      _exp = DateTime.now().add(Duration(seconds: (r.data['expires_in'] as int) - 30));
      return _tok!;
    } catch (e) { throw _map(e); }
  }

  ApiError _map(Object e) {
    if (e is ApiError) return e;
    if (e is DioException) {
      final s = e.response?.statusCode;
      final raw = e.response?.data;
      final detail = raw is Map ? Map<String, dynamic>.from(raw) : null;
      if (s == 429) return ApiError('rate_limited', detail);
      if (s == 503) return ApiError(detail?['error'] == 'budget_exhausted' ? 'budget_exhausted' : 'http_503', detail); // daily spend guard vs provider outage: same status, different words
      if (s == 504) return ApiError('timeout', detail); // the model took too long: retryable, not a budget problem
      return s != null ? ApiError('http_$s', detail) : ApiError('offline');
    }
    return ApiError('error');
  }

  Future<void> _ledger(String endpoint, String kind, Map<String, dynamic> body, {String gate = 'cloud.enabled', String? summary}) async {
    if (!await db.flag(gate) || await db.flag('offline.forced')) throw CloudDisabled();
    await db.ledger(endpoint, kind, summary ?? summarizeBody(body), utf8.encode(jsonEncode(body)).length, body['name'] != null, false);
  }

  Future<Response<T>> _send<T>(String method, String path, {Object? body, ResponseType? rt, Map<String, String> extra = const {}, CancelToken? cancelToken}) async {
    final vault = await vaultAuth?.call() ?? const <String, String>{};
    for (var attempt = 0;; attempt++) {
      try {
        return await _dio.request<T>(path, data: body, options: Options(method: method, responseType: rt, headers: {'Authorization': 'Bearer ${await token(force: attempt > 0)}', ...vault, ...extra}), cancelToken: cancelToken);
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) throw const VoiceCancelled();
        if (e.response?.statusCode == 401 && attempt == 0) continue;
        throw _map(e);
      }
    }
  }

  Stream<BrainEvent> _sse(String path, String kind, Map<String, dynamic> body) async* {
    await _ledger(path, kind, body);
    try {
      final r = await _send<ResponseBody>('POST', path, body: body, rt: ResponseType.stream);
      var buf = '';
      await for (final chunk in r.data!.stream.cast<List<int>>().transform(utf8.decoder)) {
        buf += chunk;
        int i;
        while ((i = buf.indexOf('\n\n')) >= 0) {
          final blk = buf.substring(0, i);
          buf = buf.substring(i + 2);
          String? ev, data;
          for (final l in blk.split('\n')) { if (l.startsWith('event: ')) { ev = l.substring(7); } else if (l.startsWith('data: ')) { data = l.substring(6); } }
          if (ev != null && data != null) yield BrainEvent(ev, jsonDecode(data) as Map<String, dynamic>);
        }
      }
    } on ApiError { rethrow; } on DioException catch (e) { throw _map(e); } on SocketException { throw ApiError('offline'); }
  }

  Stream<BrainEvent> brainTurn(Map<String, dynamic> body) => _sse('/v1/brain/turn', 'brain', body);
  Stream<BrainEvent> understand(Map<String, dynamic> body) => _sse('/v1/understand', 'understand', body);

  Future<List<Map<String, String>>> plan(String goal, String presentation, String lang) async {
    final body = {'goal': goal, 'presentation': presentation, 'lang': kLangNames[lang] ?? 'English'};
    await _ledger('/v1/plan', 'plan', body);
    final r = await _send<Map<String, dynamic>>('POST', '/v1/plan', body: body);
    return [for (final s in r.data!['steps'] as List) {'emoji': '${s['emoji']}', 'text': '${s['text']}'}];
  }

  Future<List<String>> compose(List<String> strip, String presentation, String lang) async {
    final body = {'strip': strip, 'presentation': presentation, 'lang': kLangNames[lang] ?? 'English'};
    await _ledger('/v1/compose', 'compose', body);
    final r = await _send<Map<String, dynamic>>('POST', '/v1/compose', body: body);
    return [for (final o in r.data!['options'] as List) '$o'];
  }

  Future<Uint8List> visual(String concept) async {
    final body = {'concept': concept};
    await _ledger('/v1/visual', 'picture', body);
    final r = await _send<List<int>>('POST', '/v1/visual', body: body, rt: ResponseType.bytes);
    return Uint8List.fromList(r.data!);
  }

  Future<bool> healthy() async { try { final r = await _dio.get('/v1/health'); return r.data['status'] == 'ok' && r.data['budget_ok'] == true; } catch (_) { return false; } }

  /// Voice: the ledger entry is written here, before any audio leaves the phone.
  Future<String> beginVoice() async {
    if (!await db.flag('cloud.enabled') || await db.flag('offline.forced')) throw CloudDisabled();
    await db.ledger('/v1/voice', 'voice', 'your voice, streamed live for transcription (not kept)', 0, false, false);
    return token();
  }

  /// Neural voice: synthesises ONE sentence server-side. Ledger-before-send
  /// (like every cloud call); cancellable for barge-in. Returns the sideband
  /// + raw PCM16 mono 24 kHz.
  Future<SpokenSentence> speakOnline({required String text, required String lang, required String profile, double pace = 1, Map<String, String> style = const {}, String sentenceId = '', CancelToken? cancelToken}) async {
    final body = {'text': text, 'lang': lang, 'profile': profile, 'style': {'pace': pace, ...style}, 'sentence_id': sentenceId};
    await _ledger('/v1/speak', 'voice', body, summary: 'one Milo sentence to speak aloud (${text.length} characters)');
    final r = await _send<List<int>>('POST', '/v1/speak', body: body, rt: ResponseType.bytes, cancelToken: cancelToken);
    final bytes = r.data!;
    final nl = bytes.indexOf(10);
    if (nl <= 0) throw ApiError('error');
    final sb = jsonDecode(utf8.decode(bytes.sublist(0, nl))) as Map<String, dynamic>;
    return SpokenSentence('${sb['engine']}', [for (final v in (sb['envelope'] as List?) ?? []) (v as num).toDouble()],
        Uint8List.fromList(bytes.sublist(nl + 1)), (sb['duration_ms'] as num?)?.toInt() ?? 0, '${sb['sentence_id'] ?? ''}');
  }

  // ---- sync (opaque ciphertext only; separate permission from cloud AI) ----
  Map<String, String> _vh(String vid, String key) => {'X-Vault-Id': vid, 'X-Vault-Key': key};
  Future<void> syncCreate(String vid, String key) async { await _send('POST', '/v1/sync/vault', extra: _vh(vid, key)); }
  Future<Map<String, dynamic>> syncChanges(String vid, String key, int since) async =>
      (await _send<Map<String, dynamic>>('GET', '/v1/sync/changes?since=$since&limit=200', extra: _vh(vid, key))).data!;
  Future<Map<String, dynamic>> syncPush(String vid, String key, List<Map<String, dynamic>> recs) async {
    await db.ledger('/v1/sync/records', 'sync', '${recs.length} end-to-end encrypted records (the server cannot read them)', recs.fold<int>(0, (a, r) => a + (r['ciphertext_b64'] as String).length), false, false);
    return (await _send<Map<String, dynamic>>('POST', '/v1/sync/records', body: {'records': recs}, extra: _vh(vid, key))).data!;
  }
  Future<void> syncDelete(String vid, String key) async { await _send('DELETE', '/v1/sync/vault', extra: _vh(vid, key)); }

  // ---- family BYOK key management (trusted-adult flow; the key is sent once, never stored on this phone) ----
  Future<void> setProviderKey(String vid, String key, String provider, String apiKey) async {
    await _send('POST', '/v1/sync/provider-key', body: {'provider': provider, 'api_key': apiKey}, extra: _vh(vid, key));
    await db.ledger('/v1/sync/provider-key', 'sync', 'family AI key saved (the key itself is never written here)', 0, false, false);
  }
  Future<Map<String, dynamic>?> providerKeyStatus(String vid, String key) async {
    try {
      return (await _send<Map<String, dynamic>>('GET', '/v1/sync/provider-key', extra: _vh(vid, key))).data!;
    } on ApiError catch (e) {
      if (e.code == 'http_404') return null;
      rethrow;
    }
  }
  Future<void> deleteProviderKey(String vid, String key) async {
    await _send('DELETE', '/v1/sync/provider-key', extra: _vh(vid, key));
    await db.ledger('/v1/sync/provider-key', 'sync', 'family AI key removed', 0, false, false);
  }

  // ---- Phase 3 AI connections (multi-provider; vault-authenticated, keys never stored on this phone) ----
  Future<Map<String, dynamic>> listConnections(String vid, String key) async =>
      (await _send<Map<String, dynamic>>('GET', '/v1/connections', extra: _vh(vid, key))).data!;
  Future<Map<String, dynamic>> saveConnection(String vid, String key, String provider, {String apiKey = '', String baseUrl = '', String model = '', bool ack = false}) async {
    final r = await _send<Map<String, dynamic>>('POST', '/v1/connections/$provider',
        body: {if (apiKey.isNotEmpty) 'api_key': apiKey, if (baseUrl.isNotEmpty) 'base_url': baseUrl, if (model.isNotEmpty) 'default_model': model, 'ack_data_policy': ack}, extra: _vh(vid, key));
    await db.ledger('/v1/connections/$provider', 'sync', 'family AI key saved for $provider (the key itself is never written here)', 0, false, false);
    return r.data!;
  }
  Future<Map<String, dynamic>> testConnection(String vid, String key, String provider, {String model = ''}) async =>
      (await _send<Map<String, dynamic>>('POST', '/v1/connections/$provider/test', body: {'model': model}, extra: _vh(vid, key))).data!;
  Future<List<String>> connectionModels(String vid, String key, String provider) async =>
      [for (final m in (await _send<Map<String, dynamic>>('GET', '/v1/connections/$provider/models', extra: _vh(vid, key))).data!['models'] as List) '$m'];
  Future<Map<String, dynamic>> putRoutes(String vid, String key, Map<String, List<Map<String, String>>> routes) async =>
      (await _send<Map<String, dynamic>>('PUT', '/v1/connections/routes', body: {'routes': routes}, extra: _vh(vid, key))).data!;
  Future<void> deleteConnection(String vid, String key, String provider) async {
    await _send('DELETE', '/v1/connections/$provider', extra: _vh(vid, key));
    await db.ledger('/v1/connections/$provider', 'sync', 'family AI key removed for $provider', 0, false, false);
  }

  // ---- Phase 0 connection check (About row): which server, what health, plain words ----
  Future<Map<String, dynamic>> healthDetails() async {
    try {
      final r = await _dio.get('/v1/health');
      return Map<String, dynamic>.from(r.data as Map);
    } on DioException catch (e) { throw _map(e); } on SocketException { throw ApiError('offline'); }
  }

  /// One /v1/health check, never throwing: failures become honest words.
  /// Ungated on purpose (it reports raw reachability; the ladder banner covers gates).
  Future<ConnStatus> connectionCheck() async {
    try {
      final h = await healthDetails();
      return ConnStatus(apiBase: Env.apiBase, ok: h['status'] == 'ok' && h['budget_ok'] == true,
          provider: h['provider'] is String ? h['provider'] as String : null,
          brainMode: h['brain_mode'] is String ? h['brain_mode'] as String : null, budgetOk: h['budget_ok'] == true,
          words: connectionWords(health: h, error: null));
    } on ApiError catch (e) { return ConnStatus(apiBase: Env.apiBase, ok: false, words: connectionWords(health: null, error: e.code)); } catch (_) {
      return ConnStatus(apiBase: Env.apiBase, ok: false, words: connectionWords(health: null, error: 'error'));
    }
  }
}

/// Plain-words result of one /v1/health check. No secrets, no content.
class ConnStatus {
  final String apiBase, words;
  final bool ok;
  final String? provider, brainMode;
  final bool? budgetOk;
  const ConnStatus({required this.apiBase, required this.words, required this.ok, this.provider, this.brainMode, this.budgetOk});
}

/// Maps a health payload or an ApiError code to one honest sentence. Pure: unit-tested.
String connectionWords({required Map<String, dynamic>? health, required String? error}) {
  if (health != null) {
    if (health['status'] == 'ok' && health['budget_ok'] == true) return 'Connected. Milo can think in the cloud.';
    if (health['status'] == 'ok') return 'Connected, but the thinking cloud is resting (daily budget used). Everything on this phone still works.';
    return 'The server answered but looks unwell (status ${health['status']}). Try again in a bit.';
  }
  return switch (error) {
    'offline' => 'Can’t reach the server. Check the gateway is running and this phone can open the address above.',
    'timeout' => 'The server took too long to answer. Try again.',
    'rate_limited' => 'Too many checks at once. Wait a minute and try again.',
    'budget_exhausted' => 'The thinking cloud is resting (daily budget used). Everything on this phone still works.',
    final c? when c.startsWith('http_') => 'The server answered with an error (${c.substring(5)}). Try again later.',
    _ => 'Something went wrong checking the connection.',
  };
}
