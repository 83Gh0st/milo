import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/core/ai_provider.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/data/secure_store.dart';

import 'helpers/fake_db.dart';
import 'helpers/harness.dart';

void main() {
  group('ai choice', () {
    test('defaults to Milo hosted', () async {
      expect(await aiChoice(FakeDb()), AiChoice.miloHosted);
    });

    test('round-trips through the family flag the router reads',
        () async {
      final db = FakeDb();
      await setAiChoice(db, AiChoice.family);
      expect(await db.get('ai.family_key'), 'family');
      expect(await aiChoice(db), AiChoice.family);
      await setAiChoice(db, AiChoice.miloHosted);
      expect(await db.get('ai.family_key'), '');
      expect(await aiChoice(db), AiChoice.miloHosted);
    });

    test('choice words name both options honestly', () {
      expect(aiChoiceWords(AiChoice.miloHosted), contains('Milo hosted'));
      expect(aiChoiceWords(AiChoice.family), contains('Family AI'));
    });

    test('routing: family attaches vault auth, hosted sends none',
        () async {
      final db = FakeDb();
      final api = FakeApi(db, SecureStore());
      final sync = FakeSync(db, api, SecureStore(), on: true);
      final c = ProviderContainer(overrides: [
        dbProvider.overrideWithValue(db),
        storeProvider.overrideWithValue(SecureStore()),
        syncProvider.overrideWithValue(sync),
      ]);
      addTearDown(c.dispose);
      // The real apiProvider wiring (not a copy): vaultAuth is set by the
      // provider itself from the stored choice + the sync vault.
      final real = c.read(apiProvider);
      await setAiChoice(db, AiChoice.family);
      final fam = await real.vaultAuth!();
      expect(fam.keys, containsAll(['X-Vault-Id', 'X-Vault-Key']));
      await setAiChoice(db, AiChoice.miloHosted);
      expect(await real.vaultAuth!(), isEmpty);
      // Family choice without the sync vault: no identity, no headers.
      sync.on = false;
      await setAiChoice(db, AiChoice.family);
      expect(await real.vaultAuth!(), isEmpty);
    });
  });
}
