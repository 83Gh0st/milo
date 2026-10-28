import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/data/secure_store.dart';
import 'package:milo/net/api.dart';

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
      await t.pumpWidget(MaterialApp(home: Builder(builder: (c) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(s)), child: child))));
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
  Future<Map<String, dynamic>?> providerKeyStatus(String vid) async => null;
  @override
  Future<bool> healthy() async => true; // instant: LadderNotifier.refresh awaits this on every pump
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
    connectionCheckProvider.overrideWithValue(AsyncValue.data(conn ??
        const ConnStatus(apiBase: 'http://test', ok: true, provider: 'mock', brainMode: 'json', budgetOk: true, words: 'Connected.'))),
  ];
}

/// Pumps [screen] at [size]/[scale] with the standard overrides and mocked
/// connectivity. Uses bounded pumps: LadderNotifier's 90 s timer would hang
/// pumpAndSettle under fake async.
Future<void> pumpScreen(WidgetTester t, Widget screen, {Size size = const Size(360, 640), double scale = 1.0, EdgeInsets insets = EdgeInsets.zero, Director? d, ProviderContainer? container, void Function()? check}) async {
  mockConnectivity(t);
  t.view.physicalSize = Size(size.width * 3, size.height * 3);
  t.view.devicePixelRatio = 3.0;
  final scope = container == null
      ? ProviderScope(overrides: screenOverrides(d ?? Director()), child: MaterialApp(home: Builder(builder: (c) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale), viewInsets: insets), child: screen))))
      : UncontrolledProviderScope(container: container, child: MaterialApp(home: Builder(builder: (c) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(scale), viewInsets: insets), child: screen))));
  await t.pumpWidget(scope);
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 100));
  check?.call();
  expect(t.takeException(), isNull);
  t.view.resetPhysicalSize();
  t.view.resetDevicePixelRatio();
}
