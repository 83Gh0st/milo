import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import '../net/api.dart';
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
    // Scrollable: the fixed column overflowed 360x640 (a real phone size) by
    // ~100 px. No Spacer inside (unbounded height forbids flex).
    return MiloScreen(title: 'Word builder', kind: 'learn', body: SingleChildScrollView(padding: const EdgeInsets.all(20), child: Column(children: [
      Container(height: 150, width: 170, decoration: BoxDecoration(color: T.mintSoft, borderRadius: BorderRadius.circular(22)), alignment: Alignment.center, child: Text(all[w].$2, style: const TextStyle(fontSize: 72))),
      const SizedBox(height: 22),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (var i = 0; i < target.length; i++) Container(margin: const EdgeInsets.all(4), width: 56, height: 62, alignment: Alignment.center, decoration: BoxDecoration(color: i < filled ? T.priSoft : Colors.white, borderRadius: BorderRadius.circular(14), border: Border.all(color: T.pri, width: 2)), child: Text(i < filled ? target[i].toUpperCase() : '', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800)))]),
      const SizedBox(height: 22),
      Wrap(alignment: WrapAlignment.center, children: [for (var i = 0; i < letters.length; i++) AnimatedRotation(turns: tilt == i ? .03 : 0, duration: const Duration(milliseconds: 120), child: Opacity(opacity: used[i] ? .25 : 1, child: Container(margin: const EdgeInsets.all(5), child: Material(color: T.pri, borderRadius: BorderRadius.circular(14), child: InkWell(borderRadius: BorderRadius.circular(14), onTap: () => _tap(i), child: SizedBox(width: 58, height: 62, child: Center(child: Text(letters[i].toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 28, fontWeight: FontWeight.w800)))))))))]),
      IconButton(iconSize: 36, tooltip: 'Hear the word', onPressed: () => d.speak(target), icon: const Icon(Icons.volume_up, color: T.pri)),
      TextButton.icon(icon: const Icon(Icons.auto_awesome, size: 18), label: Text('What does “$target” mean?', style: const TextStyle(fontSize: 15)),
          onPressed: () { ref.read(lookupWordProvider.notifier).state = target; openScreen('understand'); }),
      const SizedBox(height: 18),
      Row(children: [Expanded(child: BigButton('Hint', () { final n = target[filled < target.length ? filled : 0]; final i = letters.indexWhere((l) => l == n) ; if (i >= 0) { setState(() => tilt = -1); d.speak('Try the letter $n'); } }, kind: BK.soft)), const SizedBox(width: 12),
        Expanded(child: BigButton(done ? 'Next word' : 'Check', done ? () async { d.celebrate(); await ref.read(dbProvider).progress('word'); _next(); } : () => d.speak(filled == 0 ? 'Let us start with the first sound.' : 'Nearly there.')))]),
      const SizedBox(height: 8), const Text('No timer. No lives. Unlimited hints.', style: TextStyle(fontSize: 12, color: T.mute)), const SizedBox(height: 90),
    ])));
  }
}

const _themes = ['Animals', 'Bedtime', 'Space', 'Sea', 'Forest', 'Kindness'];
const _lengths = [('short', 'Short'), ('medium', 'Medium'), ('long', 'Long')];

/// Story time: a fresh tale generated for the child on every ask (gateway
/// /v1/story), never the same pages twice; saved tales live ONLY on this
/// device (local.stories never syncs). No connection → a plain message.
class StoryTime extends ConsumerStatefulWidget { const StoryTime({super.key}); @override ConsumerState<StoryTime> createState() => _StoryState(); }
class _StoryState extends ConsumerState<StoryTime> {
  final theme = TextEditingController(), chars = TextEditingController(), setting = TextEditingController(), q = TextEditingController();
  String length = 'short', err = '', answer = '';
  Story? tale;
  int page = 0;
  bool busy = false, artBusy = false, askOpen = false, justSaved = false;
  List<Map<String, dynamic>> saved = [];
  final art = <int, Uint8List>{};
  @override
  void initState() { super.initState(); _loadSaved(); }
  @override
  void dispose() { theme.dispose(); chars.dispose(); setting.dispose(); q.dispose(); super.dispose(); }

  Future<void> _loadSaved() async {
    try {
      final raw = await ref.read(dbProvider).get('local.stories');
      final list = raw == null ? [] : (jsonDecode(raw) as List);
      if (mounted) setState(() => saved = [for (final e in list) if (e is Map) Map<String, dynamic>.from(e)]);
    } catch (_) {}
  }

  Future<void> _storeSaved() => ref.read(dbProvider).put('local.stories', jsonEncode(saved.take(20).toList()));

  String _words(Object e) {
    if (e is CloudDisabled) return 'Stories need Milo\u2019s internet. A grown-up can switch it on in More \u00b7 Internet.';
    if (e is! ApiError) return 'Something went wrong. Please try again.';
    if (e.code == 'offline' || e.code == 'timeout') return 'Stories need the internet. Please try again when you are back online.';
    if (e.code == 'http_429' || e.code == 'budget_exhausted') return 'Milo is resting now. Please try again later.';
    if (e.detail?['error'] == 'crisis') return 'Let\u2019s pick a happier idea for our story.';
    if (e.code == 'bad_story') return 'That tale got tangled. Please try again.';
    return 'Something went wrong. Please try again.';
  }

  List<Map<String, String>> get _sent => [for (final p in tale?.pages ?? <StoryPage>[]) p.toJson()];

  Future<void> _new() async {
    final d = ref.read(directorProvider);
    setState(() { busy = true; err = ''; answer = ''; askOpen = false; art.clear(); justSaved = false; });
    try {
      final who = chars.text.split(',').map((c) => c.trim()).where((c) => c.isNotEmpty).take(4).toList();
      final s = await ref.read(apiProvider).story(theme: theme.text.trim(), characters: who, setting: setting.text.trim(),
          length: length, presentation: d.profile.name, lang: d.lang);
      if (!mounted) return;
      setState(() { tale = s; page = 0; });
    } catch (e) { if (mounted) setState(() => err = _words(e)); } finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> _more(String mode) async {
    final d = ref.read(directorProvider), t = tale;
    if (t == null) return;
    setState(() { busy = true; err = ''; });
    try {
      final s = await ref.read(apiProvider).story(mode: mode, pages: _sent, presentation: d.profile.name, lang: d.lang);
      if (!mounted) return;
      setState(() { tale = Story(title: t.title, pages: [...t.pages, ...s.pages].take(9).toList(), toldBy: s.toldBy); page = t.pages.length.clamp(0, 8); });
    } catch (e) { if (mounted) setState(() => err = _words(e)); } finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> _ask() async {
    final d = ref.read(directorProvider);
    if (q.text.trim().length < 2) return;
    setState(() { busy = true; err = ''; });
    try {
      final a = await ref.read(apiProvider).storyAnswer(pages: _sent, question: q.text.trim(), presentation: d.profile.name, lang: d.lang);
      if (mounted) setState(() => answer = a);
    } catch (e) { if (mounted) setState(() => err = _words(e)); } finally { if (mounted) setState(() => busy = false); }
  }

  Future<void> _draw() async {
    final t = tale;
    if (t == null || page >= t.pages.length) return;
    setState(() { artBusy = true; err = ''; });
    try {
      // Keep the prompt inside the gateway's screened-prompt budget even for
      // long pages (the gateway truncates too; this keeps intent intact).
      final moment = t.pages[page].text.length > 180 ? t.pages[page].text.substring(0, 180) : t.pages[page].text;
      final pic = await ref.read(apiProvider).generateImage('A gentle picture-book illustration for this story moment: $moment');
      if (mounted) setState(() => art[page] = pic);
    } catch (_) { if (mounted) setState(() => err = 'The picture could not be drawn. The story still works.'); } finally { if (mounted) setState(() => artBusy = false); }
  }

  Future<void> _save() async {
    final t = tale;
    if (t == null) return;
    saved.removeWhere((e) => e['title'] == t.title && (e['pages'] as List?)?.length == t.pages.length);
    saved.insert(0, {'title': t.title, 'pages': [for (final p in t.pages) p.toJson()], 'told_by': t.toldBy, 'ts': DateTime.now().millisecondsSinceEpoch});
    await _storeSaved();
    if (mounted) setState(() => justSaved = true);
  }

  void _open(Map<String, dynamic> e) {
    try {
      final tb = e['told_by'];
      setState(() {
        tale = Story(title: '${e['title'] ?? 'Saved tale'}', pages: [for (final p in (e['pages'] as List? ?? [])) if (p is Map) StoryPage('${p['heading'] ?? ''}', '${p['text'] ?? ''}')],
            toldBy: tb is Map ? {'provider': '${tb['provider'] ?? ''}', 'model': '${tb['model'] ?? ''}'} : const {'provider': '', 'model': ''});
        page = 0; art.clear(); answer = ''; askOpen = false; err = ''; justSaved = false;
      });
    } catch (_) { setState(() => err = 'That saved tale could not be opened.'); }
  }

  @override
  Widget build(BuildContext context) => tale == null ? _setup() : _reading();

  Widget _field(TextEditingController c, String hint) => Padding(padding: const EdgeInsets.only(top: 8),
      child: TextField(controller: c, textCapitalization: TextCapitalization.sentences, decoration: InputDecoration(hintText: hint, border: const OutlineInputBorder(), isDense: true)));

  Widget _setup() => MiloScreen(title: 'Story time', kind: 'learn', body: ListView(padding: const EdgeInsets.all(16), children: [
    const Text('What shall the story be about?', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
    Wrap(spacing: 8, children: [for (final t in _themes) ActionChip(label: Text(t), onPressed: () => setState(() => theme.text = t))]),
    _field(theme, 'e.g. a brave little duck'), _field(chars, 'Who is in it? e.g. Milo, Pip'), _field(setting, 'Where? e.g. the beach'),
    const SizedBox(height: 10), const Text('How long?', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
    Wrap(spacing: 8, children: [for (final l in _lengths) ChoiceChip(label: Text(l.$2), selected: length == l.$1, onSelected: (_) => setState(() => length = l.$1))]),
    const SizedBox(height: 12),
    if (busy) const Padding(padding: EdgeInsets.all(20), child: LinearProgressIndicator()) else BigButton('Tell me a story', _new),
    if (err.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(err, style: const TextStyle(color: T.coral))),
    const Section('My saved stories (this device only)'),
    if (saved.isEmpty) const Text('No saved tales yet.', style: TextStyle(color: T.mute)),
    for (var i = 0; i < saved.length; i++)
      Card(child: ListTile(title: Text('${saved[i]['title'] ?? 'Tale'}', style: const TextStyle(fontWeight: FontWeight.w800)),
          subtitle: Text('${((saved[i]['pages'] as List?) ?? []).length} pages \u00b7 Told by ${toldByLabel(Map<String, String>.from((saved[i]['told_by'] as Map?) ?? {}))}'),
          onTap: () => _open(saved[i]),
          trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () async { saved.removeAt(i); await _storeSaved(); setState(() {}); }))),
    const SizedBox(height: 90),
  ]));

  Widget _reading() {
    final d = ref.read(directorProvider), t = tale!, p = page < t.pages.length ? t.pages[page] : null, last = page >= t.pages.length - 1, pic = art[page];
    return MiloScreen(title: 'Story time', kind: 'learn', onBack: () => setState(() => tale = null),
        trailing: Center(child: Padding(padding: const EdgeInsets.only(right: 8), child: Text('${min(page + 1, t.pages.length)}/${t.pages.length}'))),
        body: ListView(padding: const EdgeInsets.all(20), children: [
      Container(height: 170, width: double.infinity, decoration: BoxDecoration(color: T.mintSoft, borderRadius: BorderRadius.circular(22)),
          alignment: Alignment.center, child: pic != null ? ClipRRect(borderRadius: BorderRadius.circular(22), child: Image.memory(pic, height: 170, width: double.infinity, fit: BoxFit.cover, errorBuilder: (_, __, ___) => const Text('\u{1F4D6}', style: TextStyle(fontSize: 80))))
              : const Text('\u{1F4D6}', style: TextStyle(fontSize: 80))),
      if (pic != null) const Padding(padding: EdgeInsets.only(top: 4), child: Text('Drawn by AI for this story', style: TextStyle(fontSize: 12, color: T.mute), textAlign: TextAlign.center)),
      const SizedBox(height: 6),
      if (pic == null) (artBusy ? const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()) : BigButton('Draw a picture', _draw, kind: BK.soft)),
      const SizedBox(height: 8), Text(t.title.isEmpty ? 'Our story' : t.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800), textAlign: TextAlign.center),
      Text('Told by ${toldByLabel(t.toldBy)}', style: const TextStyle(fontSize: 12, color: T.mute), textAlign: TextAlign.center), const SizedBox(height: 10),
      if (p != null) ...[if (p.heading.isNotEmpty) Text(p.heading, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800), textAlign: TextAlign.center),
        Text(p.text, style: TextStyle(fontSize: 21, height: d.lineSpacing), textAlign: TextAlign.center)],
      const SizedBox(height: 12),
      if (busy) const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator()),
      if (err.isNotEmpty) Text(err, style: const TextStyle(color: T.coral), textAlign: TextAlign.center),
      Row(children: [
        Expanded(child: BigButton('Listen', p == null ? null : () => d.speak(p.text), kind: BK.soft)), const SizedBox(width: 12),
        Expanded(child: BigButton('Back', page == 0 ? null : () => setState(() => page--), kind: BK.outline)), const SizedBox(width: 12),
        Expanded(child: BigButton('Next', last ? null : () => setState(() => page++))),
      ]),
      if (last) ...[
        const SizedBox(height: 10),
        Row(children: [Expanded(child: BigButton('Keep going', busy ? null : () => _more('continue'), kind: BK.soft)), const SizedBox(width: 12),
          Expanded(child: BigButton('Finish it', busy ? null : () => _more('ending'), kind: BK.soft))]),
        const SizedBox(height: 10),
        BigButton(askOpen ? 'Hide questions' : 'Ask about it', () => setState(() => askOpen = !askOpen), kind: BK.outline),
        if (askOpen) ...[_field(q, 'e.g. Who is Pip?'),
          Padding(padding: const EdgeInsets.only(top: 8), child: BigButton('Ask', busy ? null : _ask)),
          if (answer.isNotEmpty) Container(margin: const EdgeInsets.only(top: 8), padding: const EdgeInsets.all(14), width: double.infinity,
              decoration: BoxDecoration(color: T.amberSoft, borderRadius: BorderRadius.circular(18)), child: Text(answer, style: const TextStyle(fontSize: 18)))],
        const SizedBox(height: 10),
        Row(children: [Expanded(child: BigButton(justSaved ? 'Saved \u2713' : 'Save', justSaved ? null : _save, kind: BK.mint)), const SizedBox(width: 12),
          Expanded(child: BigButton('New story', () => setState(() { tale = null; }), kind: BK.outline))]),
        const SizedBox(height: 10),
        BigButton('Finish', () async { await _save(); await ref.read(dbProvider).progress('read'); d.celebrate(goal: true); if (context.mounted) Navigator.pop(context); }, kind: BK.coral),
      ],
      const SizedBox(height: 90),
    ]));
  }
}
