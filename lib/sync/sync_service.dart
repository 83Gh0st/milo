import 'dart:math';
import '../data/db.dart';
import '../data/secure_store.dart';
import '../net/api.dart';
import 'sync_crypto.dart';

/// Optional end-to-end encrypted sync (doc 8.5). Off by default; a separate permission from cloud AI.
class SyncService {
  SyncService(this.db, this.api, this.store);
  final MiloDb db;
  final MiloApi api;
  final SecureStore store;
  Future<void> Function()? onApplied;
  SyncKeys? _k;
  bool busy = false;

  Future<bool> get enabled => db.flag('local.sync');
  Future<SyncKeys?> _keys() async {
    if (_k != null) return _k;
    final s = await store.read('sync.secret');
    return s == null ? null : (_k = await SyncKeys.derive(s));
  }

  /// First device: returns the secret to show ONCE (the person must keep it; losing it means the cloud copy cannot be opened).
  Future<String> enable() async {
    final secret = generateSecret();
    final k = await SyncKeys.derive(secret);
    await api.syncCreate(k.vaultId, k.authKey);
    await store.write('sync.secret', secret);
    _k = k;
    await db.putFlag('local.sync', true);
    await db.logConsent('sync', 'enabled', 'user');
    await db.queueEverything();
    await syncNow();
    return secret;
  }

  /// Another device: the same secret opens the same vault.
  Future<void> join(String secret) async {
    final k = await SyncKeys.derive(secret);
    await api.syncChanges(k.vaultId, k.authKey, 0); // 401 if the secret is wrong
    await store.write('sync.secret', secret);
    _k = k;
    await db.putFlag('local.sync', true);
    await db.put('local.sync.cursor', '0');
    await db.logConsent('sync', 'joined', 'user');
    await db.queueEverything();
    await syncNow();
  }

  Future<void> syncNow() async {
    final k = await _keys();
    if (k == null || busy || !await enabled) return;
    busy = true;
    try { await _push(k); await _pull(k); } finally { busy = false; }
  }

  Future<void> _push(SyncKeys k) async {
    while (true) {
      final box = await db.outbox();
      if (box.isEmpty) return;
      final recs = <Map<String, dynamic>>[];
      final meta = <List<Object>>[];
      for (final o in box) {
        final t = o['tbl'] as String, pk = o['pk'] as String, ts = o['updated_at'] as int, del = o['deleted'] == 1;
        Map<String, dynamic> payload;
        if (del) { payload = {'t': t, 'k': pk, 'del': true}; } else {
          final row = await db.rowJson(t, pk);
          if (row == null) { await db.clearOutbox(t, pk, ts); continue; }
          payload = {'t': t, 'k': pk, 'row': row};
        }
        final rid = await k.recordId(t, pk);
        recs.add({'record_id': rid, 'updated_at': ts, 'deleted': del, ...await k.seal(rid, payload)});
        meta.add([t, pk, ts]);
      }
      if (recs.isEmpty) return;
      await api.syncPush(k.vaultId, k.authKey, recs); // conflicts mean the server holds a newer copy: it arrives in the pull
      for (final m in meta) { await db.clearOutbox(m[0] as String, m[1] as String, m[2] as int); }
    }
  }

  Future<void> _pull(SyncKeys k) async {
    var since = int.tryParse(await db.get('local.sync.cursor') ?? '0') ?? 0, applied = false;
    while (true) {
      final r = await api.syncChanges(k.vaultId, k.authKey, since);
      for (final rec in r['records'] as List) {
        since = max(since, rec['seq'] as int);
        try {
          final p = await k.open('${rec['record_id']}', '${rec['nonce']}', '${rec['ciphertext_b64']}');
          final t = '${p['t']}', pk = '${p['k']}';
          if (!kSync.containsKey(t) || (rec['updated_at'] as int) <= await db.localStamp(t, pk)) continue; // last write wins
          if (p['del'] == true) { await db.applyRemoteDelete(t, pk); } else { await db.applyRemote(t, pk, Map<String, dynamic>.from(p['row'] as Map)); }
          applied = true;
        } catch (_) { continue; } // undecryptable or malformed record: skip, never crash
      }
      await db.put('local.sync.cursor', '$since');
      if (r['more'] != true) break;
    }
    if (applied) await onApplied?.call();
  }

  /// Turn sync off and erase the cloud copy (right to erasure).
  Future<void> disable() async {
    final k = await _keys();
    if (k != null) { try { await api.syncDelete(k.vaultId, k.authKey); } on ApiError { /* offline: copy is deleted next time or by the person */ } }
    await store.delete('sync.secret');
    _k = null;
    await db.putFlag('local.sync', false);
    await db.logConsent('sync', 'disabled', 'user');
  }
}
