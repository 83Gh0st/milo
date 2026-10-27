import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../companion/milo_view.dart';
import '../core/providers.dart';
import 'screen.dart';
import 'theme.dart';

/// Progress without pressure: days together, milestones, no levels, no streaks, no loss states (wireframe 8.x).
class ProgressScreen extends ConsumerStatefulWidget { const ProgressScreen({super.key}); @override ConsumerState<ProgressScreen> createState() => _PState(); }
class _PState extends ConsumerState<ProgressScreen> {
  int tab = 0;
  Future<Map<String, Object>> _load() async {
    final db = ref.read(dbProvider);
    final week = await db.db.rawQuery("SELECT strftime('%w', ts/1000, 'unixepoch', 'localtime') d, COUNT(*) c FROM progress_events WHERE ts>? GROUP BY d", [DateTime.now().millisecondsSinceEpoch - 7 * 86400000]);
    return {'days': await db.daysTogether(), 'c': await db.counts(days: 3650), 'on': await db.flag('progress.enabled', def: true), 'week': {for (final r in week) int.parse('${r['d']}'): r['c'] as int}};
  }
  @override
  Widget build(BuildContext context) {
    ref.listen<int>(tabProvider, (_, n) { if (n == 3) setState(() {}); });
    return FutureBuilder<Map<String, Object>>(future: _load(), builder: (_, s) {
      if (!s.hasData) return const SizedBox();
      final days = s.data!['days'] as int, c = s.data!['c'] as Map<String, int>, on = s.data!['on'] as bool, week = s.data!['week'] as Map<int, int>;
      final order = [1, 2, 3, 4, 5, 6, 0], mx = [1, ...week.values].reduce((a, b) => a > b ? a : b), today = DateTime.now().weekday % 7;
      Widget stat(int n, String l, int col) => Expanded(child: Container(margin: const EdgeInsets.all(4), padding: const EdgeInsets.symmetric(vertical: 14), decoration: BoxDecoration(color: T.soft[col], borderRadius: BorderRadius.circular(18)),
          child: Column(children: [Text('$n', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: T.strong[col])), Text(l, style: const TextStyle(fontWeight: FontWeight.w700))])));
      return ListView(padding: const EdgeInsets.all(16), children: [
        const ScreenHeader('Your progress'),
        PillTabs(const ['Learning', 'Speaking', 'Tasks'], tab, (i) => setState(() => tab = i)),
        const SizedBox(height: 10),
        if (!on) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Progress is turned off.', style: TextStyle(fontSize: 17))))
        else ...[
          Card(child: Padding(padding: const EdgeInsets.all(14), child: Row(children: [const SizedBox(width: 64, height: 64, child: MiloView()), const SizedBox(width: 12),
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('$days days together', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)), const Text('Never resets. Never lost.', style: TextStyle(color: T.mute))])]))),
          Row(children: tab == 0 ? [stat(c['read'] ?? 0, 'Stories', 0), stat(c['word'] ?? 0, 'Words', 3), stat(c['step'] ?? 0, 'Steps', 1)] : tab == 1 ? [stat(c['spoken'] ?? 0, 'Messages', 0), stat(c['message'] ?? 0, 'Chats', 3), stat(c['help'] ?? 0, 'Asked for help', 1)] : [stat(c['step'] ?? 0, 'Steps', 0), stat(c['task'] ?? 0, 'Plans done', 3), stat(c['help'] ?? 0, 'Asked for help', 1)]),
          const Section('This week'),
          SizedBox(height: 120, child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [for (final d in order) Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
            Container(margin: const EdgeInsets.symmetric(horizontal: 6), height: 12 + 80 * ((week[d] ?? 0) / mx), decoration: BoxDecoration(color: d == today ? T.pri : T.priSoft, borderRadius: BorderRadius.circular(8))),
            const SizedBox(height: 4), Text(const ['S', 'M', 'T', 'W', 'T', 'F', 'S'][d], style: const TextStyle(fontSize: 12, color: T.mute))]))])),
          RowCard(icon: Icons.timeline, title: 'Reading journey', subtitle: 'Milestones, not levels', onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ReadingJourney(c)))),
          RowCard(icon: Icons.emoji_events_outlined, title: 'Achievements', subtitle: 'Effort and character', color: 2, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => Achievements(c, days)))),
          RowCard(icon: Icons.spa_outlined, title: 'Milo is growing', subtitle: 'Seed to bloom, no pressure', color: 3, onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => Growth(days)))),
        ],
        const SizedBox(height: 120),
      ]);
    });
  }
}

class ReadingJourney extends StatelessWidget {
  const ReadingJourney(this.c, {super.key});
  final Map<String, int> c;
  @override
  Widget build(BuildContext context) {
    final steps = [('First story read', (c['read'] ?? 0) >= 1), ('5 new words', (c['word'] ?? 0) >= 5), ('First quick check', (c['check'] ?? 0) >= 1), ('Read 5 stories', (c['read'] ?? 0) >= 5), ('20 new words', (c['word'] ?? 0) >= 20)];
    final next = steps.indexWhere((s) => !s.$2);
    return MiloScreen(title: 'Reading journey', body: ListView(padding: const EdgeInsets.all(20), children: [
      for (var i = 0; i < steps.length; i++) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Row(children: [
        Container(width: 36, height: 36, decoration: BoxDecoration(shape: BoxShape.circle, color: steps[i].$2 ? T.mint : (i == next ? T.priSoft : T.line)), child: Icon(steps[i].$2 ? Icons.check : (i == next ? Icons.arrow_forward : Icons.circle_outlined), color: steps[i].$2 ? Colors.white : T.pri, size: 20)),
        const SizedBox(width: 14), Expanded(child: Container(padding: const EdgeInsets.all(14), decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), border: Border.all(color: steps[i].$2 ? T.mint : (i == next ? T.pri : T.line))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(steps[i].$1, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)), Text(steps[i].$2 ? 'Done' : (i == next ? 'In progress' : 'Not yet'), style: const TextStyle(fontSize: 12, color: T.mute))])))])),
    ]));
  }
}

class Achievements extends StatelessWidget {
  const Achievements(this.c, this.days, {super.key});
  final Map<String, int> c;
  final int days;
  @override
  Widget build(BuildContext context) {
    final a = [('Brave', Icons.flag, T.coral, (c['spoken'] ?? 0) >= 1), ('Curious', Icons.visibility, T.pri, (c['read'] ?? 0) >= 1), ('Focused', Icons.timer_outlined, T.mint, (c['task'] ?? 0) >= 1), ('Kind', Icons.favorite, T.amber, days >= 3),
      ('Asked for help', Icons.my_location, T.pri, (c['help'] ?? 0) >= 1), ('Tried again', Icons.auto_awesome, T.mute, (c['step'] ?? 0) >= 5)];
    return MiloScreen(title: 'Achievements', body: ListView(padding: const EdgeInsets.all(16), children: [
      GridView.count(crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: 1.05, children: [
        for (final x in a) Card(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [CircleAvatar(radius: 32, backgroundColor: x.$4 ? x.$3 : T.priSoft, child: Icon(x.$2, color: x.$4 ? Colors.white : T.mute, size: 30)), const SizedBox(height: 8), Text(x.$1, style: TextStyle(fontWeight: FontWeight.w800, color: x.$4 ? T.ink : T.mute))]))]),
      const SizedBox(height: 14), const Center(child: Text('Rewards effort and character. Asking for help is a strength.', textAlign: TextAlign.center, style: TextStyle(color: T.mute))),
    ]));
  }
}

class Growth extends ConsumerWidget {
  const Growth(this.days, {super.key});
  final int days;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final stage = days >= 30 ? 4 : days >= 14 ? 3 : days >= 7 ? 2 : days >= 2 ? 1 : 0;
    return MiloScreen(title: 'Milo is growing', noHeader: false, body: ListView(padding: const EdgeInsets.all(20), children: [
      const SizedBox(height: 240, child: MiloView()),
      Row(children: [for (var i = 0; i < 5; i++) ...[Column(children: [Container(width: 22, height: 22, decoration: BoxDecoration(shape: BoxShape.circle, color: i <= stage ? T.mint : T.line)), const SizedBox(height: 4), Text(const ['Seed', 'Sprout', 'Leaves', 'Bud', 'Bloom'][i], style: TextStyle(fontSize: 11, fontWeight: i == stage ? FontWeight.w800 : FontWeight.w500))]), if (i < 4) Expanded(child: Container(height: 3, color: i < stage ? T.mint : T.line))]]),
      const Section('Milo’s wardrobe (you choose)'),
      Row(children: [for (final i in [Icons.person_outline, Icons.auto_awesome, Icons.favorite_border, Icons.nightlight_outlined]) Expanded(child: Container(margin: const EdgeInsets.all(4), height: 64, decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: T.line)), child: Icon(i, color: T.pri)))]),
      Container(margin: const EdgeInsets.only(top: 14), padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: T.mintSoft, borderRadius: BorderRadius.circular(16)), child: const Text('Milo never wilts when you are away.\nCosmetics are chosen, not locked.', style: TextStyle(fontWeight: FontWeight.w700))),
    ]));
  }
}
