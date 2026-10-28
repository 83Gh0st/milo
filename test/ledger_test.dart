import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/data/secure_store.dart';

import 'helpers/fake_db.dart';
import 'helpers/harness.dart';

/// Plan 7.10 (one ledger entry per cloud call) and 7.12 (a cut stream
/// finishes gracefully, never crashes, ladder says what happened).
void main() {
  test('100 mixed cloud calls write exactly 100 ledger entries', () async {
    final db = FakeDb();
    final api = FakeApi(db, SecureStore());
    for (var i = 0; i < 20; i++) {
      await api.brainTurn({'text': 'hello $i'}).drain();
      await api.understand({'content_text': 'read me $i'}).drain();
      await api.plan('goal $i', 'friendly', 'en');
      await api.compose(['I', 'want', 'water'], 'friendly', 'en');
      await api.visual('tree');
    }
    final rows = await db.ledgerRows(200);
    expect(rows.length, 100);
    final eps = rows.map((r) => r['endpoint']).toSet();
    expect(eps, {'/v1/brain/turn', '/v1/understand', '/v1/plan', '/v1/compose', '/v1/visual'});
    // Metadata only: no message text, no document text, no goal text leaks in.
    final blob = rows.map((r) => '${r['summary']}').join('|');
    expect(blob.contains('hello 3'), isFalse);
    expect(blob.contains('read me 3'), isFalse);
    expect(blob.contains('goal 3'), isFalse);
  });

  test('mid-stream cut: partial finishes, pocket explains, ladder rests', () async {
    final db = FakeDb();
    final api = FakeApi(db, SecureStore())..cutStream = true;
    final c = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      storeProvider.overrideWithValue(SecureStore()),
      directorProvider.overrideWith((_) => Director()),
      apiProvider.overrideWithValue(api),
    ]);
    addTearDown(c.dispose);
    await c.read(routerProvider).handle('Why is the ocean deep?', c.read(directorProvider));
    expect(c.read(ladderProvider), Ladder.resting); // timeout, not offline
    expect((await db.ledgerRows(10)).length, 1); // the attempt was still logged first
  });
}
