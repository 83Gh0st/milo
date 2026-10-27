import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import 'privacy_screens.dart';
import 'screen.dart';
import 'theme.dart';

/// Wireframe 10.2: settings and counts only. Never conversation text.
class TrustedScreen extends ConsumerWidget {
  const TrustedScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    void go(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    return MiloScreen(title: 'Trusted adult', body: ListView(padding: const EdgeInsets.all(16), children: [
      const Center(child: Icon(Icons.lock, color: T.pri, size: 34)), const Center(child: Padding(padding: EdgeInsets.all(8), child: Text('Grown-up area', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)))),
      RowCard(icon: Icons.grid_view, title: 'Words and symbols', subtitle: 'Add, edit, order', onTap: () => go(const WordsEditor())),
      RowCard(icon: Icons.menu_book_outlined, title: 'Reading support', subtitle: 'Level, speed, voice', color: 1, onTap: () => openScreen('home')),
      RowCard(icon: Icons.cloud_outlined, title: 'Cloud and privacy', subtitle: 'Cloud on or off, memory', color: 2, onTap: () => go(const LedgerScreen())),
      RowCard(icon: Icons.bedtime_outlined, title: 'Gentle time limits', subtitle: d.breakNudgeMin == 0 ? 'Off' : 'Break nudge every ${d.breakNudgeMin} min', color: 3, onTap: () => go(const TimeLimits())),
      RowCard(icon: Icons.insights, title: 'Weekly summary', subtitle: 'Progress only, no chats', onTap: () => go(const WeeklySummary())),
      RowCard(icon: Icons.phone_outlined, title: 'Trusted contacts', subtitle: 'Used by the Help me sheet', color: 1, onTap: () => go(const Contacts())),
      const SizedBox(height: 12), BigButton('Lock', () => Navigator.pop(context), kind: BK.outline),
    ]));
  }
}

class WordsEditor extends ConsumerStatefulWidget { const WordsEditor({super.key}); @override ConsumerState<WordsEditor> createState() => _WEState(); }
class _WEState extends ConsumerState<WordsEditor> {
  final emoji = TextEditingController(text: '⭐'), label = TextEditingController();
  @override
  Widget build(BuildContext context) {
    final db = ref.read(dbProvider);
    return MiloScreen(title: 'Edit board', body: FutureBuilder(future: db.tiles(), builder: (_, s) {
      final tiles = s.data ?? [];
      return ListView(padding: const EdgeInsets.all(16), children: [
        const Section('Add a tile'),
        Row(children: [SizedBox(width: 70, child: TextField(controller: emoji, style: const TextStyle(fontSize: 28))), const SizedBox(width: 8), Expanded(child: TextField(controller: label, decoration: const InputDecoration(hintText: 'Word, e.g. Grandma'))),
          IconButton.filled(onPressed: () async { if (label.text.trim().isEmpty) return; await db.addTile(emoji.text.trim().isEmpty ? '⭐' : emoji.text.trim(), label.text.trim()); label.clear(); setState(() {}); }, icon: const Icon(Icons.add))]),
        const Section('Your tiles'),
        for (final t in tiles) Card(child: ListTile(leading: Text('${t['emoji']}', style: const TextStyle(fontSize: 26)), title: Text('${t['label']}'), trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () async { await db.deleteTile(t['id'] as String); setState(() {}); }))),
        const SizedBox(height: 10),
        Row(children: [Expanded(child: BigButton('Export', () => Clipboard.setData(ClipboardData(text: jsonEncode([for (final t in tiles) {'emoji': t['emoji'], 'label': t['label']}]))), kind: BK.soft)), const SizedBox(width: 10),
          Expanded(child: BigButton('Paste board', () async { final d = await Clipboard.getData('text/plain'); try { for (final t in jsonDecode(d?.text ?? '[]') as List) { await db.addTile('${t['emoji']}', '${t['label']}'); } setState(() {}); } catch (_) {} }, kind: BK.outline))]),
        const Padding(padding: EdgeInsets.all(12), child: Text('Tile positions never change unless you change them. Photo tiles are planned.', style: TextStyle(fontSize: 12, color: T.mute))),
      ]);
    }));
  }
}

class TimeLimits extends ConsumerWidget {
  const TimeLimits({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    return MiloScreen(title: 'Gentle time limits', body: ListView(padding: const EdgeInsets.all(16), children: [
      const Text('Milo can offer a break after a long session. It is only a suggestion and never locks anything.', style: TextStyle(fontSize: 16)), const SizedBox(height: 12),
      for (final m in [0, 10, 20, 30]) Card(child: RadioListTile<int>(value: m, groupValue: d.breakNudgeMin, title: Text(m == 0 ? 'Off' : 'Every $m minutes'), onChanged: (v) => d.set(() => d.breakNudgeMin = v ?? 0))),
    ]));
  }
}

class WeeklySummary extends ConsumerWidget {
  const WeeklySummary({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final db = ref.read(dbProvider);
    return MiloScreen(title: 'Weekly summary', body: FutureBuilder(future: Future.wait([db.counts(), db.flag('progress.enabled', def: true)]), builder: (_, s) {
      if (!s.hasData) return const SizedBox();
      final c = s.data![0] as Map<String, int>, on = s.data![1] as bool;
      Widget row(String e, String l, int n) => Card(child: ListTile(leading: Text(e, style: const TextStyle(fontSize: 26)), title: Text(l), trailing: Text('$n', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800))));
      return ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Counts only. Never messages, never transcripts.', style: TextStyle(color: T.mute)),
        _SwitchRow('Show progress to the child', on, (v) async { await db.putFlag('progress.enabled', v); (context as Element).markNeedsBuild(); }),
        row('📖', 'Things read', c['read'] ?? 0), row('✅', 'Steps done', c['step'] ?? 0), row('🏁', 'Plans finished', c['task'] ?? 0), row('💬', 'Messages spoken', c['spoken'] ?? 0), row('🙋', 'Times asked for help', c['help'] ?? 0)]);
    }));
  }
}

class _SwitchRow extends StatelessWidget { const _SwitchRow(this.t, this.v, this.f); final String t; final bool v; final void Function(bool) f; @override Widget build(BuildContext c) => Card(child: SwitchListTile(title: Text(t), value: v, onChanged: f)); }

class Contacts extends ConsumerStatefulWidget { const Contacts({super.key}); @override ConsumerState<Contacts> createState() => _ContactsState(); }
class _ContactsState extends ConsumerState<Contacts> {
  final trusted = TextEditingController(), doctor = TextEditingController(), dname = TextEditingController();
  @override
  void initState() { super.initState(); final db = ref.read(dbProvider); db.get('local.trusted_phone').then((v) => trusted.text = v ?? ''); db.get('local.doctor_phone').then((v) => doctor.text = v ?? ''); db.get('local.doctor_name').then((v) => dname.text = v ?? ''); }
  @override
  Widget build(BuildContext context) {
    final db = ref.read(dbProvider);
    return MiloScreen(title: 'Trusted contacts', body: ListView(padding: const EdgeInsets.all(16), children: [
      const Section('Trusted person'), TextField(controller: trusted, keyboardType: TextInputType.phone, onChanged: (v) => db.put('local.trusted_phone', v), decoration: const InputDecoration(hintText: 'Phone number')),
      const Section('Doctor (for the “Call the doctor” plan)'), TextField(controller: dname, onChanged: (v) => db.put('local.doctor_name', v), decoration: const InputDecoration(hintText: 'Name, e.g. Dr. Sharma')),
      const SizedBox(height: 8), TextField(controller: doctor, keyboardType: TextInputType.phone, onChanged: (v) => db.put('local.doctor_phone', v), decoration: const InputDecoration(hintText: 'Phone number')),
      const Padding(padding: EdgeInsets.all(12), child: Text('Numbers stay on this phone and are never sent. Milo only opens your phone app after a tap.', style: TextStyle(fontSize: 12, color: T.mute))),
    ]));
  }
}
