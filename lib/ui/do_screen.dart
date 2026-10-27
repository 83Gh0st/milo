import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../companion/milo_view.dart';
import '../core/payload.dart';
import '../core/providers.dart';
import 'screen.dart';
import 'theme.dart';

typedef Steps = List<List<String>>;
const Map<String, Steps> _routines = {
  'Get ready for school': [['🛏️', 'Wake up and wash'], ['👕', 'Get dressed'], ['🥣', 'Eat breakfast'], ['🎒', 'Pack your bag'], ['👟', 'Put on your shoes']],
  'Call the doctor': [['📱', 'Open the phone app'], ['👤', 'Choose the doctor'], ['📞', 'Tap call']],
  'Finish my assignment': [['📚', 'Get your books'], ['✏️', 'Pick one task'], ['⏱️', 'Work for ten minutes'], ['✅', 'Check it'], ['📤', 'Hand it in']],
  'Buy groceries': [['📝', 'Write a list'], ['🛍️', 'Take a bag'], ['🛒', 'Find the things'], ['💳', 'Pay']],
};
const _handoff = {'Get ready for school': 'Can you help me please', 'Call the doctor': 'Hello I would like to make an appointment', 'Finish my assignment': 'I need some help with my work', 'Buy groceries': 'Where can I find this please'};

/// Do things (wireframes 6.1 to 6.5): one step at a time, a visible confirmation before anything external, no timers, no nagging.
class DoScreen extends ConsumerStatefulWidget { const DoScreen({super.key}); @override ConsumerState<DoScreen> createState() => _DState(); }
class _DState extends ConsumerState<DoScreen> {
  int tab = 0, step = 0;
  String? sel;
  bool reviewing = false;
  Steps steps = [];
  List<Map<String, dynamic>> saved = [];
  final goal = TextEditingController();
  bool planning = false;

  @override
  void initState() { super.initState(); _restore(); }
  Future<void> _restore() async {
    final db = ref.read(dbProvider);
    final raw = await db.get('local.do'), tasks = await db.get('local.tasks');
    try {
      if (tasks != null && tasks.isNotEmpty) saved = [for (final t in jsonDecode(tasks) as List) Map<String, dynamic>.from(t as Map)];
      if (raw != null && raw.isNotEmpty) { final m = jsonDecode(raw) as Map<String, dynamic>; sel = m['t'] as String?; steps = [for (final s in m['s'] as List) ['${s[0]}', '${s[1]}']]; step = m['i'] as int; }
    } catch (_) {}
    if (mounted) setState(() {});
  }
  Future<void> _save() => ref.read(dbProvider).put('local.do', sel == null ? '' : jsonEncode({'t': sel, 's': steps, 'i': step}));
  Future<void> _saveTasks() => ref.read(dbProvider).put('local.tasks', jsonEncode(saved));

  void _review(String title, Steps s) {
    final d = ref.read(directorProvider);
    setState(() { sel = title; steps = [for (final x in s) [...x]]; step = 0; reviewing = true; });
    ref.read(chipsProvider.notifier).put(ChipItem('task', 'You’re working on: $title', steps.map((x) => x[1]).join('. ')));
    d.emote('curious', i: .7, hold: 4); d.gesture('point', force: true);
  }
  void _start() { setState(() => reviewing = false); _save(); }
  void _end() { setState(() { sel = null; reviewing = false; }); ref.read(chipsProvider.notifier).clearKind('task'); _save(); }

  Future<void> _plan() async {
    final d = ref.read(directorProvider), g = goal.text.trim();
    if (g.isEmpty) return;
    final key = _routines.keys.where((k) => g.toLowerCase().contains(k.split(' ').last.toLowerCase())).firstOrNull;
    if (key != null) { _review(key, _routines[key]!); goal.clear(); return; } // known routines load instantly, offline
    setState(() => planning = true);
    try { final p = await ref.read(apiProvider).plan(g, d.profile.name, d.lang); _review(g, [for (final s in p) [s['emoji']!, s['text']!]]); goal.clear(); }
    catch (_) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Making a new plan needs the internet. These plans work offline.'))); }
    if (mounted) setState(() => planning = false);
  }

  Future<void> _addStep() async {
    final t = TextEditingController();
    final v = await showDialog<String>(context: context, builder: (_) => AlertDialog(title: const Text('Add a step'), content: TextField(controller: t, autofocus: true), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, t.text), child: const Text('Add'))]));
    if (v != null && v.trim().isNotEmpty) setState(() => steps.add(['➕', v.trim()]));
  }

  @override
  Widget build(BuildContext context) {
    final d = ref.read(directorProvider), db = ref.read(dbProvider);
    Widget page;
    String title = 'Do things';
    if (sel == null) {
      page = ListView(padding: const EdgeInsets.all(16), children: [
        PillTabs(const ['Suggested', 'My tasks', 'My plan'], tab, (i) => setState(() => tab = i)), const SizedBox(height: 8),
        if (tab == 0) for (final e in _routines.entries) RowCard(icon: Icons.checklist, title: e.key, subtitle: 'Today · ${e.value.length} steps', color: _routines.keys.toList().indexOf(e.key), onTap: () => _review(e.key, e.value)),
        if (tab == 1) ...[for (final t in saved) RowCard(icon: Icons.star_outline, title: '${t['t']}', subtitle: '${(t['s'] as List).length} steps', color: 2, onTap: () => _review('${t['t']}', [for (final s in t['s'] as List) ['${s[0]}', '${s[1]}']])), if (saved.isEmpty) const Padding(padding: EdgeInsets.all(20), child: Text('Plans you make will be saved here.', style: TextStyle(color: T.mute)))],
        if (tab == 2) const Padding(padding: EdgeInsets.all(20), child: Text('Pick a task to start your plan. You can change any step before you begin.', style: TextStyle(color: T.mute, fontSize: 16))),
        const SizedBox(height: 10),
        TextField(controller: goal, onSubmitted: (_) => _plan(), decoration: InputDecoration(hintText: 'Tell Milo what you need to do…', suffixIcon: planning ? const Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator(strokeWidth: 2)) : IconButton(onPressed: _plan, icon: const Icon(Icons.auto_awesome, color: T.pri)))),
        const Padding(padding: EdgeInsets.all(10), child: Center(child: Text('Suggestions come from routines you used, never from guessing.', style: TextStyle(fontSize: 12, color: T.mute)))),
      ]);
    } else if (reviewing) {
      title = sel!;
      page = Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: Row(children: [const SizedBox(width: 56, height: 56, child: MiloView()), const SizedBox(width: 8), const Expanded(child: Speech('Here is a plan. Change anything you like.'))])),
        Expanded(child: ReorderableListView(padding: const EdgeInsets.symmetric(horizontal: 14), onReorder: (a, b) => setState(() { if (b > a) b--; steps.insert(b, steps.removeAt(a)); }), children: [
          for (var i = 0; i < steps.length; i++) Card(key: ValueKey('$i${steps[i][1]}'), child: ListTile(leading: const Icon(Icons.drag_handle, color: T.mute), title: Text('${i + 1}   ${steps[i][1]}', style: const TextStyle(fontSize: 17)), trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => setState(() => steps.removeAt(i)))))])),
        Padding(padding: const EdgeInsets.all(14), child: Column(children: [
          OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size(double.infinity, 52)), onPressed: _addStep, child: const Text('+ Add a step')),
          const Padding(padding: EdgeInsets.all(8), child: Text('Reorder, skip or edit any step. Nothing starts by itself.', style: TextStyle(fontSize: 12, color: T.mute))),
          BigButton('Start', steps.isEmpty ? null : () { if (!_routines.containsKey(sel) && !saved.any((t) => t['t'] == sel)) { saved.add({'t': sel, 's': steps}); _saveTasks(); } _start(); }), const SizedBox(height: 80)])),
      ]);
    } else if (step >= steps.length) {
      return Scaffold(backgroundColor: const Color(0xFFE9EDFF), body: SafeArea(child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
        const Spacer(), const SizedBox(height: 260, child: MiloView()), const Text('You finished!', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800)), Text(sel!, style: const TextStyle(color: T.mute, fontSize: 16)), const Spacer(),
        BigButton('Next task', _end), const SizedBox(height: 10),
        BigButton('Ask my teacher', () { final s = sel!; ref.read(expressTextProvider.notifier).state = _handoff[s] ?? 'Can you help me please'; _end(); openScreen('express', replace: true); }, kind: BK.soft), const SizedBox(height: 10),
        BigButton('Take a break', () { _end(); openScreen('break'); }, kind: BK.outline), const SizedBox(height: 10),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Back to Home'))]))));
    } else {
      title = sel!;
      final s = steps[step], isCall = RegExp(r'\bcall\b', caseSensitive: false).hasMatch(s[1]);
      page = Padding(padding: const EdgeInsets.all(20), child: Column(children: [
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (var i = 0; i < steps.length; i++) Container(margin: const EdgeInsets.all(4), width: 12, height: 12, decoration: BoxDecoration(shape: BoxShape.circle, color: i <= step ? T.pri : T.line))]),
        Text('Step ${step + 1} of ${steps.length}', style: const TextStyle(fontSize: 12, color: T.mute)), const SizedBox(height: 12),
        Container(height: 190, width: double.infinity, decoration: BoxDecoration(color: T.priSoft, borderRadius: BorderRadius.circular(22)), alignment: Alignment.center, child: Text(s[0], style: const TextStyle(fontSize: 84))),
        const SizedBox(height: 14), Text(s[1], textAlign: TextAlign.center, style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)),
        IconButton(iconSize: 34, tooltip: 'Hear it', onPressed: () => d.speak(s[1]), icon: const Icon(Icons.volume_up, color: T.pri)),
        if (isCall) TextButton(onPressed: () => openScreen('express'), child: const Text('Practise what to say first')),
        const Spacer(),
        BigButton('Done', () async {
          if (isCall) { final n = await db.get('local.doctor_phone') ?? await db.get('local.trusted_phone'); if (n != null && n.isNotEmpty && context.mounted) { await confirmCall(context, (await db.get('local.doctor_name')) ?? 'the doctor', n); } } // always a visible confirmation
          final last = step + 1 >= steps.length;
          setState(() => step++); _save(); d.celebrate(goal: last); await db.progress(last ? 'task' : 'step');
          if (last) { d.speak(d.profile.name == 'discreet' ? 'Done.' : 'You did it!'); ref.read(chipsProvider.notifier).clearKind('task'); } else { d.gesture('point', force: true); }
        }, kind: BK.mint), const SizedBox(height: 10),
        Row(children: [Expanded(child: BigButton('Help me', () { db.progress('help'); d.ask('I need help with: ${s[1]}'); }, kind: BK.soft)), const SizedBox(width: 10), Expanded(child: BigButton('Skip', () { setState(() => step++); _save(); }, kind: BK.outline))]),
        const SizedBox(height: 6), const Text('Take your time.', style: TextStyle(color: T.mute)), const SizedBox(height: 90),
      ]));
    }
    return MiloScreen(title: title, onBack: sel != null && !reviewing && step < steps.length ? () { _save(); Navigator.pop(context); } : (sel != null ? _end : null), body: page);
  }
}
