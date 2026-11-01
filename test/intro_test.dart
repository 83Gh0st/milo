import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/data/secure_store.dart';
import 'package:milo/ui/intro.dart';

import 'helpers/fake_db.dart';
import 'helpers/harness.dart';

ProviderContainer introContainer() => ProviderContainer(overrides: [
      dbProvider.overrideWithValue(FakeDb()),
      storeProvider.overrideWithValue(SecureStore()),
      directorProvider.overrideWith((_) => Director()),
    ]);

Future<void> pumpIntro(WidgetTester t, ProviderContainer c, {bool disableAnimations = false}) async {
  mockConnectivity(t);
  await t.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
          home: MediaQuery(data: const MediaQueryData().copyWith(disableAnimations: disableAnimations), child: const MiloIntro()))));
  await t.pump();
}

void main() {
  testWidgets('veil shows the wordmark, then dismisses on its timer', (t) async {
    final c = introContainer();
    await pumpIntro(t, c);
    expect(find.text('milo'), findsOneWidget);
    expect(c.read(introDoneProvider), isFalse);
    await t.pump(const Duration(milliseconds: 1800)); // past the 1700 ms veil
    expect(c.read(introDoneProvider), isTrue);
    expect(t.takeException(), isNull);
    c.dispose();
  });

  testWidgets('tap skips the veil once the entrance has landed', (t) async {
    final c = introContainer();
    await pumpIntro(t, c);
    await t.pump(const Duration(milliseconds: 600)); // past the .3 skip gate
    await t.tap(find.byType(MiloIntro));
    await t.pump();
    expect(c.read(introDoneProvider), isTrue);
    expect(t.takeException(), isNull);
    c.dispose();
  });

  testWidgets('reduced motion gets a short static hold, no animation', (t) async {
    final c = introContainer();
    await pumpIntro(t, c, disableAnimations: true);
    expect(find.text('milo'), findsOneWidget); // the static brand lockup
    await t.pump(const Duration(milliseconds: 600)); // past the 500 ms hold
    expect(c.read(introDoneProvider), isTrue);
    expect(t.takeException(), isNull);
    c.dispose();
  });
}
