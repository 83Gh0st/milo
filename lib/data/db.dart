import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path/path.dart' as p;
import 'package:sqflite_sqlcipher/sqflite.dart';
import 'secure_store.dart';

const kProfile = 1; // every table carries profile_id from day one (multi-profile ready)
/// Tables that sync, with primary-key column and the ONLY columns a remote row may set (never trust remote column names).
const kSync = {'settings': 'key', 'support_profile': 'axis', 'memories': 'id', 'phrases': 'id', 'documents': 'id', 'board_items': 'id'};
const kCols = {
  'settings': ['key', 'value', 'updated_at'],
  'support_profile': ['profile_id', 'axis', 'value', 'source', 'updated_at'],
  'memories': ['id', 'profile_id', 'type', 'key', 'value', 'source', 'consent_scope', 'created_at', 'updated_at', 'expires_at', 'status'],
  'phrases': ['id', 'profile_id', 'text', 'usage_count', 'last_used', 'updated_at'],
  'documents': ['id', 'profile_id', 'title', 'text', 'saved_by_user', 'created_at', 'updated_at'],
  'board_items': ['id', 'profile_id', 'position', 'label', 'emoji', 'spoken_text', 'is_core', 'updated_at'],
};
int now() => DateTime.now().millisecondsSinceEpoch;
String newId() { final r = Random.secure(); return List.generate(12, (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0')).join(); }

class MiloDb {
  final Database db;
  final SecureStore store;
  final String path;
  MiloDb._(this.db, this.store, this.path);

  static Future<MiloDb> open(SecureStore store) async {
    final path = p.join(await getDatabasesPath(), 'milo.db');
    final db = await openDatabase(path, password: await store.dbKey(), version: 1, onCreate: (d, v) async {
      for (final s in _schema) { await d.execute(s); }
    });
    final m = MiloDb._(db, store, path);
    await m.purgeExpired();
    return m;
  }

  static const _schema = [
    'CREATE TABLE profiles(id INTEGER PRIMARY KEY, display_name TEXT, presentation TEXT, presence TEXT, ui_lang TEXT, speech_lang TEXT, created_at INTEGER)',
    'CREATE TABLE support_profile(profile_id INTEGER, axis TEXT, value TEXT, source TEXT, updated_at INTEGER, PRIMARY KEY(profile_id, axis))',
    'CREATE TABLE memories(id TEXT PRIMARY KEY, profile_id INTEGER, type TEXT, key TEXT, value TEXT, source TEXT, consent_scope TEXT, created_at INTEGER, updated_at INTEGER, expires_at INTEGER, status TEXT)',
    'CREATE TABLE board_items(id TEXT PRIMARY KEY, profile_id INTEGER, position INTEGER, label TEXT, emoji TEXT, spoken_text TEXT, is_core INTEGER, updated_at INTEGER)',
    'CREATE TABLE phrases(id TEXT PRIMARY KEY, profile_id INTEGER, text TEXT, usage_count INTEGER, last_used INTEGER, updated_at INTEGER)',
    'CREATE TABLE documents(id TEXT PRIMARY KEY, profile_id INTEGER, title TEXT, text TEXT, saved_by_user INTEGER, created_at INTEGER, updated_at INTEGER)',
    'CREATE TABLE explanation_cache(content_hash TEXT, strategy TEXT, language TEXT, payload_json TEXT, created_at INTEGER, PRIMARY KEY(content_hash, strategy, language))',
    'CREATE TABLE progress_events(id INTEGER PRIMARY KEY AUTOINCREMENT, profile_id INTEGER, type TEXT, ts INTEGER)',
    'CREATE TABLE consent_log(id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, scope TEXT, choice TEXT, actor TEXT)',
    'CREATE TABLE cloud_ledger(id INTEGER PRIMARY KEY AUTOINCREMENT, ts INTEGER, endpoint TEXT, kind TEXT, summary TEXT, bytes INTEGER, included_name INTEGER, voice_kept INTEGER)',
    'CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT, updated_at INTEGER)',
    'CREATE TABLE sync_outbox(tbl TEXT, pk TEXT, updated_at INTEGER, deleted INTEGER, PRIMARY KEY(tbl, pk))',
  ];

  // ---- settings (keys starting "local." never sync) ----
  Future<String?> get(String k) async { final r = await db.query('settings', where: 'key=?', whereArgs: [k]); return r.isEmpty ? null : r.first['value'] as String?; }
  Future<bool> flag(String k, {bool def = false}) async { final v = await get(k); return v == null ? def : v == '1'; }
  Future<void> put(String k, String v) async {
    final t = now();
    await db.insert('settings', {'key': k, 'value': v, 'updated_at': t}, conflictAlgorithm: ConflictAlgorithm.replace);
    if (!k.startsWith('local.')) await touch('settings', k);
  }
  Future<void> putFlag(String k, bool v) => put(k, v ? '1' : '0');
  Future<Map<String, String>> allSettings() async => {for (final r in await db.query('settings')) r['key'] as String: (r['value'] ?? '') as String};

  // ---- support profile ----
  Future<void> setAxis(String axis, String value, {String source = 'user'}) async {
    await db.insert('support_profile', {'profile_id': kProfile, 'axis': axis, 'value': value, 'source': source, 'updated_at': now()}, conflictAlgorithm: ConflictAlgorithm.replace);
    await touch('support_profile', axis);
  }
  Future<Map<String, String>> support() async => {for (final r in await db.query('support_profile')) r['axis'] as String: r['value'] as String};

  // ---- memories ----
  Future<String> addMemory(String type, String key, String value, String source, {String scope = 'may_send', int? ttlDays}) async {
    final id = newId(), t = now();
    await db.insert('memories', {'id': id, 'profile_id': kProfile, 'type': type, 'key': key, 'value': value, 'source': source, 'consent_scope': scope,
      'created_at': t, 'updated_at': t, 'expires_at': ttlDays == null ? null : t + ttlDays * 86400000, 'status': 'active'});
    await touch('memories', id);
    await logConsent('memory:$key', 'saved', 'user');
    return id;
  }
  Future<List<Map<String, Object?>>> memories() => db.query('memories', where: "status='active'", orderBy: 'created_at DESC');
  /// Hard delete + cache purge in ONE transaction (acceptance test: forgetting leaves nothing behind).
  Future<void> forget(String id) async {
    await db.transaction((t) async {
      await t.delete('memories', where: 'id=?', whereArgs: [id]);
      await t.delete('explanation_cache');
      await t.insert('sync_outbox', {'tbl': 'memories', 'pk': id, 'updated_at': now(), 'deleted': 1}, conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }
  Future<void> forgetAll() async { for (final m in await db.query('memories', columns: ['id'])) { await forget(m['id'] as String); } await db.execute('VACUUM'); }
  Future<void> purgeExpired() async {
    for (final m in await db.query('memories', columns: ['id'], where: 'expires_at IS NOT NULL AND expires_at<?', whereArgs: [now()])) { await forget(m['id'] as String); }
  }
  /// At most 5 items for one activity, only whitelisted keys, only memories the person allowed to be sent.
  Future<List<Map<String, String>>> forRequest(List<String> keys) async {
    final rows = await db.query('memories', where: "status='active' AND consent_scope='may_send'", orderBy: 'updated_at DESC');
    return [for (final r in rows) if (keys.contains(r['key'])) {'key': r['key'] as String, 'value': r['value'] as String}].take(5).toList();
  }

  // ---- phrases, cache, documents, board ----
  Future<void> bumpPhrase(String text) async {
    final r = await db.query('phrases', where: 'text=?', whereArgs: [text]);
    final t = now();
    if (r.isEmpty) { final id = newId(); await db.insert('phrases', {'id': id, 'profile_id': kProfile, 'text': text, 'usage_count': 1, 'last_used': t, 'updated_at': t}); await touch('phrases', id); }
    else { final id = r.first['id'] as String; await db.update('phrases', {'usage_count': (r.first['usage_count'] as int) + 1, 'last_used': t, 'updated_at': t}, where: 'id=?', whereArgs: [id]); await touch('phrases', id); }
  }
  Future<List<String>> recentPhrases([int n = 6]) async => [for (final r in await db.query('phrases', orderBy: 'last_used DESC', limit: n)) r['text'] as String];
  Future<String?> cacheGet(String h, String strategy, String lang) async {
    final r = await db.query('explanation_cache', where: 'content_hash=? AND strategy=? AND language=?', whereArgs: [h, strategy, lang]);
    return r.isEmpty ? null : r.first['payload_json'] as String;
  }
  Future<void> cachePut(String h, String strategy, String lang, String json) => db.insert('explanation_cache',
      {'content_hash': h, 'strategy': strategy, 'language': lang, 'payload_json': json, 'created_at': now()}, conflictAlgorithm: ConflictAlgorithm.replace);
  Future<List<Map<String, Object?>>> tiles() => db.query('board_items', orderBy: 'position');
  Future<void> addTile(String emoji, String label) async {
    final id = newId(), t = now();
    await db.insert('board_items', {'id': id, 'profile_id': kProfile, 'position': t ~/ 1000, 'label': label, 'emoji': emoji, 'spoken_text': label, 'is_core': 0, 'updated_at': t});
    await touch('board_items', id);
  }
  Future<void> deleteTile(String id) async { await db.delete('board_items', where: 'id=?', whereArgs: [id]); await touch('board_items', id, deleted: true); }

  // ---- saved documents (plan 8.1): rows exist only if the person chose to save ----
  Future<String> addDocument(String title, String text) async {
    final id = newId(), t = now();
    await db.insert('documents', {'id': id, 'profile_id': kProfile, 'title': title, 'text': text, 'saved_by_user': 1, 'created_at': t, 'updated_at': t});
    await touch('documents', id);
    return id;
  }
  Future<List<Map<String, Object?>>> documents() => db.query('documents', orderBy: 'created_at DESC');
  Future<void> deleteDocument(String id) async { await db.delete('documents', where: 'id=?', whereArgs: [id]); await touch('documents', id, deleted: true); }

  // ---- progress (counts only, never content) ----
  Future<void> progress(String type) => db.insert('progress_events', {'profile_id': kProfile, 'type': type, 'ts': now()});
  Future<Map<String, int>> counts({int days = 7}) async {
    final since = now() - days * 86400000;
    final r = await db.rawQuery('SELECT type, COUNT(*) c FROM progress_events WHERE ts>=? GROUP BY type', [since]);
    return {for (final x in r) x['type'] as String: x['c'] as int};
  }
  Future<int> daysTogether() async {
    final r = await db.rawQuery("SELECT COUNT(DISTINCT strftime('%Y-%m-%d', ts/1000, 'unixepoch')) c FROM progress_events");
    return (r.first['c'] as int) + 0; // never decreases, never resets
  }

  // ---- consent + cloud ledger ----
  Future<void> logConsent(String scope, String choice, String actor) => db.insert('consent_log', {'ts': now(), 'scope': scope, 'choice': choice, 'actor': actor});
  Future<void> ledger(String endpoint, String kind, String summary, int bytes, bool name, bool voice) =>
      db.insert('cloud_ledger', {'ts': now(), 'endpoint': endpoint, 'kind': kind, 'summary': summary, 'bytes': bytes, 'included_name': name ? 1 : 0, 'voice_kept': voice ? 1 : 0});
  Future<List<Map<String, Object?>>> ledgerRows([int n = 100]) => db.query('cloud_ledger', orderBy: 'id DESC', limit: n);

  // ---- sync plumbing ----
  Future<void> touch(String tbl, String pk, {bool deleted = false}) async {
    if (!kSync.containsKey(tbl)) return;
    await db.insert('sync_outbox', {'tbl': tbl, 'pk': pk, 'updated_at': now(), 'deleted': deleted ? 1 : 0}, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  Future<List<Map<String, Object?>>> outbox() => db.query('sync_outbox', limit: 200);
  Future<void> clearOutbox(String tbl, String pk, int upTo) => db.delete('sync_outbox', where: 'tbl=? AND pk=? AND updated_at<=?', whereArgs: [tbl, pk, upTo]);
  Future<Map<String, Object?>?> rowJson(String tbl, String pk) async {
    final r = await db.query(tbl, where: '${kSync[tbl]}=?', whereArgs: [pk]);
    return r.isEmpty ? null : Map<String, Object?>.from(r.first);
  }
  Future<int> updatedAt(String tbl, String pk) async => (await rowJson(tbl, pk))?['updated_at'] as int? ?? 0;
  Future<int> localStamp(String tbl, String pk) async {
    final o = await db.query('sync_outbox', columns: ['updated_at'], where: 'tbl=? AND pk=?', whereArgs: [tbl, pk]);
    return max(await updatedAt(tbl, pk), o.isEmpty ? 0 : o.first['updated_at'] as int);
  }
  Future<void> applyRemote(String tbl, String pk, Map<String, dynamic> row) async {
    final cols = kCols[tbl]; if (cols == null) return;
    final clean = <String, Object?>{for (final c in cols) if (row.containsKey(c)) c: row[c]};
    if (clean.containsKey('profile_id')) clean['profile_id'] = kProfile;
    clean[kSync[tbl]!] = pk;
    await db.insert(tbl, clean, conflictAlgorithm: ConflictAlgorithm.replace);
  }
  Future<void> applyRemoteDelete(String tbl, String pk) async { if (kSync.containsKey(tbl)) await db.delete(tbl, where: '${kSync[tbl]}=?', whereArgs: [pk]); }
  Future<void> queueEverything() async {
    for (final e in kSync.entries) {
      if (e.key == 'settings') continue; // settings are queued key by key as they change
      for (final r in await db.query(e.key, columns: [e.value])) { await touch(e.key, r[e.value] as String); }
    }
    for (final r in await db.query('settings', columns: ['key'])) { final k = r['key'] as String; if (!k.startsWith('local.')) await touch('settings', k); }
  }

  /// "Delete everything": database file, keys, cache. Caller also deletes the cloud vault first if sync was on.
  Future<void> deleteEverything() async {
    await db.close();
    await deleteDatabase(path);
    try { await File('$path-journal').delete(); } catch (_) {}
    await store.wipe();
  }
}
