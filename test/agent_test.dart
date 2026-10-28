import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/data/secure_store.dart';
import 'package:milo/ui/calm_screens.dart';
import 'package:milo/ui/chat_screen.dart';
import 'package:milo/ui/express_screen.dart';
import 'package:milo/ui/failure_screens.dart';
import 'package:milo/ui/trusted_screen.dart';
import 'package:milo/ui/understand_screen.dart';

import 'helpers/fake_db.dart';
import 'helpers/harness.dart';

/// Widget tests for the Phase 5 safe multimodal agent: the steps checklist
/// (visible confirmation before anything is saved) and the lookup_word
/// cross-screen handoff into the Understand reader.
ProviderContainer agentContainer(FakeDb db, FakeApi api, {String lookup = ''}) => ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      storeProvider.overrideWithValue(SecureStore()),
      directorProvider.overrideWith((_) => Director()),
      apiProvider.overrideWithValue(api),
      lookupWordProvider.overrideWith((_) => lookup),
      connectionCheckProvider.overrideWithValue(const AsyncValue.data(
          ConnStatus(apiBase: 'http://test', ok: true, provider: 'mock', brainMode: 'json', budgetOk: true, words: 'Connected.'))),
    ]);

Future<void> settleAgent(WidgetTester t, [int n = 6]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('agent steps card', () {
    testWidgets('checks steps off and saves to Do on confirmation', (t) async {
      final db = FakeDb();
      final c = agentContainer(db, FakeApi(db, SecureStore()));
      addTearDown(c.dispose);
      await pumpScreen(t, const ChatScreen(), size: const Size(393, 852), container: c);
      c.read(chatProvider.notifier).addSteps(['Open the book', 'Read one page']);
      await settleAgent(t);
      expect(find.text('Open the book'), findsOneWidget);
      expect(find.text('Save to Do'), findsOneWidget);
      await t.tap(find.text('Open the book'));
      await t.pump();
      await t.tap(find.text('Save to Do'));
      await settleAgent(t);
      // The visible confirmation is what writes: nothing landed before the tap.
      expect(db.settings['local.tasks'], contains('Read one page'));
      expect(find.text('Saved'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('blind model honesty', () {
    testWidgets('an image turn on a blind model explains, not "unreachable"', (t) async {
      final db = FakeDb();
      final api = FakeApi(db, SecureStore())..blindError = true;
      final c = agentContainer(db, api);
      addTearDown(c.dispose);
      await pumpScreen(t, const UnderstandScreen(), size: const Size(393, 852), container: c);
      await c.read(routerProvider).explain(c.read(directorProvider), 'x', imageB64: 'e30=');
      await settleAgent(t, 30);
      expect(find.byType(CloudUnreachableScreen), findsNothing);
      expect(c.read(ladderProvider), Ladder.offline);
      expect(t.takeException(), isNull);
    });
  });

  group('check-in counts (§0.1, plan 7.11)', () {
    testWidgets('off by default; opt-in records one count, never the answer', (t) async {
      final db = FakeDb();
      final c = agentContainer(db, FakeApi(db, SecureStore()));
      addTearDown(c.dispose);
      await pumpScreen(t, const CheckInScreen(), size: const Size(393, 852), container: c);
      await t.tap(find.byType(IconButton).first);
      await settleAgent(t);
      expect(db.progressRows, isEmpty); // default: nothing in the calm space is recorded
      await db.putFlag('checkin.counts', true);
      await t.tap(find.byType(IconButton).first);
      await settleAgent(t);
      expect(db.progressRows, ['checkin']); // opt-in: counts only, answers never stored
      expect(t.takeException(), isNull);
    });
  });

  group('switch scanning (P2)', () {
    ProviderContainer scanContainer(FakeDb db, FakeApi api, int ms) => ProviderContainer(overrides: [
          dbProvider.overrideWithValue(db),
          storeProvider.overrideWithValue(SecureStore()),
          directorProvider.overrideWith((_) => Director()
            ..scanMode = true
            ..scanMs = ms),
          apiProvider.overrideWithValue(api),
          connectionCheckProvider.overrideWithValue(const AsyncValue.data(
              ConnStatus(apiBase: 'http://test', ok: true, provider: 'mock', brainMode: 'json', budgetOk: true, words: 'Connected.'))),
        ]);
    testWidgets('any tap picks the highlighted tile', (t) async {
      final db = FakeDb();
      final c = scanContainer(db, FakeApi(db, SecureStore()), 60000);
      addTearDown(c.dispose);
      await pumpScreen(t, const ExpressScreen(), size: const Size(393, 852), container: c);
      await t.tap(find.text('Food')); // highlight sits at tile 0, timer effectively frozen
      await settleAgent(t);
      expect(find.text('I want'), findsNWidgets(2)); // grid tile + strip bar
      expect(t.takeException(), isNull);
    });
    testWidgets('highlight auto-advances on the interval', (t) async {
      final db = FakeDb();
      final c = scanContainer(db, FakeApi(db, SecureStore()), 300);
      addTearDown(c.dispose);
      await pumpScreen(t, const ExpressScreen(), size: const Size(393, 852), container: c);
      await t.pump(const Duration(milliseconds: 150)); // clock 200 -> 350: exactly one 300 ms tick
      await t.tap(find.text('Food'));
      await settleAgent(t);
      expect(find.text('I need'), findsNWidgets(2)); // tile 1, not the tapped tile
      expect(t.takeException(), isNull);
    });
  });

  group('trusted-adult report (P2)', () {
    testWidgets('two periods, counts only, check-ins gated by opt-in', (t) async {
      final db = FakeDb();
      db.progressRows.addAll(['read', 'read', 'step', 'checkin']);
      await db.putFlag('checkin.counts', true);
      final c = agentContainer(db, FakeApi(db, SecureStore()));
      addTearDown(c.dispose);
      await pumpScreen(t, const WeeklySummary(), size: const Size(393, 852), container: c);
      await settleAgent(t);
      expect(find.text('This week'), findsOneWidget);
      await t.scrollUntilVisible(find.text('All time so far'), 300);
      await settleAgent(t);
      expect(find.text('All time so far'), findsOneWidget);
      expect(find.text('Mood check-ins', skipOffstage: false), findsNWidgets(2)); // week + all-time
      expect(find.text('Things read', skipOffstage: false), findsNWidgets(2));
      expect(find.textContaining('A quiet week'), findsNothing);
      expect(t.takeException(), isNull);
    });
    testWidgets('quiet week says so gently, no loss language', (t) async {
      final db = FakeDb();
      final c = agentContainer(db, FakeApi(db, SecureStore()));
      addTearDown(c.dispose);
      await pumpScreen(t, const WeeklySummary(), size: const Size(393, 852), container: c);
      await settleAgent(t);
      expect(find.textContaining('A quiet week'), findsOneWidget);
      expect(find.text('Mood check-ins'), findsNothing); // opt-in off
      expect(find.textContaining('streak'), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  group('lookup_word handoff', () {
    testWidgets('prefills the Understand reader with the looked-up word', (t) async {
      final db = FakeDb();
      final c = agentContainer(db, FakeApi(db, SecureStore()), lookup: 'photosynthesis');
      addTearDown(c.dispose);
      await pumpScreen(t, const UnderstandScreen(), size: const Size(393, 852), container: c);
      await settleAgent(t, 30);
      expect(find.text('photosynthesis'), findsWidgets);
      expect(t.takeException(), isNull);
    });
  });
}
