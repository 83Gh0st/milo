import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/data/secure_store.dart';
import 'package:milo/net/api.dart';
import 'package:milo/ui/learn_screen.dart';

import 'helpers/fake_db.dart';
import 'helpers/harness.dart';

ProviderContainer storyContainer(FakeDb db, FakeApi api, Director d) => ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      storeProvider.overrideWithValue(SecureStore()),
      directorProvider.overrideWith((_) => d),
      apiProvider.overrideWithValue(api),
      connectionCheckProvider.overrideWith((_) => Future.value(
          const ConnStatus(apiBase: 'http://test', ok: true, provider: 'mock', brainMode: 'json', budgetOk: true, words: 'Connected.'))),
    ]);

/// StoryTime sits one push deep so Finish can pop back here.
class _Launcher extends StatelessWidget {
  const _Launcher();
  @override
  Widget build(BuildContext context) => ElevatedButton(
      onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StoryTime())), child: const Text('go stories'));
}

Future<void> _open(WidgetTester t) async {
  await t.tap(find.text('go stories'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
}

Future<void> _tell(WidgetTester t) async {
  await t.tap(find.text('Tell me a story'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 100));
}

/// Story flows need a tall viewport: the reading column is legitimately long
/// (a ListView, scrolls in prod), and pumpScreen resets to 800x600 after
/// pumping. Tall + compact keeps every button built and tappable.
Future<void> pumpStory(WidgetTester t, Widget screen, ProviderContainer c) async {
  await pumpScreen(t, screen, size: const Size(360, 1000), container: c);
  t.view.physicalSize = const Size(360 * 3, 1000 * 3);
  t.view.devicePixelRatio = 3.0;
  addTearDown(() { t.view.resetPhysicalSize(); t.view.resetDevicePixelRatio(); });
}

void main() {
  group('Story.parse (second validation gate)', () {
    test('accepts a good tale with attribution', () {
      final s = Story.parse({
        'title': 'Pip',
        'pages': [
          {'heading': 'One', 'text': 'Pip waddled out.'}
        ],
        'told_by': {'provider': 'modal', 'model': 'x'}
      });
      expect(s.title, 'Pip');
      expect(s.pages.single.text, 'Pip waddled out.');
      expect(s.toldBy['provider'], 'modal');
    });
    test('rejects wrong shapes instead of showing half a tale', () {
      for (final bad in [
        {'title': 'x'},
        {'pages': []},
        {'pages': 'nope'},
        {
          'pages': [
            {'heading': 'h', 'text': '   '}
          ]
        },
        {
          'pages': [
            {'heading': 'h'}
          ]
        },
        {
          'pages': [for (var i = 0; i < 10; i++) {'heading': 'h', 'text': 't'}]
        },
      ]) {
        expect(() => Story.parse(bad), throwsA(isA<ApiError>().having((e) => e.code, 'code', 'bad_story')), reason: '$bad');
      }
    });
    test('predates-attribution payloads still open', () {
      final s = Story.parse({
        'pages': [
          {'heading': '', 'text': 'Once.'}
        ]
      });
      expect(s.toldBy['provider'], '');
      expect(toldByLabel(s.toldBy), 'Milo');
    });
  });

  group('toldByLabel', () {
    test('names the teller without model ids', () {
      expect(toldByLabel(const {'provider': 'modal', 'model': 'x'}), 'Milo-hosted Spark');
      expect(toldByLabel(const {'provider': 'meta', 'model': 'muse-spark-1.3'}), 'Muse Spark');
      expect(toldByLabel(const {'provider': 'meta', 'model': 'muse-wonder-1.0'}), 'Muse Wonder');
      expect(toldByLabel(const {'provider': 'mock', 'model': 'f'}), 'Practice storyteller');
      expect(toldByLabel(const {'provider': 'openai', 'model': 'g'}), 'Your openai key');
    });
  });

  group('StoryTime screen', () {
    testWidgets('generates, pages, continues, asks, saves and finishes', (t) async {
      final db = FakeDb(), api = FakeApi(db, SecureStore());
      final c = storyContainer(db, api, Director()..quiet = true);
      await pumpStory(t, const _Launcher(), c);
      await _open(t);
      expect(find.text('What shall the story be about?'), findsOneWidget);
      await t.tap(find.text('Animals'));
      await t.pump();
      await _tell(t);
      expect(find.text('The Brave Little Boat'), findsOneWidget);
      expect(find.text('Fake page one.'), findsOneWidget);
      expect(find.text('Told by Practice storyteller'), findsOneWidget);
      expect(find.text('1/2'), findsOneWidget);
      expect(db.ledgerList.where((e) => e['endpoint'] == '/v1/story'), isNotEmpty); // ledger-before-send kept
      await t.tap(find.text('Next'));
      await t.pump();
      expect(find.text('2/2'), findsOneWidget);
      expect(find.text('Keep going'), findsOneWidget);
      await t.tap(find.text('Keep going'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('3/3'), findsOneWidget);
      expect(find.text('Then something new happened.'), findsOneWidget);
      await t.tap(find.text('Ask about it'));
      await t.pump();
      await t.enterText(find.byType(TextField).last, 'Who is it about?');
      await t.tap(find.text('Ask'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('Fake answer.'), findsOneWidget);
      await t.tap(find.text('Save'));
      await t.pump();
      expect(find.text('Saved ✓'), findsOneWidget);
      expect(db.settings['local.stories'], contains('The Brave Little Boat'));
      // Direct drag: the smart scrollers misfire here (the question field's own
      // Scrollable confuses scrollUntilVisible; ensureVisible no-ops), while a
      // drag clamps at max scroll and always reveals the end of the tale.
      await t.drag(find.byType(ListView), const Offset(0, -500));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      await t.tap(find.text('Finish'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));
      expect(find.text('go stories'), findsOneWidget); // popped back
      expect(db.progressRows, contains('read'));
      expect(t.takeException(), isNull);
      c.dispose(); // in-body: teardowns run after the timer invariant check
    });

    testWidgets('saved tales reopen and delete; new ask stays fresh-capable', (t) async {
      final db = FakeDb(), api = FakeApi(db, SecureStore());
      final c = storyContainer(db, api, Director()..quiet = true);
      await pumpStory(t, const _Launcher(), c);
      await _open(t);
      await _tell(t);
      await t.tap(find.text('Next'));
      await t.pump();
      await t.tap(find.text('Save'));
      await t.pump();
      await t.tap(find.text('New story'));
      await t.pump();
      expect(find.text('The Brave Little Boat'), findsOneWidget); // in the saved list
      api.fakeStoryTitle = 'A Second Tale';
      await _tell(t); // a new ask is a new tale, never the saved pages on repeat
      expect(find.text('A Second Tale'), findsOneWidget);
      expect(t.takeException(), isNull);
      c.dispose(); // in-body: teardowns run after the timer invariant check
    });

    testWidgets('no connection shows a plain message, not a repeated tale', (t) async {
      final db = FakeDb(), api = FakeApi(db, SecureStore())..failStory = true;
      final c = storyContainer(db, api, Director()..quiet = true);
      await pumpStory(t, const _Launcher(), c);
      await _open(t);
      await _tell(t);
      expect(find.text('Stories need the internet. Please try again when you are back online.'), findsOneWidget);
      expect(find.text('Fake page one.'), findsNothing);
      expect(t.takeException(), isNull);
      c.dispose(); // in-body: teardowns run after the timer invariant check
    });
  });
}
