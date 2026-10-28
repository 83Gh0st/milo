import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/contracts/events.dart';
import 'package:milo/core/payload.dart';
import 'package:milo/data/secure_store.dart';
import 'package:milo/net/api.dart';
import 'package:milo/sync/sync_service.dart';

import 'fake_db.dart';

/// Phase 0 layout harness (the Phase 1 matrix in brief §4 builds on this).
const kHarnessSizes = {'small': Size(360, 640), 'standard': Size(393, 852), 'large': Size(412, 915)};

/// Loads bundled Lexend so widget/golden text renders as glyphs, not boxes.
Future<void> loadLexend() async {
  final loader = FontLoader('Lexend')..addFont(rootBundle.load('assets/fonts/Lexend-Regular.ttf'));
  await loader.load();
}

/// Pumps [child] (already wrapped in any providers it needs) inside a plain
/// MaterialApp at every harness size and text scale, then runs [check].
/// Surfaces reset after each case. Fails on any render overflow.
Future<void> pumpAtSizes(WidgetTester t, Widget child, {List<double> scales = const [1.0, 2.0], void Function()? check}) async {
  for (final e in kHarnessSizes.entries) {
    for (final s in scales) {
      t.view.physicalSize = Size(e.value.width * 3, e.value.height * 3);
      t.view.devicePixelRatio = 3.0;
      await t.pumpWidget(MaterialApp(home: Builder(builder: (c) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(s)), child: Scaffold(body: child)))));
      await t.pumpAndSettle();
      check?.call();
      expect(t.takeException(), isNull, reason: '${e.key} @${s}x');
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    }
  }
}

/// Phase 1 overlap guard: two on-screen regions must not intersect.
void expectNoOverlap(WidgetTester t, Finder a, Finder b) {
  expect(t.getRect(a).overlaps(t.getRect(b)), isFalse);
}

/// Full device matrix from the brief (logical dp).
const kMatrixSizes = {
  'small': Size(360, 640),
  'standard': Size(393, 852),
  'large': Size(412, 915),
  'fold': Size(673, 841),
  'tabletSmall': Size(600, 960),
  'tablet': Size(800, 1280),
  'landscape': Size(915, 412),
  'landscapeWide': Size(1280, 800),
};

/// Mocks the connectivity_plus channels so LadderNotifier works in tests.
void mockConnectivity(WidgetTester t) {
  const method = MethodChannel('dev.fluttercommunity.plus/connectivity');
  t.binding.defaultBinaryMessenger.setMockMethodCallHandler(method, (call) async {
    if (call.method == 'check') return ['wifi'];
    return null;
  });
  t.binding.defaultBinaryMessenger.setMockMessageHandler('dev.fluttercommunity.plus/connectivity_status', (data) async {
    const codec = StandardMethodCodec();
    final call = codec.decodeMethodCall(data);
    if (call.method == 'listen' || call.method == 'cancel') return codec.encodeSuccessEnvelope(null);
    return codec.encodeErrorEnvelope(code: 'error', message: 'unexpected');
  });
}

/// MiloApi with every network call stubbed: vault key status is always "none".
/// Screens under test never touch the network.
class FakeApi extends MiloApi {
  FakeApi(super.db, super.store);
  @override
  Future<Map<String, dynamic>?> providerKeyStatus(String vid, String key) async => null;
  @override
  Future<bool> healthy() async => true; // instant: LadderNotifier.refresh awaits this on every pump

  // ---- Phase 3 AI connections fake: a tiny in-memory vault ----
  final savedConns = <Map<String, dynamic>>[];
  Map<String, List<Map<String, String>>> savedRoutes = {};
  bool failProbe = false;

  @override
  Future<Map<String, dynamic>> listConnections(String vid, String key) async =>
      {'connections': savedConns, 'routes': savedRoutes};

  @override
  Future<Map<String, dynamic>> saveConnection(String vid, String key, String provider,
      {String apiKey = '', String baseUrl = '', String model = '', bool ack = false}) async {
    if (apiKey.isNotEmpty && apiKey.length < 8) throw ApiError('http_422', {'error': 'key_too_short'});
    if (apiKey.isEmpty && savedConns.every((c) => c['provider'] != provider) && provider != 'custom') {
      throw ApiError('http_422', {'error': 'key_required'});
    }
    if (!ack && provider != 'custom' && savedConns.every((c) => c['provider'] != provider)) {
      throw ApiError('http_409', {'error': 'policy_ack_required',
        'policy': {'trains_on_data': 'unknown', 'retention': 'terms not reviewed', 'needs_ack': true, 'note': 'Fake policy for tests.'}});
    }
    String? keep;
    for (final c in savedConns) {
      if (c['provider'] == provider) keep = c['hint'] as String;
    }
    savedConns.removeWhere((c) => c['provider'] == provider);
    final hint = apiKey.isEmpty ? (keep ?? '…0000') : '…${apiKey.substring(apiKey.length - 4)}';
    savedConns.add({'provider': provider, 'base_url': baseUrl, 'hint': hint, 'default_model': model.isEmpty ? 'fake-model' : model,
      'policy': {'trains_on_data': 'unknown', 'retention': 'terms not reviewed', 'needs_ack': provider != 'custom', 'note': 'Fake policy for tests.'}});
    return {'provider': provider, 'hint': hint, 'model': model, 'caps': {}, 'policy': {}};
  }

  @override
  Future<Map<String, dynamic>> testConnection(String vid, String key, String provider, {String model = ''}) async =>
      failProbe ? {'ok': false, 'checks': {'chat': 'fail:unreachable'}} :
          {'ok': true, 'checks': {'chat': 'pass', 'json_schema': 'pass', 'vision': 'pass'}};

  @override
  Future<List<String>> connectionModels(String vid, String key, String provider) async => ['fake-model-a', 'fake-model-b'];

  @override
  Future<Map<String, dynamic>> putRoutes(String vid, String key, Map<String, List<Map<String, String>>> routes) async {
    if (savedConns.isEmpty) throw ApiError('http_409', {'error': 'no_connections'});
    savedRoutes = routes;
    return {'routes': routes};
  }

  @override
  Future<void> deleteConnection(String vid, String key, String provider) async {
    savedConns.removeWhere((c) => c['provider'] == provider);
  }

  // ---- Phase 4 neural voice fake ----
  int speakCalls = 0;
  bool failSpeak = false;
  String speakEngine = 'fake-neural';
  Duration speakDelay = const Duration(milliseconds: 5);
  // ---- Phase 5 agent fake: one canned explanation turn ----
  bool blindError = false; // when true, the "model" cannot see pictures
  @override
  Stream<BrainEvent> understand(Map<String, dynamic> body) async* {
    await _ledg('/v1/understand', 'understand', summarizeBody(body));
    if (blindError) {
      yield const BrainEvent('error', {'code': 'unsupported_capability'});
      return;
    }
    yield const BrainEvent('say', {'text': 'Fake explanation.'});
    yield const BrainEvent('done', {'followup': 'none'});
  }

  @override
  Future<SpokenSentence> speakOnline(
      {required String text, required String lang, required String profile, double pace = 1, Map<String, String> style = const {}, String sentenceId = '', CancelToken? cancelToken}) async {
    speakCalls++;
    await _ledg('/v1/speak', 'voice', 'one Milo sentence to speak aloud (${text.length} characters)');
    await Future.delayed(speakDelay);
    if (failSpeak) throw ApiError('offline');
    return SpokenSentence(speakEngine, [0.0, 0.5, 1.0, 0.5, 0.0], Uint8List(4800), 100, sentenceId);
  }

  // ---- Plan 7.10 ledger fake: every fake cloud call writes one metadata-only
  // entry first, mirroring MiloApi._ledger (gates off: fakes never throw
  // CloudDisabled, so existing tests keep their meaning).
  Future<void> _ledg(String endpoint, String kind, String summary) =>
      db.ledger(endpoint, kind, summary, summary.length, false, false);
  bool cutStream = false; // when true, brainTurn yields one say then a transport error
  @override
  Stream<BrainEvent> brainTurn(Map<String, dynamic> body) async* {
    await _ledg('/v1/brain/turn', 'brain', summarizeBody(body));
    yield const BrainEvent('say', {'text': 'Fake partial.'});
    if (cutStream) {
      yield const BrainEvent('error', {'code': 'timeout'});
      return;
    }
    yield const BrainEvent('done', {'followup': 'none'});
  }

  @override
  Future<List<Map<String, String>>> plan(String goal, String presentation, String lang) async {
    await _ledg('/v1/plan', 'plan', 'your task goal');
    return [{'emoji': '✅', 'text': 'Fake step'}];
  }

  @override
  Future<List<String>> compose(List<String> strip, String presentation, String lang) async {
    await _ledg('/v1/compose', 'compose', 'the words you picked');
    return ['Fake wording'];
  }

  @override
  Future<Uint8List> visual(String concept) async {
    await _ledg('/v1/visual', 'picture', 'one picture word');
    return Uint8List(8);
  }
}

/// Standard app-graph overrides for pumping real screens. The director is the
/// test's own instance; db is in-memory; the connection check is canned.
List<Override> screenOverrides(Director d, {ConnStatus? conn}) {
  final db = FakeDb();
  return [
    dbProvider.overrideWithValue(db),
    storeProvider.overrideWithValue(SecureStore()),
    directorProvider.overrideWith((_) => d),
    apiProvider.overrideWithValue(FakeApi(db, SecureStore())),
    connectionCheckProvider.overrideWith((_) => Future.value(conn ??
        const ConnStatus(apiBase: 'http://test', ok: true, provider: 'mock', brainMode: 'json', budgetOk: true, words: 'Connected.'))),
  ];
}

/// SyncService with a canned vault: [on] controls [enabled], and the vault
/// headers are fixed test values. No platform storage, no network.
class FakeSync extends SyncService {
  FakeSync(super.db, super.api, super.store, {this.on = true});
  bool on;
  @override
  Future<bool> get enabled async => on;
  @override
  Future<Map<String, String>?> vaultHeaders() async =>
      on ? {'X-Vault-Id': 'ab' * 16, 'X-Vault-Key': 'cd' * 32} : null;
}

/// Pumps [screen] at [size]/[scale] with the standard overrides and mocked
/// connectivity. Uses bounded pumps: LadderNotifier's 90 s timer would hang
/// pumpAndSettle under fake async.
Future<void> pumpScreen(WidgetTester t, Widget screen, {Size size = const Size(360, 640), double scale = 1.0, EdgeInsets insets = EdgeInsets.zero, Director? d, ProviderContainer? container, void Function()? check}) async {
  mockConnectivity(t);
  t.view.physicalSize = Size(size.width * 3, size.height * 3);
  t.view.devicePixelRatio = 3.0;
  // Scaffold mirrors production (MiloScreen always wraps screens): chips,
  // fields, checkboxes and snackbars need a Material ancestor.
  final scope = container == null
      ? ProviderScope(overrides: screenOverrides(d ?? Director()), child: MaterialApp(home: Builder(builder: (c) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale), viewInsets: insets), child: Scaffold(body: screen)))))
      : UncontrolledProviderScope(container: container, child: MaterialApp(home: Builder(builder: (c) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale), viewInsets: insets), child: Scaffold(body: screen)))));
  await t.pumpWidget(scope);
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 100));
  check?.call();
  // DIAGNOSTIC-ROUND (revert after): let layout errors escape so CI prints
  // their full rendering chains instead of one-line summaries.
  // expect(t.takeException(), isNull);
  t.view.resetPhysicalSize();
  t.view.resetDevicePixelRatio();
}
