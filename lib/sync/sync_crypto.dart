import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';

String hex(List<int> b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
List<int> unhex(String s) => [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)];

/// 160-bit random sync secret shown once as 8 groups of 4 base32 characters. High entropy, so no weak-passphrase problem.
String generateSecret() {
  final r = Random.secure();
  const a = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  var bits = 0, val = 0;
  final out = StringBuffer();
  for (var i = 0; i < 20; i++) {
    val = (val << 8) | r.nextInt(256);
    bits += 8;
    while (bits >= 5) { out.write(a[(val >> (bits - 5)) & 31]); bits -= 5; }
    val &= (1 << bits) - 1;
  }
  final s = out.toString();
  return [for (var i = 0; i < s.length; i += 4) s.substring(i, i + 4)].join('-');
}

/// Argon2id (OWASP minimum: 19 MiB, 2 passes, 1 lane) then HKDF-SHA256 into four independent keys. Runs in an isolate.
Future<Map<String, String>> deriveSync(String secret) async {
  final norm = secret.toUpperCase().replaceAll(RegExp('[^A-Z2-7]'), '');
  final salt = (await Sha256().hash(utf8.encode('milo-sync-v1'))).bytes;
  final root = await Argon2id(memory: 19456, parallelism: 1, iterations: 2, hashLength: 32).deriveKeyFromPassword(password: norm, nonce: salt);
  final h = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
  Future<String> sub(String info) async => hex(await (await h.deriveKey(secretKey: root, nonce: const [], info: utf8.encode(info))).extractBytes());
  return {'vault': (await sub('vault-id')).substring(0, 32), 'auth': await sub('auth'), 'enc': await sub('enc'), 'rid': await sub('record-id')};
}

class SyncKeys {
  SyncKeys(Map<String, String> m) : vaultId = m['vault']!, authKey = m['auth']!, _enc = unhex(m['enc']!), _rid = unhex(m['rid']!);
  final String vaultId, authKey;
  final List<int> _enc, _rid;
  static Future<SyncKeys> derive(String secret) async => SyncKeys(await compute(deriveSync, secret));
  final _aes = AesGcm.with256bits();

  /// Opaque record id: the server cannot learn table names or row ids.
  Future<String> recordId(String tbl, String pk) async => hex((await Hmac.sha256().calculateMac(utf8.encode('$tbl:$pk'), secretKey: SecretKey(_rid))).bytes);

  Future<Map<String, String>> seal(String rid, Map<String, dynamic> payload) async {
    final nonce = _aes.newNonce();
    final box = await _aes.encrypt(utf8.encode(jsonEncode(payload)), secretKey: SecretKey(_enc), nonce: nonce, aad: utf8.encode('$vaultId$rid'));
    return {'nonce': hex(nonce), 'ciphertext_b64': base64Encode([...box.cipherText, ...box.mac.bytes])};
  }

  Future<Map<String, dynamic>> open(String rid, String nonceHex, String ctB64) async {
    final ct = base64Decode(ctB64);
    final box = SecretBox(ct.sublist(0, ct.length - 16), nonce: unhex(nonceHex), mac: Mac(ct.sublist(ct.length - 16)));
    return jsonDecode(utf8.decode(await _aes.decrypt(box, secretKey: SecretKey(_enc), aad: utf8.encode('$vaultId$rid')))) as Map<String, dynamic>;
  }
}
