import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/data/secure_store.dart';
import 'package:milo/net/api.dart';
import 'package:milo/sys/share_in.dart';
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
ProviderContainer agentContainer(FakeDb db, FakeApi api, {String lookup = '', String shared = ''}) => ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      storeProvider.overrideWithValue(SecureStore()),
      directorProvider.overrideWith((_) => Director()),
      apiProvider.overrideWithValue(api),
      lookupWordProvider.overrideWith((_) => lookup),
      sharedTextProvider.overrideWith((_) => shared),
      connectionCheckProvider.overrideWith((_) => Future.value(const ConnStatus(apiBase: 'http://test', ok: true, provider: 'mock', brainMode: 'json', budgetOk: true, words: 'Connected.'))),
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
      await pumpScreen(t, const UnderstandScreen(), size: const Size(393, 852), container: c);
      // Never directly awaited: explain's caption-linger delay runs on the
      // fake clock, which only advances while pumping.
      unawaited(c.read(routerProvider).explain(c.read(directorProvider), 'x', imageB64: 'e30='));
      await settleAgent(t, 45);
      expect(find.byType(CloudUnreachableScreen), findsNothing);
      expect(c.read(ladderProvider), Ladder.offline);
      expect(t.takeException(), isNull);
      c.dispose(); // in-body: teardowns run after the timer invariant check
    });
  });

  group('check-in counts (§0.1, plan 7.11)', () {
    testWidgets('off by default; opt-in records one count, never the answer', (t) async {
      final db = FakeDb();
      final c = agentContainer(db, FakeApi(db, SecureStore()));
      await pumpScreen(t, const CheckInScreen(), size: const Size(393, 852), container: c);
      final mood = find.byIcon(Icons.sentiment_very_satisfied); // a mood face, not the header back button
      await t.tap(mood);
      await settleAgent(t);
      expect(db.progressRows, isEmpty); // default: nothing in the calm space is recorded
      await db.putFlag('checkin.counts', true);
      await t.tap(mood);
      await settleAgent(t);
      expect(db.progressRows, ['checkin']); // opt-in: counts only, answers never stored
      await settleAgent(t, 20); // drain fire-and-forget speak timers before teardown
      c.dispose(); // in-body: teardowns run after the timer invariant check
      expect(t.takeException(), isNull);
    });
  });

  group('switch scanning (P2)', () {
    ProviderContainer scanContainer(FakeDb db, FakeApi api, int ms) => ProviderContainer(overrides: [
          dbProvider.overrideWithValue(db),
          storeProvider.overrideWithValue(SecureStore()),
          directorProvider.overrideWith((_) => Director()
            ..scanMode = true
            ..scanMs = ms
            ..presenceOverride = Presence.hidden), // no dock: the grid owns the screen
          apiProvider.overrideWithValue(api),
          connectionCheckProvider.overrideWith((_) => Future.value(const ConnStatus(apiBase: 'http://test', ok: true, provider: 'mock', brainMode: 'json', budgetOk: true, words: 'Connected.'))),
        ]);
    testWidgets('any tap picks the highlighted tile', (t) async {
      final db = FakeDb();
      final c = scanContainer(db, FakeApi(db, SecureStore()), 60000);
      await pumpScreen(t, const ExpressScreen(), size: const Size(393, 852), container: c);
      await t.ensureVisible(find.text('I want', skipOffstage: false)); // top row: tappable even if the grid scrolled
      await t.pump();
      await t.tap(find.text('I want')); // highlight sits at tile 0, timer effectively frozen
      await settleAgent(t);
      expect(find.text('I want', skipOffstage: false), findsNWidgets(2)); // grid tile + strip bar
      expect(t.takeException(), isNull);
      c.dispose(); // in-body: teardowns run after the timer invariant check
    });
    testWidgets('highlight auto-advances on the interval', (t) async {
      final db = FakeDb();
      final c = scanContainer(db, FakeApi(db, SecureStore()), 300);
      await pumpScreen(t, const ExpressScreen(), size: const Size(393, 852), container: c);
      await t.pump(const Duration(milliseconds: 150)); // clock 200 -> 350: exactly one 300 ms tick
      await t.ensureVisible(find.text('I want', skipOffstage: false)); // top row: tappable even if the grid scrolled
      await t.pump();
      await t.tap(find.text('I want'));
      await settleAgent(t);
      expect(find.text('I need', skipOffstage: false), findsNWidgets(2)); // tile 1, not the tapped tile
      expect(t.takeException(), isNull);
      c.dispose(); // in-body: teardowns run after the timer invariant check
    });
  });

  group('trusted-adult report (P2)', () {
    testWidgets('two periods, counts only, check-ins gated by opt-in', (t) async {
      final db = FakeDb();
      db.progressRows.addAll(['read', 'read', 'step', 'checkin']);
      await db.putFlag('checkin.counts', true);
      final c = agentContainer(db, FakeApi(db, SecureStore()));
      await pumpScreen(t, const WeeklySummary(), size: const Size(393, 852), container: c);
      await settleAgent(t);
      expect(find.text('THIS WEEK'), findsOneWidget); // Section headers render upper-cased
      await t.scrollUntilVisible(find.text('ALL TIME SO FAR'), 300);
      await settleAgent(t);
      expect(find.text('ALL TIME SO FAR'), findsOneWidget);
      expect(find.text('Mood check-ins', skipOffstage: false), findsNWidgets(2)); // week + all-time
      expect(find.text('Things read', skipOffstage: false), findsNWidgets(2));
      expect(find.textContaining('A quiet week'), findsNothing);
      expect(t.takeException(), isNull);
      c.dispose(); // in-body: teardowns run after the timer invariant check
    });
    testWidgets('quiet week says so gently, no loss language', (t) async {
      final db = FakeDb();
      final c = agentContainer(db, FakeApi(db, SecureStore()));
      await pumpScreen(t, const WeeklySummary(), size: const Size(393, 852), container: c);
      await settleAgent(t);
      expect(find.textContaining('A quiet week'), findsOneWidget);
      expect(find.text('Mood check-ins'), findsNothing); // opt-in off
      expect(find.textContaining('streak'), findsNothing);
      expect(t.takeException(), isNull);
      c.dispose(); // in-body: teardowns run after the timer invariant check
    });
  });

  group('lookup_word handoff', () {
    testWidgets('prefills the Understand reader with the looked-up word', (t) async {
      final db = FakeDb();
      final c = agentContainer(db, FakeApi(db, SecureStore()), lookup: 'photosynthesis');
      await pumpScreen(t, const UnderstandScreen(), size: const Size(393, 852), container: c);
      await settleAgent(t, 30);
      await t.tap(find.text('Continue')); // reading -> style
      await settleAgent(t);
      await t.tap(find.text('Apply')); // style -> reader, words visible
      await settleAgent(t);
      expect(find.text('photosynthesis'), findsWidgets);
      expect(t.takeException(), isNull);
      c.dispose(); // in-body: teardowns run after the timer invariant check
    });
  });

  group('share-in (plan 7.13)', () {
    testWidgets('platform text lands in the provider', (t) async {
      final db = FakeDb();
      final c = agentContainer(db, FakeApi(db, SecureStore()));
      addTearDown(c.dispose);
      String? got;
      armShareIn((s) => got = s);
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.handlePlatformMessage(
          'milo/share', const StandardMethodCodec().encodeMethodCall(const MethodCall('sharedText', '  Shared words  ')), (_) {});
      expect(got, 'Shared words'); // trimmed, non-empty only
      expect(t.takeException(), isNull);
    });
    testWidgets('shared text prefills the Understand reader once', (t) async {
      final db = FakeDb();
      final c = agentContainer(db, FakeApi(db, SecureStore()), shared: 'Shared words');
      await pumpScreen(t, const UnderstandScreen(), size: const Size(393, 852), container: c);
      await settleAgent(t, 30);
      await t.tap(find.text('Continue')); // reading -> style
      await settleAgent(t);
      await t.tap(find.text('Apply')); // style -> reader, words visible
      await settleAgent(t);
      expect(find.textContaining('Shared words'), findsWidgets);
      expect(c.read(sharedTextProvider), isEmpty); // consumed
      expect(t.takeException(), isNull);
      c.dispose(); // in-body: teardowns run after the timer invariant check
    });
  });
}
