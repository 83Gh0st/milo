import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import 'screen.dart';
import 'theme.dart';

// Fixed order: tile positions never move, so motor memory is preserved (wireframe 4.1).
const _grid = [(Icons.adjust, 'I want', 0), (Icons.favorite, 'I need', 1), (Icons.notifications_none, 'Help', 2), (Icons.restaurant, 'Food', 3), (Icons.wc, 'Toilet', 0), (Icons.healing, 'I’m hurt', 1), (Icons.check_circle_outline, 'Yes', 3), (Icons.radio_button_unchecked, 'No', 1)];
const _more = ['I', 'you', 'more', 'stop', 'go', 'like', 'not', 'water', 'play', 'home', 'school', 'please', 'thank you', 'again', 'finished'];
const _symbols = {'People': ['👩', '👨', '👧', '👦', '👵', '👴', '🧑‍⚕️', '🧑‍🏫'], 'Food': ['💧', '🍎', '🍞', '🥛', '🍚', '🍌', '🍪', '🍕'], 'Places': ['🏠', '🏫', '🏥', '🛒', '🌳', '🚌', '🚻', '🛏️'], 'Actions': ['🏃', '🍽️', '🛁', '🎮', '📖', '😴', '🎵', '🚶']};
const _base = ['I', 'want', 'to', 'go', 'the', 'water', 'food', 'help', 'more', 'please', 'bathroom', 'home', 'school', 'play', 'stop', 'yes', 'no', 'need', 'like', 'doctor', 'shop', 'park'];

class ExpressScreen extends ConsumerStatefulWidget { const ExpressScreen({super.key}); @override ConsumerState<ExpressScreen> createState() => _EState(); }

class _EState extends ConsumerState<ExpressScreen> {
  int tab = 0;
  List<String> strip = [], recent = [];
  List<List<String>> custom = [];
  String symCat = 'People';
  final kb = TextEditingController();

  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final db = ref.read(dbProvider);
    final t = await db.tiles(), r = await db.recentPhrases();
    if (mounted) setState(() { custom = [for (final x in t) ['${x['emoji']}', '${x['label']}']]; recent = r; });
  }
  void _add(String w) => setState(() { strip.add(w); kb.text = strip.join(' '); if (!ref.read(directorProvider).speaking) ref.read(directorProvider).gesture('nod', force: true); });

  Future<void> _speak(String text, {bool help = false, bool view = true}) async {
    final db = ref.read(dbProvider), d = ref.read(directorProvider);
    db.bumpPhrase(text); db.progress('spoken'); if (help) { db.progress('help'); }
    if (view) { await Navigator.push(context, MaterialPageRoute(builder: (_) => SpeakingView(text))); } else { d.speakAac(text); }
    _load();
  }
  List<String> _predict() {
    final w = kb.text.split(' ').last.toLowerCase();
    if (w.isEmpty) return ['shop', 'park', 'doctor'];
    final pool = {...recent.expand((r) => r.split(' ')), ..._base};
    return pool.where((x) => x.toLowerCase().startsWith(w) && x.toLowerCase() != w).take(3).toList();
  }

  @override
  Widget build(BuildContext context) {
    final ladder = ref.watch(ladderProvider);
    ref.listen<String>(expressTextProvider, (_, n) { if (n.isNotEmpty) { setState(() { strip = n.split(' '); kb.text = n; }); ref.read(expressTextProvider.notifier).state = ''; } });
    final text = strip.join(' ');
    Widget quick(String l, String s, {bool help = false}) => Expanded(child: TextButton(onPressed: () => _speak(s, help: help, view: false), child: Text(l, style: const TextStyle(color: T.coral, fontWeight: FontWeight.w800))));
    Widget body;
    if (tab == 0) {
      body = GridView.count(crossAxisCount: 3, padding: const EdgeInsets.fromLTRB(14, 4, 14, 4), mainAxisSpacing: 10, crossAxisSpacing: 10, childAspectRatio: .98, children: [
        for (final g in _grid) PastelTile(icon: g.$1, label: g.$2, color: g.$3, onTap: () => _add(g.$2.replaceAll('’', "'"))),
        PastelTile(icon: Icons.image_outlined, label: 'More', color: 2, onTap: () => showModalBottomSheet(context: context, builder: (_) => ListView(padding: const EdgeInsets.all(16), children: [Wrap(spacing: 8, runSpacing: 8, children: [for (final w in _more) ActionChip(label: Text(w, style: const TextStyle(fontSize: 18)), onPressed: () { Navigator.pop(context); _add(w); })]), const Divider(), Wrap(spacing: 8, runSpacing: 8, children: [for (final c in custom) ActionChip(avatar: Text(c[0]), label: Text(c[1], style: const TextStyle(fontSize: 18)), onPressed: () { Navigator.pop(context); _add(c[1]); })])]))),
      ]);
    } else if (tab == 1) {
      body = Column(children: [SizedBox(height: 46, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 10), children: [for (final k in _symbols.keys) Padding(padding: const EdgeInsets.all(4), child: ChoiceChip(label: Text(k), selected: symCat == k, onSelected: (_) => setState(() => symCat = k)))])),
        Expanded(child: GridView.count(crossAxisCount: 4, padding: const EdgeInsets.all(12), mainAxisSpacing: 8, crossAxisSpacing: 8, children: [for (var i = 0; i < _symbols[symCat]!.length; i++) PastelTile(icon: null, emoji: _symbols[symCat]![i], label: '', color: i, onTap: () => _add(const {'👩': 'woman', '👨': 'man', '👧': 'girl', '👦': 'boy', '👵': 'grandma', '👴': 'grandpa', '🧑‍⚕️': 'doctor', '🧑‍🏫': 'teacher', '💧': 'water', '🍎': 'apple', '🍞': 'bread', '🥛': 'milk', '🍚': 'rice', '🍌': 'banana', '🍪': 'biscuit', '🍕': 'pizza', '🏠': 'home', '🏫': 'school', '🏥': 'hospital', '🛒': 'shop', '🌳': 'park', '🚌': 'bus', '🚻': 'toilet', '🛏️': 'bed', '🏃': 'run', '🍽️': 'eat', '🛁': 'bath', '🎮': 'play', '📖': 'read', '😴': 'sleep', '🎵': 'music', '🚶': 'walk'}[_symbols[symCat]![i]] ?? 'it'))])),
        const Padding(padding: EdgeInsets.all(6), child: Text('Emoji symbols. ARASAAC pictograms can replace them (non-commercial licence).', style: TextStyle(fontSize: 11, color: T.mute)))]);
    } else {
      final pred = _predict();
      body = Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: kb, autofocus: true, maxLines: 3, style: const TextStyle(fontSize: 22), onChanged: (v) => setState(() => strip = v.split(' ').where((x) => x.isNotEmpty).toList()), decoration: const InputDecoration(hintText: 'Type a message')),
        const SizedBox(height: 10), Wrap(spacing: 8, children: [for (final p in pred) ActionChip(side: const BorderSide(color: T.pri), backgroundColor: Colors.white, label: Text(p, style: const TextStyle(fontSize: 18, color: T.pri, fontWeight: FontWeight.w700)), onPressed: () => setState(() { final parts = kb.text.split(' '); parts.last = p; kb.text = '${parts.join(' ')} '; strip = kb.text.split(' ').where((x) => x.isNotEmpty).toList(); }))]),
        const Padding(padding: EdgeInsets.all(8), child: Text('Word prediction runs on the phone.', style: TextStyle(fontSize: 12, color: T.mute)))]));
    }
    return MiloScreen(title: 'Communication', kind: 'express', trailing: Row(mainAxisSize: MainAxisSize.min, children: [IconButton(tooltip: 'Choose a voice', onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const VoiceChooser())), icon: const Icon(Icons.record_voice_over_outlined)), const SizedBox(width: 4)]), body: Column(children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: PillTabs(const ['Phrases', 'Symbols', 'Keyboard'], tab, (i) => setState(() => tab = i))),
      Container(margin: const EdgeInsets.fromLTRB(14, 10, 14, 6), padding: const EdgeInsets.fromLTRB(16, 8, 8, 8), decoration: BoxDecoration(color: T.priSoft, borderRadius: BorderRadius.circular(18)), child: Row(children: [
        Expanded(child: Text(text.isEmpty ? 'Tap pictures to build a message' : text, style: TextStyle(fontSize: 21, fontWeight: FontWeight.w700, color: text.isEmpty ? T.mute : T.ink))),
        if (text.isNotEmpty) IconButton(tooltip: 'Clear', onPressed: () => setState(() { strip = []; kb.clear(); }), icon: const Icon(Icons.close)),
        FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(88, 48)), onPressed: text.isEmpty ? null : () => _speak(text), child: const Text('Speak'))])), // never spoken until the person taps Speak
      if (ladder == Ladder.full && strip.length > 1) Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: Align(alignment: Alignment.centerLeft, child: TextButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ComposeScreen(strip))).then((v) { if (v is String) setState(() { strip = v.split(' '); kb.text = v; }); }), icon: const Icon(Icons.auto_awesome, size: 18), label: const Text('Say it better')))),
      Expanded(child: body),
      if (recent.isNotEmpty) SizedBox(height: 40, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [const Center(child: Text('Recent: ', style: TextStyle(color: T.mute, fontSize: 12))), for (final r in recent.take(5)) Padding(padding: const EdgeInsets.all(3), child: ActionChip(visualDensity: VisualDensity.compact, label: Text(r, style: const TextStyle(fontSize: 13)), onPressed: () => setState(() { strip = r.split(' '); kb.text = r; })))])),
      Container(margin: const EdgeInsets.fromLTRB(14, 4, 14, 4), decoration: BoxDecoration(color: T.coralSoft, borderRadius: BorderRadius.circular(16)), child: Row(children: [quick('Help', 'Help me please', help: true), quick('I need a break', 'I need a break'), quick('I’m hurt', 'I’m hurt', help: true)])),
      const Padding(padding: EdgeInsets.only(bottom: 6), child: Text('Tiles never move unless you move them.', style: TextStyle(fontSize: 11, color: T.mute))),
    ]));
  }
}

/// Wireframe 4.5: large text for the listener; the waveform follows the voice; Milo only breathes and blinks.
class SpeakingView extends ConsumerStatefulWidget { const SpeakingView(this.text, {super.key}); final String text; @override ConsumerState<SpeakingView> createState() => _SVState(); }
class _SVState extends ConsumerState<SpeakingView> {
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(directorProvider).speakAac(widget.text)); }
  @override
  Widget build(BuildContext context) {
    final d = ref.watch(directorProvider);
    return Scaffold(body: SafeArea(child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
      FutureBuilder<String?>(future: ref.read(dbProvider).get('name'), builder: (_, s) => Align(alignment: Alignment.centerLeft, child: Text('${(s.data ?? '').isEmpty ? 'I' : s.data} says', style: const TextStyle(color: T.mute)))),
      const Spacer(), Text(widget.text, textAlign: TextAlign.center, style: const TextStyle(fontSize: 44, fontWeight: FontWeight.w800, height: 1.15)), const SizedBox(height: 30),
      SizedBox(height: 70, child: AnimatedBuilder(animation: d.frame, builder: (_, __) => Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (var i = 0; i < 34; i++) Container(width: 6, margin: const EdgeInsets.symmetric(horizontal: 2), height: 8 + 56 * (d.speaking ? (.25 + .75 * (.5 + .5 * math.sin(d.clock * 9 + i * .9)).abs()) * (.4 + d.pulse * .6) : .05), decoration: BoxDecoration(color: T.pri, borderRadius: BorderRadius.circular(3)))]))),
      const Spacer(), Row(children: [Expanded(child: BigButton('Again', () => d.speakAac(widget.text), kind: BK.soft)), const SizedBox(width: 12), Expanded(child: BigButton('Done', () { d.cancelSpeech(); Navigator.pop(context); }))]),
      const Padding(padding: EdgeInsets.all(10), child: Text('Large text for the listener.', style: TextStyle(fontSize: 12, color: T.mute))),
    ]))));
  }
}

/// Wireframe 4.3: on request only; keeps the meaning, adds no facts, feelings or consent; always editable.
class ComposeScreen extends ConsumerStatefulWidget { const ComposeScreen(this.strip, {super.key}); final List<String> strip; @override ConsumerState<ComposeScreen> createState() => _CSState(); }
class _CSState extends ConsumerState<ComposeScreen> {
  List<String>? opts;
  String? err;
  @override
  void initState() { super.initState(); _go(); }
  Future<void> _go() async {
    final d = ref.read(directorProvider);
    try { final o = await ref.read(apiProvider).compose(widget.strip, d.profile.name, d.lang); if (mounted) setState(() => opts = o); } catch (_) { if (mounted) setState(() => err = 'Wording help needs the internet. Your board still speaks.'); }
  }
  @override
  Widget build(BuildContext context) {
    final d = ref.read(directorProvider);
    return MiloScreen(title: 'Say it better', kind: 'express', body: ListView(padding: const EdgeInsets.all(16), children: [
      Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: T.priSoft, borderRadius: BorderRadius.circular(18)), child: Text(widget.strip.join(' '), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800))),
      const Section('Milo suggests (you choose)'),
      if (opts == null && err == null) const Padding(padding: EdgeInsets.all(20), child: LinearProgressIndicator()),
      if (err != null) Text(err!, style: const TextStyle(color: T.coral)),
      for (final o in opts ?? <String>[]) Card(child: ListTile(title: Text(o, style: const TextStyle(fontSize: 18)), trailing: IconButton(icon: const Icon(Icons.play_arrow, color: T.pri), onPressed: () => d.speakAac(o)), onTap: () => Navigator.pop(context, o))),
      Container(margin: const EdgeInsets.only(top: 12), padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: T.amberSoft, borderRadius: BorderRadius.circular(16)), child: const Text('Keeps your meaning. Adds no facts, feelings, or consent. Always editable.')),
    ]));
  }
}

/// Wireframe 4.4: plays a sample; applies instantly and persists.
class VoiceChooser extends ConsumerWidget {
  const VoiceChooser({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    const items = [('Friendly', 'Milo (friendly)', 'Warm and bright'), ('Calm', 'Calm', 'Soft and slow'), ('Energetic', 'Energetic', 'Quick and playful'), ('Device', 'Device voice', 'This phone’s own voice')];
    return MiloScreen(title: 'Choose a voice', kind: 'express', body: ListView(padding: const EdgeInsets.all(16), children: [
      for (final i in items) Card(shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: BorderSide(color: d.voiceStyle == i.$1 ? T.pri : T.line, width: d.voiceStyle == i.$1 ? 2 : 1)), child: ListTile(leading: Icon(d.voiceStyle == i.$1 ? Icons.check_circle : Icons.circle_outlined, color: T.pri), title: Text(i.$2, style: const TextStyle(fontWeight: FontWeight.w800)), subtitle: Text(i.$3),
        trailing: const Icon(Icons.play_arrow, color: T.pri), onTap: () { d.set(() => d.voiceStyle = i.$1); d.applyVoice().then((_) => d.speakAac('I want water')); })),
      const Section('Speed'), Slider(value: d.voiceSpeed, min: .6, max: 1.4, onChanged: (v) => d.set(() => d.voiceSpeed = v)),
      const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Slower', style: TextStyle(fontSize: 12, color: T.mute)), Text('Faster', style: TextStyle(fontSize: 12, color: T.mute))]),
      const SizedBox(height: 16), BigButton('Done', () => Navigator.pop(context)),
    ]));
  }
}
