import 'dart:math';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Keys live in Keychain / Keystore, never in the database or backups.
class SecureStore {
  final _s = const FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true), iOptions: IOSOptions(accessibility: KeychainAccessibility.first_unlock_this_device));
  static String _hex(int n) { final r = Random.secure(); return List.generate(n, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join(); }
  Future<String> _getOrMake(String k, int bytes) async { var v = await _s.read(key: k); if (v == null) { v = _hex(bytes); await _s.write(key: k, value: v); } return v; }
  Future<String> dbKey() => _getOrMake('milo.dbkey', 32); // random 256-bit SQLCipher key
  Future<String> installId() => _getOrMake('milo.install', 16); // random, not derived from the device
  Future<String?> read(String k) => _s.read(key: 'milo.$k');
  Future<void> write(String k, String v) => _s.write(key: 'milo.$k', value: v);
  Future<void> delete(String k) => _s.delete(key: 'milo.$k');
  Future<void> wipe() => _s.deleteAll();
}
