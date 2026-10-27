import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';

class MemoryScreen extends ConsumerStatefulWidget { const MemoryScreen({super.key}); @override ConsumerState<MemoryScreen> createState() => _MemState(); }
class _MemState extends ConsumerState<MemoryScreen> {
  @override
  Widget build(BuildContext context) {
    final db = ref.read(dbProvider), mem = ref.watch(memoryProvider);
    return Scaffold(appBar: AppBar(title: const Text('What Milo remembers')), body: FutureBuilder(
      future: db.memories(),
      builder: (_, s) {
        final rows = s.data ?? [];
        return ListView(padding: const EdgeInsets.all(16), children: [
          SwitchListTile(title: const Text('Pause memory', style: TextStyle(fontSize: 18)), subtitle: const Text('While paused, Milo saves nothing new.'), value: mem.paused, onChanged: (v) async { await mem.setPaused(v); }),
          if (rows.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Nothing yet. Say “remember I like pictures” and I will ask you first.', style: TextStyle(fontSize: 17))),
          for (final r in rows) Card(child: ListTile(
            title: Text('${r['key']}: ${r['value']}', style: const TextStyle(fontSize: 17)),
            subtitle: Text('${r['source'] == 'user_confirmed' ? 'You confirmed this' : 'You said this'}${r['expires_at'] == null ? '' : ' • forgets itself in a few days'}${r['consent_scope'] == 'local_only' ? ' • stays on this phone' : ''}'),
            trailing: IconButton(tooltip: 'Forget this', icon: const Icon(Icons.delete_outline), onPressed: () async { await db.forget(r['id'] as String); setState(() {}); }))),
          if (rows.isNotEmpty) ...[
            OutlinedButton.icon(onPressed: () => Clipboard.setData(ClipboardData(text: jsonEncode([for (final r in rows) {'key': r['key'], 'value': r['value']}]))), icon: const Icon(Icons.copy), label: const Text('Copy my memories')),
            TextButton(onPressed: () async { await db.forgetAll(); setState(() {}); }, child: const Text('Forget everything')),
          ],
        ]);
      },
    ));
  }
}

class LedgerScreen extends ConsumerStatefulWidget { const LedgerScreen({super.key}); @override ConsumerState<LedgerScreen> createState() => _LedgerState(); }
class _LedgerState extends ConsumerState<LedgerScreen> {
  @override
  Widget build(BuildContext context) {
    final db = ref.read(dbProvider);
    return Scaffold(appBar: AppBar(title: const Text('Privacy and cloud')), body: FutureBuilder(
      future: Future.wait([db.ledgerRows(), db.flag('cloud.enabled'), db.flag('cloud.name')]),
      builder: (_, s) {
        if (!s.hasData) return const SizedBox();
        final rows = s.data![0] as List<Map<String, Object?>>, cloud = s.data![1] as bool, name = s.data![2] as bool;
        final day = DateTime.now().millisecondsSinceEpoch - 86400000;
        return ListView(padding: const EdgeInsets.all(16), children: [
          SwitchListTile(title: const Text('Use cloud AI', style: TextStyle(fontSize: 18)), subtitle: const Text('Needed for explaining new text, photos, voice and wording help.'), value: cloud,
              onChanged: (v) async { await db.putFlag('cloud.enabled', v); await db.logConsent('cloud.enabled', v ? 'on' : 'off', 'user'); ref.read(ladderProvider.notifier).refresh(); setState(() {}); }),
          SwitchListTile(title: const Text('Send my first name'), value: name, onChanged: (v) async { await db.putFlag('cloud.name', v); await db.logConsent('cloud.name', v ? 'on' : 'off', 'user'); setState(() {}); }),
          const ListTile(title: Text('Keep voice recordings'), subtitle: Text('Never. Your voice is transcribed live and not kept.'), trailing: Icon(Icons.block)),
          const Divider(),
          const Text('Sent in the last day', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          if (rows.where((r) => (r['ts'] as int) > day).isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Nothing was sent.')),
          for (final r in rows.where((r) => (r['ts'] as int) > day)) ListTile(dense: true, title: Text('${r['kind']}: ${r['summary']}'), subtitle: Text('${DateTime.fromMillisecondsSinceEpoch(r['ts'] as int)}'.substring(0, 16))),
          const Divider(),
          const Text('Never sent', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
          for (final t in ['Your saved phrases and board', 'Personal photos', 'Voice recordings', 'Your progress counts', 'Memories marked “stays on this phone”', 'Anything in the grown-up area']) ListTile(dense: true, leading: const Icon(Icons.check, size: 18), title: Text(t)),
        ]);
      },
    ));
  }
}
