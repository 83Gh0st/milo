import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../companion/milo_view.dart';
import '../core/providers.dart';
import 'screen.dart';
import 'theme.dart';

/// Validates `assets/learn/words.json` (a list, or {"words": [...]}, of
/// {word, emoji}). Anything malformed is skipped; never throws.
List<(String, String)> parseLearnWords(String raw) {
  final out = <(String, String)>[];
  try {
    final j = jsonDecode(raw);
    final list = j is List ? j : (j is Map ? j['words'] : null);
    if (list is! List) return out;
    final seen = <String>{};
    for (final e in list) {
      if (e is! Map) continue;
      final w = '${e['word'] ?? ''}'.trim().toLowerCase(), em = '${e['emoji'] ?? ''}'.trim();
      if (!RegExp(r'^[a-z]{2,12}$').hasMatch(w) || em.isEmpty || em.length > 8 || !seen.add(w)) continue;
      out.add((w, em));
      if (out.length >= 60) break;
    }
  } catch (_) {}
  return out;
}

/// Learn (wireframe 5.x): bundled content, fully offline, no timer, no lives, no streaks, unlimited hints.
class LearnScreen extends ConsumerStatefulWidget { const LearnScreen({super.key}); @override ConsumerState<LearnScreen> createState() => _LearnState(); }
class _LearnState extends ConsumerState<LearnScreen> {
  @override
  Widget build(BuildContext context) {
    final db = ref.read(dbProvider);
    return MiloScreen(title: 'My learning journey', body: FutureBuilder(future: Future.wait([db.counts(days: 3650), db.get('goals')]), builder: (_, s) {
      final c = (s.data?[0] ?? <String, int>{}) as Map<String, int>, goals = ((s.data?[1] as String?) ?? '');
      Widget goal(String t, String sub, int n, int of, int col) => Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text(t, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800))), Icon(Icons.flag, color: T.strong[col])]), Text(sub, style: const TextStyle(fontSize: 12, color: T.mute)), const SizedBox(height: 8),
        ClipRRect(borderRadius: BorderRadius.circular(6), child: LinearProgressIndicator(value: (n / of).clamp(0.0, 1.0).toDouble(), minHeight: 8, color: T.strong[col], backgroundColor: T.line))])));
      return ListView(padding: const EdgeInsets.all(16), children: [
        goal('Read a story', '${min(c['read'] ?? 0, 5)} of 5 stories', c['read'] ?? 0, 5, 0), goal('Reading fluency', 'Practise aloud', c['read'] ?? 0, 10, 3),
        goal('Vocabulary', '${c['word'] ?? 0} words learned', c['word'] ?? 0, 20, 1), goal('Comprehension', 'Quick checks', c['check'] ?? 0, 10, 2),
        Container(margin: const EdgeInsets.symmetric(vertical: 8), padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: T.priSoft, borderRadius: BorderRadius.circular(18)), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Next goal (you chose it)', style: TextStyle(fontSize: 12, color: T.mute)), Text(goals.isEmpty ? 'Pick a goal in My profile' : goals.split(',').first, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))])),
        BigButton('Games', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const WordBuilder()))), const SizedBox(height: 10),
        BigButton('Story time', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const StoryTime())), kind: BK.soft),
      ]);
    }));
  }
}

const _words = [('tree', '🌳'), ('moon', '🌙'), ('fish', '🐟'), ('apple', '🍎'), ('ocean', '🌊'), ('house', '🏠')];

class WordBuilder extends ConsumerStatefulWidget { const WordBuilder({super.key}); @override ConsumerState<WordBuilder> createState() => _WBState(); }
class _WBState extends ConsumerState<WordBuilder> {
  int w = 0, filled = 0, tilt = -1;
  List<(String, String)> all = List.of(_words); // bundled words plus validated JSON extras
  late List<String> letters = _shuffle();
  late List<bool> used = List.filled(letters.length, false);
  @override
  void initState() {
    super.initState();
    rootBundle.loadString('assets/learn/words.json').then((raw) {
      final extra = [for (final e in parseLearnWords(raw)) if (!all.any((a) => a.$1 == e.$1)) e];
      if (extra.isNotEmpty && mounted) setState(() => all = [...all, ...extra]);
    }).catchError((_) {});
  }
  List<String> _shuffle() => (all[w].$1.split('')..shuffle(Random()));
  void _next() { setState(() { w = (w + 1) % all.length; filled = 0; letters = _shuffle(); used = List.filled(letters.length, false); }); }

  void _tap(int i) {
    final d = ref.read(directorProvider), target = all[w].$1;
    if (used[i]) return;
    if (letters[i] == target[filled]) { setState(() { used[i] = true; filled++; }); d.speak(letters[i]); d.emote('happy', i: .7, hold: 2); } // cheer the tile
    else { setState(() => tilt = i); d.gesture('shrug', force: true); Future.delayed(const Duration(milliseconds: 400), () { if (mounted) setState(() => tilt = -1); }); } // tilts when it does not fit
  }
  @override
  Widget build(BuildContext context) {
    final d = ref.read(directorProvider), target = all[w].$1, done = filled == target.length;
    return MiloScreen(title: 'Word builder', kind: 'learn', body: Padding(padding: const EdgeInsets.all(20), child: Column(children: [
      Container(height: 150, width: 170, decoration: BoxDecoration(color: T.mintSoft, borderRadius: BorderRadius.circular(22)), alignment: Alignment.center, child: Text(all[w].$2, style: const TextStyle(fontSize: 72))),
      const SizedBox(height: 22),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (var i = 0; i < target.length; i++) Container(margin: const EdgeInsets.all(4), width: 56, height: 62, alignment: Alignment.center, decoration: BoxDecoration(color: i < filled ? T.priSoft : Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: T.pri, width: 2)), child: Text(i < filled ? target[i].toUpperCase() : '', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)))]),
      const SizedBox(height: 22),
      Wrap(alignment: WrapAlignment.center, children: [for (var i = 0; i < letters.length; i++) AnimatedRotation(turns: tilt == i ? .03 : 0, duration: const Duration(milliseconds: 120), child: Opacity(opacity: used[i] ? .25 : 1, child: Container(margin: const EdgeInsets.all(5), child: Material(color: T.pri, borderRadius: BorderRadius.circular(14), child: InkWell(borderRadius: BorderRadius.circular(14), onTap: () => _tap(i), child: SizedBox(width: 58, height: 62, child: Center(child: Text(letters[i].toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)))))))))]),
      IconButton(iconSize: 36, tooltip: 'Hear the word', onPressed: () => d.speak(target), icon: const Icon(Icons.volume_up, color: T.pri)),
      const Spacer(),
      Row(children: [Expanded(child: BigButton('Hint', () { final n = target[filled < target.length ? filled : 0]; final i = letters.indexWhere((l) => l == n) ; if (i >= 0) { setState(() => tilt = -1); d.speak('Try the letter $n'); } }, kind: BK.soft)), const SizedBox(width: 12),
        Expanded(child: BigButton(done ? 'Next word' : 'Check', done ? () async { d.celebrate(); await ref.read(dbProvider).progress('word'); _next(); } : () => d.speak(filled == 0 ? 'Let us start with the first sound.' : 'Nearly there.')))]),
      const SizedBox(height: 8), const Text('No timer. No lives. Unlimited hints.', style: TextStyle(fontSize: 12, color: T.mute)), const SizedBox(height: 90),
    ])));
  }
}

const _story = [
  ('🏝️', 'Mia the little explorer found a tiny boat on the beach.'),
  ('🌊', 'She sailed out across the blue water. The waves were small and gentle.'),
  ('🐚', 'Under the water she saw something shiny. She reached down and picked it up.'),
];

class StoryTime extends ConsumerStatefulWidget { const StoryTime({super.key}); @override ConsumerState<StoryTime> createState() => _StoryState(); }
class _StoryState extends ConsumerState<StoryTime> {
  int page = 0;
  bool asked = false;
  @override
  Widget build(BuildContext context) {
    final d = ref.read(directorProvider), p = page < _story.length ? _story[page] : null;
    return MiloScreen(title: 'Story time', kind: 'learn', trailing: Center(child: Padding(padding: const EdgeInsets.only(right: 8), child: Text('${min(page + 1, _story.length)}/${_story.length}'))), body: Padding(padding: const EdgeInsets.all(20), child: Column(children: [
      Container(height: 170, width: double.infinity, decoration: BoxDecoration(color: T.mintSoft, borderRadius: BorderRadius.circular(22)), alignment: Alignment.center, child: Text(p?.$1 ?? '🐚', style: const TextStyle(fontSize: 80))),
      const SizedBox(height: 14), const Text('The Little Explorer', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)), const SizedBox(height: 10),
      if (p != null) Text(p.$2, style: TextStyle(fontSize: 21, height: d.lineSpacing), textAlign: TextAlign.center)
      else Container(padding: const EdgeInsets.all(16), width: double.infinity, decoration: BoxDecoration(color: T.amberSoft, borderRadius: BorderRadius.circular(18)), child: Column(children: [
        const Text('What do you think she found?', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w800)), const Text('Say it, tap it, or skip.', style: TextStyle(color: T.mute)), const SizedBox(height: 10),
        Wrap(spacing: 8, children: [for (final a in ['A pearl', 'A map', 'A friend']) ActionChip(label: Text(a), onPressed: () { setState(() => asked = true); d.emote('encouraging', i: .8, hold: 3, force: true); d.speak('What a lovely idea!', tone: 'warm'); })])])),
      const Spacer(),
      Row(children: [Expanded(child: BigButton('Listen', () => d.speak(p?.$2 ?? 'What do you think she found?'), kind: BK.soft)), const SizedBox(width: 12), Expanded(child: BigButton(p == null ? 'Finish' : 'Next', () async {
        if (p != null) { setState(() => page++); } else { await ref.read(dbProvider).progress('read'); d.celebrate(goal: true); if (context.mounted) Navigator.pop(context); }
      }))]),
      const SizedBox(height: 90),
    ])));
  }
}
