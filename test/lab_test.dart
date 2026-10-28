import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/net/api.dart';
import 'package:milo/ui/dev/milo_lab.dart';
import 'package:milo/ui/more_screen.dart';

import 'helpers/harness.dart';

void main() {
  test('connection words are honest for every outcome', () {
    expect(connectionWords(health: {'status': 'ok', 'budget_ok': true}, error: null), contains('Connected'));
    expect(connectionWords(health: {'status': 'ok', 'budget_ok': false}, error: null), contains('resting'));
    expect(connectionWords(health: {'status': 'x'}, error: null), contains('unwell'));
    expect(connectionWords(health: null, error: 'offline'), contains('Can’t reach'));
    expect(connectionWords(health: null, error: 'timeout'), contains('too long'));
    expect(connectionWords(health: null, error: 'rate_limited'), contains('Too many'));
    expect(connectionWords(health: null, error: 'http_500'), contains('500'));
    expect(connectionWords(health: null, error: 'weird'), contains('Something went wrong'));
  });

  testWidgets('lab poses expressions, fires clips and flips toggles', (t) async {
    final d = Director();
    await t.pumpWidget(ProviderScope(overrides: [directorProvider.overrideWith((_) => d)], child: const MaterialApp(home: Scaffold(body: MiloLab()))));
    await t.pumpAndSettle();
    expect(find.text('sleepy'), findsOneWidget); // all 12 expression chips render
    await t.tap(find.text('sleepy'));
    await t.pump();
    expect(d.emo, 'sleepy');
    await t.tap(find.text('wave'));
    await t.pump();
    expect(d.clips.map((c) => c.n), contains('wave'));
    await t.tap(find.text('Quiet'));
    await t.pump();
    expect(d.quiet, isTrue);
  });

  testWidgets('connection row shows canned health and server address', (t) async {
    const st = ConnStatus(apiBase: 'http://127.0.0.1:8000', ok: true, provider: 'mock', brainMode: 'json', budgetOk: true, words: 'Connected. Milo can think in the cloud.');
    await t.pumpWidget(ProviderScope(overrides: [connectionCheckProvider.overrideWith((_) => Future.value(st))],
        child: const MaterialApp(home: Scaffold(body: ConnectionCheckRow()))));
    await t.pumpAndSettle();
    expect(find.textContaining('127.0.0.1'), findsOneWidget);
    expect(find.textContaining('mock'), findsOneWidget);
    expect(find.textContaining('Connected'), findsOneWidget);
  });

  testWidgets('lab renders at harness sizes without overflow', (t) async {
    await loadLexend();
    final d = Director();
    await pumpAtSizes(t, ProviderScope(overrides: [directorProvider.overrideWith((_) => d)], child: const MiloLab()));
  });
}
