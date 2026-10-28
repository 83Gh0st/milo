import 'package:flutter/foundation.dart';
import '../contracts/brain_contract.dart';
import '../data/db.dart';
import 'payload.dart';

class MemCmd { final String kind; final String? arg; const MemCmd(this.kind, [this.arg]); }

/// Local grammar: memory commands are real operations on the database, never left to a model (doc 7.10).
MemCmd? parseMemory(String raw) {
  final s = raw.toLowerCase().replaceAll('’', "'").trim();
  if (RegExp(r"^(what do you remember|what do you know about me)").hasMatch(s)) return const MemCmd('list');
  if (RegExp(r"^pause memory").hasMatch(s)) return const MemCmd('pause');
  if (RegExp(r"^(resume|unpause) memory").hasMatch(s)) return const MemCmd('resume');
  if (RegExp(r"^(forget everything|forget all)").hasMatch(s)) return const MemCmd('forget_all');
  if (RegExp(r"^(forget that|don't remember (this|that))").hasMatch(s)) return const MemCmd('forget_last');
  final m = RegExp(r"^remember (?:that )?(.+)$", caseSensitive: false).firstMatch(raw.trim());
  return m == null ? null : MemCmd('remember', m.group(1)!.trim());
}

class Pending { final String kind, label; final Map<String, String> data; const Pending(this.kind, this.label, [this.data = const {}]); }

/// Lifecycle: propose -> confirm in plain words -> write (one transaction, with a consent_log entry) -> use (whitelist, max 5) -> review -> forget.
class MemoryManager extends ChangeNotifier {
  MemoryManager(this.db) {
    db.flag('local.memory_paused').then((v) { if (!_pausedSet) { paused = v; notifyListeners(); } });
    db.get('local.memory_last_id').then((v) { if (v != null && v.isNotEmpty) lastId = v; });
  }
  final MiloDb db;
  bool paused = false, _pausedSet = false; // an explicit set wins over the racing initial load
  Pending? pending;
  String? lastId;

  Future<void> setPaused(bool v) async { _pausedSet = true; paused = v; await db.putFlag('local.memory_paused', v); notifyListeners(); }
  void _ask(Pending p) { pending = p; notifyListeners(); }
  void dismiss() { pending = null; notifyListeners(); }

  /// Brain proposals: only things the person said or confirmed, only whitelisted keys. Paused = discarded.
  void propose(Map<String, dynamic> p) {
    final key = p['key'], value = p['value'];
    if (paused || key is! String || value is! String || !kMemKeys.values.any((l) => l.contains(key)) || !['user_stated', 'user_confirmed'].contains(p['source'])) return;
    _ask(Pending('remember', 'Want me to remember: $key is “$value”?', {'type': '${p['type'] == 'approved_fact' ? 'approved_fact' : 'preference'}', 'key': key, 'value': value, 'source': '${p['source']}'}));
  }

  void proposeLocal(String text) {
    if (paused) return;
    final t = text.toLowerCase();
    final style = t.contains('picture') ? 'visual' : t.contains('short') ? 'short' : null;
    _ask(style != null
        ? Pending('remember', 'Want me to remember that you like ${style == 'visual' ? 'pictures' : 'short sentences'}?', {'type': 'preference', 'key': 'explanation_style', 'value': style, 'source': 'user_stated'})
        : Pending('remember', 'Want me to remember: “$text”? It will stay on this phone.', {'type': 'approved_fact', 'key': 'note', 'value': text, 'source': 'user_stated', 'scope': 'local_only'}));
  }

  void askForgetLast() { if (lastId != null && lastId!.isNotEmpty) _ask(Pending('forget', 'Forget the last thing I remembered?', {'id': lastId!})); }
  void askForgetAll() => _ask(const Pending('forgetAll', 'Forget everything I remember about you?'));

  /// Executes after the person says Yes. Returns what Milo should say AFTER the operation succeeded.
  Future<String?> confirm() async {
    final p = pending; if (p == null) return null;
    pending = null;
    String? msg;
    switch (p.kind) {
      case 'remember':
        lastId = await db.addMemory(p.data['type']!, p.data['key']!, p.data['value']!, p.data['source']!, scope: p.data['scope'] ?? 'may_send', ttlDays: p.data['type'] == 'activity_state' ? 7 : null);
        await db.put('local.memory_last_id', lastId!); // device-local pointer: survives restarts, never syncs
        msg = 'Okay. I will remember that.';
      case 'forget': await db.forget(p.data['id']!); lastId = null; await db.put('local.memory_last_id', ''); msg = 'Done. I’ve forgotten that.';
      case 'forgetAll': await db.forgetAll(); lastId = null; await db.put('local.memory_last_id', ''); msg = 'Done. I’ve forgotten everything.';
    }
    notifyListeners();
    return msg;
  }

  Future<List<Map<String, String>>> forRequest(String activity) async => paused ? [] : await db.forRequest(memKeysFor(activity));
}
