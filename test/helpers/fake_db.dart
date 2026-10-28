import 'package:milo/data/db.dart';
import 'package:milo/data/secure_store.dart';
import 'package:sqflite_sqlcipher/sqflite.dart';

/// In-memory MiloDb for widget tests. Same shapes as the real rows; nothing
/// touches platform channels or SQL. Signatures mirror lib/data/db.dart exactly.
class FakeDb implements MiloDb {
  @override
  Database get db => throw UnimplementedError('FakeDb has no native database');
  @override
  final SecureStore store = SecureStore();
  @override
  String get path => ':memory:';

  final settings = <String, String>{};
  final mems = <Map<String, Object?>>[];
  final progressRows = <String>[];
  final ledgerList = <Map<String, Object?>>[];
  final docs = <Map<String, Object?>>[];
  final tileRows = <Map<String, Object?>>[];
  final phrases = <String>[];
  int _id = 0;

  @override
  Future<String?> get(String k) async => settings[k];
  @override
  Future<bool> flag(String k, {bool def = false}) async => settings.containsKey(k) ? settings[k] == '1' : def;
  @override
  Future<void> put(String k, String v) async => settings[k] = v;
  @override
  Future<void> putFlag(String k, bool v) async => settings[k] = v ? '1' : '0';
  @override
  Future<Map<String, String>> allSettings() async => Map.of(settings);
  @override
  Future<void> setAxis(String axis, String value, {String source = 'user'}) async => settings['axis.$axis'] = value;
  @override
  Future<Map<String, String>> support() async => {'plan': settings['axis.plan'] ?? '', 'voice': settings['axis.voice'] ?? ''};
  @override
  Future<String> addMemory(String type, String key, String value, String source, {String scope = 'may_send', int? ttlDays}) async {
    final id = '${++_id}';
    mems.removeWhere((m) => m['key'] == key);
    mems.add({'id': id, 'type': type, 'key': key, 'value': value, 'source': source, 'consent_scope': scope, 'created_at': 1, 'updated_at': 1, 'expires_at': null, 'status': 'active'});
    return id;
  }

  @override
  Future<List<Map<String, Object?>>> memories() async => List.of(mems);
  @override
  Future<void> forget(String id) async => mems.removeWhere((m) => m['id'] == id);
  @override
  Future<void> forgetAll() async => mems.clear();
  @override
  Future<void> purgeExpired() async {}
  @override
  Future<List<Map<String, String>>> forRequest(List<String> keys) async =>
      [for (final m in mems) if (m['consent_scope'] == 'may_send' && keys.contains(m['key'])) {'key': '${m['key']}', 'value': '${m['value']}'}].take(5).toList();
  @override
  Future<void> bumpPhrase(String text) async {
    phrases.remove(text);
    phrases.insert(0, text);
  }

  @override
  Future<List<String>> recentPhrases([int n = 6]) async => phrases.take(n).toList();
  @override
  Future<String?> cacheGet(String h, String strategy, String lang) async => settings['cache.$h.$strategy.$lang'];
  @override
  Future<void> cachePut(String h, String strategy, String lang, String json) async => settings['cache.$h.$strategy.$lang'] = json;
  @override
  Future<List<Map<String, Object?>>> tiles() async => List.of(tileRows);
  @override
  Future<void> addTile(String emoji, String label) async => tileRows.add({'id': '${++_id}', 'label': label, 'emoji': emoji, 'spoken_text': label, 'is_core': 0, 'position': _id});
  @override
  Future<void> deleteTile(String id) async => tileRows.removeWhere((t) => t['id'] == id);
  @override
  Future<String> addDocument(String title, String text) async {
    final id = '${++_id}';
    docs.add({'id': id, 'title': title, 'text': text});
    return id;
  }

  @override
  Future<List<Map<String, Object?>>> documents() async => List.of(docs);
  @override
  Future<void> deleteDocument(String id) async => docs.removeWhere((d) => d['id'] == id);
  @override
  Future<void> progress(String type) async => progressRows.add(type);
  @override
  Future<Map<String, int>> counts({int days = 7}) async {
    final m = <String, int>{};
    for (final t in progressRows) {
      m[t] = (m[t] ?? 0) + 1;
    }
    return m;
  }

  @override
  Future<Map<int, int>> weekCounts() async => {3: progressRows.length};
  @override
  Future<int> daysTogether() async => 1;
  @override
  Future<void> logConsent(String scope, String choice, String actor) async => settings['consent.$scope'] = choice;
  @override
  Future<void> ledger(String endpoint, String kind, String summary, int bytes, bool name, bool voice) async =>
      ledgerList.add({'ts': 1, 'endpoint': endpoint, 'kind': kind, 'summary': summary, 'bytes': bytes, 'included_name': name ? 1 : 0, 'voice_kept': voice ? 1 : 0});
  @override
  Future<List<Map<String, Object?>>> ledgerRows([int n = 100]) async => ledgerList.reversed.take(n).toList();
  @override
  Future<void> touch(String tbl, String pk, {bool deleted = false}) async {}
  @override
  Future<List<Map<String, Object?>>> outbox() async => [];
  @override
  Future<void> clearOutbox(String tbl, String pk, int upTo) async {}
  @override
  Future<Map<String, Object?>?> rowJson(String tbl, String pk) async => null;
  @override
  Future<int> updatedAt(String tbl, String pk) async => 0;
  @override
  Future<int> localStamp(String tbl, String pk) async => 0;
  @override
  Future<void> applyRemote(String tbl, String pk, Map<String, dynamic> row) async {}
  @override
  Future<void> applyRemoteDelete(String tbl, String pk) async {}
  @override
  Future<void> queueEverything() async {}
  @override
  Future<void> deleteEverything() async {
    settings.clear();
    mems.clear();
    progressRows.clear();
    ledgerList.clear();
    docs.clear();
    tileRows.clear();
    phrases.clear();
  }
}
