import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/data/secure_store.dart';
import 'package:milo/net/api.dart';
import 'package:milo/ui/learn_screen.dart';
import 'package:milo/ui/trusted_screen.dart';

import 'helpers/fake_db.dart';
import 'helpers/harness.dart';

ProviderContainer tileContainer(FakeDb db, FakeApi api) => ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      storeProvider.overrideWithValue(SecureStore()),
      directorProvider.overrideWith((_) => Director()..quiet = true),
      apiProvider.overrideWithValue(api),
      connectionCheckProvider.overrideWith((_) => Future.value(
          const ConnStatus(apiBase: 'http://test', ok: true, provider: 'mock', brainMode: 'json', budgetOk: true, words: 'Connected.'))),
    ]);

void main() {
  test('tile art round-trips locally and dies with its tile', () async {
    final db = FakeDb();
    final id = await db.addTile('⭐', 'Grandma', art: Uint8List.fromList([1, 2, 3]));
    expect((await db.tiles()).single['label'], 'Grandma');
    expect(await db.tileArt(id), [1, 2, 3]);
    expect(db.settings.keys.where((k) => k.startsWith('local.tileart.')), hasLength(1)); // local-only: never synced
    await db.deleteTile(id);
    expect(await db.tileArt(id), isNull);
    expect((await db.tiles()), isEmpty);
  });

  testWidgets('grown-up draws, reviews, then saves a picture tile', (t) async {
    final db = FakeDb(), api = FakeApi(db, SecureStore());
    final c = tileContainer(db, api);
    await pumpScreen(t, const WordsEditor(), container: c);
    expect(find.byType(TextField), findsNWidgets(2)); // tripwire: label lookup below assumes exactly two fields
    await t.enterText(find.byKey(const Key('tileLabel')), 'Grandma');
    expect(t.widget<TextField>(find.byKey(const Key('tileLabel'))).controller?.text, 'Grandma'); // input landed in the label field
    await t.tap(find.text('Draw a picture (AI)'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Type the word first.'), findsNothing, reason: 'draw ran with an empty label');
    expect(find.text('Milo could not draw that. The word still saves.'), findsNothing, reason: 'generateImage threw');
    expect(find.text('AI-drawn. Look at it before saving — you decide.'), findsOneWidget);
    await t.tap(find.byIcon(Icons.add));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Grandma'), findsWidgets);
    expect(db.tileRows.single['label'], 'Grandma');
    expect(db.settings.keys.where((k) => k.startsWith('local.tileart.')), hasLength(1));
    expect(t.takeException(), isNull);
    c.dispose(); // in-body: teardowns run after the timer invariant check
  });

  testWidgets('word builder hands its word to Understand for a real explanation', (t) async {
    final db = FakeDb(), api = FakeApi(db, SecureStore());
    final c = tileContainer(db, api);
    await pumpScreen(t, const WordBuilder(), container: c);
    await t.tap(find.text('What does “tree” mean?'));
    await t.pump();
    expect(c.read(lookupWordProvider), 'tree'); // UnderstandScreen picks this up and explains it
    expect(t.takeException(), isNull);
    c.dispose(); // in-body: teardowns run after the timer invariant check
  });
}
