import 'package:flutter_test/flutter_test.dart';
import 'package:milo/contracts/brain_contract.dart';
import 'package:milo/core/payload.dart';
import 'package:milo/core/pocket_brain.dart';
import 'package:milo/core/safety.dart';
import 'package:milo/sync/sync_crypto.dart';

void main() {
  test('validator drops unknown values, URLs, and caps lists', () {
    final t = validateTurn({
      'emotion': {'name': 'angry', 'intensity': 3}, 'gesture': 'backflip', 'say': ['Visit https://x.com now', 'a', 'b', 'c', 'd'],
      'ui': [{'action': 'offer_choices', 'choices': ['1', '2', '3', '4']}, {'action': 'delete_files'}, {'action': 'open_screen', 'screen': 'launch_missiles'}],
    });
    expect(t.emotion, 'calm'); expect(t.gesture, isNull); expect(t.say.length, 4); expect(t.say.first.contains('http'), false);
    expect(t.choices.length, 3); expect(t.intensity, 1.0); expect(t.openScreen, isNull);
  });
  test('crisis language is caught locally, in three languages, before any cloud call', () {
    for (final s in ['I want to die', 'someone keeps touching me', "I don't want to be here anymore", 'ആത്മഹത്യ', 'आत्महत्या']) { expect(Safety.isCrisis(s), isTrue, reason: s); }
    expect(Safety.isCrisis('I want to dye my hair'), isFalse);
    expect(validateTurn(pocketBrain('i want to die', 'playful')).risk, 'crisis');
  });
  test('the payload contains exactly the visible chips, and no name unless allowed', () {
    final b = buildBrainBody(text: 'hi', activity: 'chat', presentation: 'friendly', lang: 'en', support: {}, memories: const [], chips: const [ChipItem('document', 'You’re reading this now', 'text')]);
    expect((b['chips'] as List).single['label'], 'You’re reading this now');
    expect(b.containsKey('name'), isFalse);
    final none = buildBrainBody(text: 'hi', activity: 'chat', presentation: 'friendly', lang: 'en', support: {}, memories: const [], chips: const []);
    expect(none['chips'], isEmpty); // removing a chip removes it from the very next request
  });
  test('sync: key derivation is deterministic, encryption round-trips, and tampering is detected', () async {
    final secret = generateSecret();
    expect(RegExp(r'^([A-Z2-7]{4}-){7}[A-Z2-7]{4}$').hasMatch(secret), isTrue);
    final k1 = SyncKeys(await deriveSync(secret)), k2 = SyncKeys(await deriveSync(secret.toLowerCase()));
    expect(k1.vaultId, k2.vaultId); expect(k1.authKey, k2.authKey); expect(k1.vaultId.length, 32);
    final rid = await k1.recordId('memories', 'abc');
    expect(rid.length, 64);
    final sealed = await k1.seal(rid, {'t': 'memories', 'k': 'abc', 'row': {'value': 'pictures'}});
    expect((await k2.open(rid, sealed['nonce']!, sealed['ciphertext_b64']!))['row']['value'], 'pictures');
    await expectLater(k1.open('f' * 64, sealed['nonce']!, sealed['ciphertext_b64']!), throwsA(anything)); // record id is bound as AAD
    final other = SyncKeys(await deriveSync(generateSecret()));
    await expectLater(other.open(rid, sealed['nonce']!, sealed['ciphertext_b64']!), throwsA(anything)); // wrong key
  });
}
