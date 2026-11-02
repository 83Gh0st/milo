import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/data/secure_store.dart';
import 'package:milo/net/api.dart';
import 'package:milo/ui/segment_overlay.dart';
import 'package:milo/ui/understand_screen.dart';

import 'helpers/fake_db.dart';
import 'helpers/harness.dart';

ProviderContainer segContainer(FakeDb db, FakeApi api) => ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      storeProvider.overrideWithValue(SecureStore()),
      directorProvider.overrideWith((_) => Director()..quiet = true),
      apiProvider.overrideWithValue(api),
      connectionCheckProvider.overrideWith((_) => Future.value(
          const ConnStatus(apiBase: 'http://test', ok: true, provider: 'mock', brainMode: 'json', budgetOk: true, words: 'Connected.'))),
    ]);

void main() {
  testWidgets('find outlines matches; tapping a box explains it', (t) async {
    final db = FakeDb(), api = FakeApi(db, SecureStore());
    String? explained;
    await pumpScreen(t, PhotoSegments(image: Uint8List(8), onExplain: (label) => explained = label),
        container: segContainer(db, api));
    await t.enterText(find.byType(TextField), 'heart');
    await t.tap(find.text('Find'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('heart'), findsWidgets); // both boxes carry the phrase
    expect(find.text('Tap an outlined box'), findsOneWidget);
    // Scoped to the overlay: find.text also matches the search field's own
    // EditableText ('heart'), which sorts first and would swallow the tap.
    await t.tap(find.descendant(of: find.byType(SegmentOverlay), matching: find.text('heart')).first);
    await t.pump();
    expect(find.text('Explain “heart”'), findsOneWidget);
    await t.tap(find.text('Explain “heart”'));
    await t.pump();
    expect(explained, 'heart');
    expect(db.ledgerList.where((e) => e['endpoint'] == '/v1/segment'), isNotEmpty);
    expect(t.takeException(), isNull);
  });

  testWidgets('short phrases never ask; offline msg keeps the photo', (t) async {
    final db = FakeDb(), api = FakeApi(db, SecureStore())..failSegment = true;
    await pumpScreen(t, PhotoSegments(image: Uint8List(8), onExplain: (_) {}), container: segContainer(db, api));
    await t.enterText(find.byType(TextField), 'x');
    await t.tap(find.text('Find'));
    await t.pump();
    expect(db.ledgerList.where((e) => e['endpoint'] == '/v1/segment'), isEmpty);
    await t.enterText(find.byType(TextField), 'heart');
    await t.tap(find.text('Find'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('Finding things needs the internet. Your photo is still here.'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
