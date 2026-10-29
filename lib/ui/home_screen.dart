import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../companion/director.dart';
import '../core/providers.dart';
import 'screen.dart';
import 'theme.dart';

class HomeScreen extends ConsumerStatefulWidget { const HomeScreen({super.key}); @override ConsumerState<HomeScreen> createState() => _HomeState(); }

class _HomeState extends ConsumerState<HomeScreen> {
  String? cont;
  bool hideCont = false;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async { // the Continue card appears only when work is unfinished
    final raw = await ref.read(dbProvider).get('local.do');
    if (raw == null || raw.isEmpty) return;
    try { final m = jsonDecode(raw) as Map<String, dynamic>; if ((m['i'] as int) < (m['s'] as List).length) setState(() => cont = '${m['t']}  ·  step ${(m['i'] as int) + 1} of ${(m['s'] as List).length}'); } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final d = ref.watch(directorProvider);
    ref.listen<int>(tabProvider, (_, n) { if (n == 0) _load(); });
    final stage = d.presence == Presence.stage, discreet = d.profile == Profile.discreet;
    final greet = d.caption.isEmpty ? 'Hi!' : d.caption;
    if (d.preReader) { // pre-reader home (wireframe 12.2): three big picture buttons, Help and Break on the bottom row
      Widget big(IconData i, String l, int c, VoidCallback f) => Padding(padding: const EdgeInsets.symmetric(vertical: 5), child: Material(color: T.soft[c], borderRadius: BorderRadius.circular(22), child: InkWell(borderRadius: BorderRadius.circular(22), onTap: () { d.speak(l); f(); },
          child: Padding(padding: const EdgeInsets.all(22), child: Row(children: [Icon(i, size: 34, color: T.strong[c]), const SizedBox(width: 18), Expanded(child: Text(l, style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800))), const Icon(Icons.volume_up, color: T.mute)])))));
      return ListView(padding: const EdgeInsets.all(16), children: [
        if (stage) const MiloStage(),
        const Center(child: Text('What shall we do?', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800))), const SizedBox(height: 8),
        big(Icons.menu_book_outlined, 'Learn', 0, () => openScreen('learn')), big(Icons.chat_bubble_outline, 'Say', 1, () => openScreen('express')), big(Icons.check_circle_outline, 'Do', 3, () => openScreen('do')),
        big(Icons.settings_outlined, 'Settings', 2, () => ref.read(tabProvider.notifier).state = 4), // plan 7.9: Settings by pictogram in pre-reader mode
        Row(children: [Expanded(child: FilledButton(style: FilledButton.styleFrom(backgroundColor: T.coral, minimumSize: const Size(0, 62)), onPressed: () => showHelpSheet(context, ref), child: const Text('Help me'))), const SizedBox(width: 10),
          Expanded(child: FilledButton.tonal(style: FilledButton.styleFrom(minimumSize: const Size(0, 62)), onPressed: () => openScreen('break'), child: const Text('Break')))]),
      ]);
    }
    return ListView(padding: const EdgeInsets.all(16), children: [
      if (discreet) ...[
        const Padding(padding: EdgeInsets.only(top: 8, bottom: 4), child: Text('Welcome back', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
        if (cont != null && !hideCont) ...[Text('Continue $cont?', style: const TextStyle(color: T.mute)), const SizedBox(height: 10),
          Row(children: [Expanded(child: FilledButton(onPressed: () => openScreen('do'), child: const Text('Continue'))), const SizedBox(width: 10), Expanded(child: OutlinedButton(onPressed: () => setState(() => hideCont = true), child: const Text('Not now')))])],
      ] else if (stage) ...[
        Align(alignment: Alignment.centerLeft, child: Speech(greet)),
        const MiloStage(),
        if (cont != null && !hideCont) Padding(padding: const EdgeInsets.only(bottom: 8), child: Material(color: T.pri, borderRadius: BorderRadius.circular(18), child: InkWell(borderRadius: BorderRadius.circular(18), onTap: () => openScreen('do'),
            child: Padding(padding: const EdgeInsets.all(16), child: Row(children: [Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Continue', style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)), Text(cont!, style: const TextStyle(color: Colors.white70, fontSize: 13))])), const Icon(Icons.play_arrow, color: Colors.white)]))))),
      ],
      const SizedBox(height: 6),
      RowCard(icon: Icons.menu_book_outlined, title: 'Understand', subtitle: discreet ? null : 'Read, listen, learn', onTap: () => openScreen('understand')),
      RowCard(icon: Icons.chat_bubble_outline, title: 'Express', subtitle: discreet ? null : 'Talk, type, communicate', color: 1, onTap: () => openScreen('express')),
      RowCard(icon: Icons.check_circle_outline, title: 'Do things', subtitle: discreet ? null : 'Plan, organise, get it done', color: 3, onTap: () => openScreen('do')),
      if (discreet) Card(child: SwitchListTile(secondary: const Icon(Icons.nightlight_round, color: T.pri), title: const Text('Quiet presence', style: TextStyle(fontWeight: FontWeight.w700)), subtitle: const Text('Small Milo. Neutral palette. No baby talk.\nNo unsolicited praise or nudges.', style: TextStyle(fontSize: 12)), value: d.quiet, onChanged: (v) => d.set(() => d.quiet = v))),
    ]);
  }
}
