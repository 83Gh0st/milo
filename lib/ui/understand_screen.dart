import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';
import '../contracts/brain_contract.dart';
import '../core/payload.dart';
import '../core/providers.dart';
import '../media/photo.dart';
import 'screen.dart';
import 'theme.dart';

/// Approximate syllable split for the word popup (heuristic, English only).
String syllables(String word) {
  final s = word.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
  bool v(String c) => 'aeiouy'.contains(c);
  if (s.length < 4) return s;
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    out.write(s[i]);
    if (i + 2 < s.length && v(s[i])) {
      if (!v(s[i + 1]) && !v(s[i + 2]) && s.substring(i + 2).split('').any(v)) { out.write('·'); out.write(s[++i]); }
      else if (!v(s[i + 1]) && v(s[i + 2]) && i > 0) { out.write('·'); }
    }
  }
  return out.toString();
}

enum _S { bring, photo, reading, style, reader, check }

/// Understand (wireframes 3.1 to 3.6): bring something, Milo reads it, choose how, reading view, quick check.
class UnderstandScreen extends ConsumerStatefulWidget { const UnderstandScreen({super.key}); @override ConsumerState<UnderstandScreen> createState() => _UState(); }

class _UState extends ConsumerState<UnderstandScreen> {
  _S step = _S.bring;
  final c = TextEditingController();
  final ask = TextEditingController();
  List<String> words = [];
  List<GlobalKey> keys = [];
  List<Map<String, String>> recent = [];
  Uint8List? _image;
  int cur = -1, speedIdx = 1;
  bool focus = false, tint = false, remember = false;
  final styles = <String>{'Audio'};
  String? picked;
  static const _speeds = [.8, 1.0, 1.25];

  @override
  void initState() {
    super.initState();
    ref.read(dbProvider).get('local.recent').then((v) { try { if (v != null && v.isNotEmpty) setState(() => recent = [for (final r in jsonDecode(v) as List) {'t': '${r['t']}', 'x': '${r['x']}'}]); } catch (_) {} });
    // Deferred: setting notifier state during initState throws ("tried to
    // modify a provider while the widget tree was building").
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(understandProvider.notifier).start();
      ref.read(understandProvider.notifier).done();
    });
    // Brain highlight spans are 1-based word ids (w1 is the first word); the reader list is 0-based.
    ref.read(directorProvider).onHighlight = (span) {
      final n = int.tryParse(span.startsWith('w') ? span.substring(1) : span) ?? -1;
      if (mounted && n >= 1 && n <= words.length) setState(() => cur = n - 1);
    };
    // read_aloud(span): highlight the word and read from there to the end.
    ref.read(directorProvider).onReadAloud = (span) {
      final n = int.tryParse(span.startsWith('w') ? span.substring(1) : span) ?? -1;
      if (mounted && n >= 1 && n <= words.length) _listenFrom(n - 1);
    };
    // lookup_word: the brain sent a word here; use it once, then clear.
    final lookup = ref.read(lookupWordProvider);
    if (lookup.isNotEmpty) { ref.read(lookupWordProvider.notifier).state = ''; _image = null; WidgetsBinding.instance.addPostFrameCallback((_) => _use(lookup)); }
    // share-in (plan 7.13): text from another app lands the same way.
    final shared = ref.read(sharedTextProvider);
    if (lookup.isEmpty && shared.isNotEmpty) { ref.read(sharedTextProvider.notifier).state = ''; _image = null; WidgetsBinding.instance.addPostFrameCallback((_) => _use(shared)); }
  }
  void _prep() { words = RegExp(r'\S+').allMatches(c.text).map((m) => m.group(0)!).toList(); keys = List.generate(words.length, (_) => GlobalKey()); }
  Future<void> _remember() async {
    final t = c.text.trim(); if (t.isEmpty) return;
    recent = [{'t': t.split(' ').take(4).join(' '), 'x': t}, ...recent.where((r) => r['x'] != t)].take(5).toList();
    await ref.read(dbProvider).put('local.recent', jsonEncode(recent));
  }

  Future<void> _use(String text, {bool explain = true}) async {
    setState(() { c.text = text; _prep(); cur = -1; step = _S.reading; });
    await _remember();
    if (explain) { await _explain('default'); }
  }
  Future<void> _explain(String strategy) {
    ref.read(chipsProvider.notifier).put(ChipItem('document', 'You’re reading this now', _image != null ? '' : c.text));
    return ref.read(routerProvider).explain(ref.read(directorProvider), c.text, strategy: strategy, imageB64: _image == null ? null : base64Encode(_image!));
  }

  Future<void> _photo(ImageSource src) async {
    final x = await ImagePicker().pickImage(source: src, maxWidth: 2400);
    if (x == null) return;
    final jpg = await compute(preparePhoto, await x.readAsBytes());
    var ocr = '';
    try { final r = TextRecognizer(); ocr = (await r.processImage(InputImage.fromFilePath(x.path))).text; await r.close(); } catch (_) {} // quick on-device OCR keeps read-aloud working offline
    try { await File(x.path).delete(); } catch (_) {} // the original (with EXIF/GPS) never lingers in the app cache
    setState(() { _image = jpg; c.text = ocr.trim(); _prep(); step = _S.photo; });
  }
  Future<void> _file() async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: ['txt', 'md']);
    final p = f?.path; if (p == null) return;
    _image = null; await _use(await File(p).readAsString());
  }
  Future<void> _paste() async {
    final t = TextEditingController();
    final v = await showModalBottomSheet<String>(context: context, isScrollControlled: true, builder: (_) => Padding(padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MediaQuery.of(context).viewInsets.bottom), child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: t, maxLines: 6, autofocus: true, decoration: const InputDecoration(hintText: 'Paste or type text')), const SizedBox(height: 10), BigButton('Continue', () => Navigator.pop(context, t.text))])));
    if (v != null && v.trim().isNotEmpty) { _image = null; await _use(v); }
  }

  Future<void> _listen() => _listenFrom(0);

  Future<void> _listenFrom(int from) async {
    final d = ref.read(directorProvider);
    d.emote('curious', i: .7, hold: 60);
    await d.speak(words.skip(from).join(' '), rate: _speeds[speedIdx], onWord: (i) { // highlight follows the audio; Milo's eyes follow the highlight
      if (!mounted || from + i >= keys.length) return;
      setState(() => cur = from + i);
      final ro = keys[from + i].currentContext?.findRenderObject();
      if (ro is RenderBox && ro.attached) d.lookAtGlobal(ro.localToGlobal(ro.size.center(Offset.zero)));
    });
    if (mounted) setState(() => cur = -1);
    d.relax(); d.emote('proud', i: .5, hold: 2);
    await ref.read(dbProvider).progress('read');
  }

  VoidCallback? get _back => switch (step) { _S.bring => null, _S.photo => () => setState(() => step = _S.bring), _S.reading => () => setState(() => step = _S.bring), _S.style => () => setState(() => step = _S.reading), _S.reader => () => setState(() => step = _S.style), _S.check => () => setState(() => step = _S.reader) };

  /// First allow-listed concept in the vocabulary or text (vocabulary first).
  /// Returns null when nothing may be pictured, so no request is ever made.
  String? _concept() {
    final vocab = ref.read(understandProvider).vocab;
    for (final v in vocab) { final w = '${v['word']}'.toLowerCase().replaceAll(RegExp(r'[^a-z]'), ''); if (kVisualConcepts.contains(w)) return w; }
    return words.map((w) => w.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '')).where(kVisualConcepts.contains).firstOrNull;
  }

  Future<void> _keep() async {
    final t = c.text.trim();
    if (t.isEmpty) return;
    await ref.read(dbProvider).addDocument(t.split(RegExp(r'\s+')).take(5).join(' '), t);
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Kept. Find it under Saved.')));
  }

  @override
  Widget build(BuildContext context) {
    final d = ref.read(directorProvider), db = ref.read(dbProvider), u = ref.watch(understandProvider), cloud = ref.watch(ladderProvider) == Ladder.full, visuals = ref.watch(visualProvider);
    final title = switch (step) { _S.bring => 'Bring something to Milo', _S.photo => 'Crop to the text', _S.reading => 'Milo is reading your text', _S.style => 'How would you like it?', _S.reader => (words.take(3).join(' ')), _S.check => 'Quick check' };
    Widget body;
    switch (step) {
      case _S.bring:
        body = ListView(padding: const EdgeInsets.all(16), children: [
          RowCard(icon: Icons.content_paste, title: 'Paste text', onTap: _paste), RowCard(icon: Icons.photo_camera_outlined, title: 'Take a photo', color: 1, onTap: () => _photo(ImageSource.camera)),
          RowCard(icon: Icons.document_scanner_outlined, title: 'Scan a document', color: 3, onTap: () => _photo(ImageSource.camera)), RowCard(icon: Icons.upload_file, title: 'Import a file', color: 2, onTap: _file),
          if (recent.isNotEmpty) ...[const Section('Recent'), for (final r in recent) RowCard(icon: Icons.description_outlined, title: r['t']!, subtitle: 'Saved on this phone', onTap: () { _image = null; _use(r['x']!); })],
          FutureBuilder(future: db.documents(), builder: (_, s) {
            final docs = s.data ?? [];
            if (docs.isEmpty) return const SizedBox();
            return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Section('Saved'),
              for (final doc in docs) Card(child: ListTile(leading: const Icon(Icons.bookmark, color: T.pri), title: Text('${doc['title']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                subtitle: const Text('Saved by you'), onTap: () { _image = null; _use('${doc['text']}'); },
                trailing: IconButton(tooltip: 'Delete', icon: const Icon(Icons.delete_outline), onPressed: () async { await db.deleteDocument(doc['id'] as String); setState(() {}); })))]);
          }),
          const SizedBox(height: 10),
          TextField(controller: ask, decoration: InputDecoration(hintText: 'Or just ask Milo…', suffixIcon: IconButton(icon: const Icon(Icons.mic, color: T.pri), onPressed: () { Navigator.pop(context); ref.read(tabProvider.notifier).state = 2; })), onSubmitted: (t) { if (t.trim().isEmpty) return; Navigator.pop(context); ref.read(tabProvider.notifier).state = 2; ref.read(chatProvider.notifier).user(t); d.ask(t); }),
          ]);
      case _S.photo:
        body = Container(color: const Color(0xFF454B66), child: Column(children: [
          Expanded(child: Padding(padding: const EdgeInsets.all(20), child: _image == null ? const SizedBox() : Container(decoration: BoxDecoration(border: Border.all(color: T.amber, width: 3)), child: Image.memory(_image!, fit: BoxFit.contain)))),
          Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), decoration: BoxDecoration(color: const Color(0xFF2B3050), borderRadius: BorderRadius.circular(16)), child: const Text('Resized, EXIF and location removed on this phone', style: TextStyle(color: Colors.white, fontSize: 12))),
          Padding(padding: const EdgeInsets.all(18), child: Row(children: [Expanded(child: BigButton('Retake', () => _photo(ImageSource.camera), kind: BK.outline)), const SizedBox(width: 12), Expanded(child: BigButton('Use photo', () { _remember(); setState(() => step = _S.reading); if (cloud) { _explain('default'); } }))]))]));
      case _S.reading:
        body = ListView(padding: const EdgeInsets.all(16), children: [
          const MiloStage(),
          if (u.loading) ...[const Center(child: Text('Understanding your text…', style: TextStyle(color: T.mute))), const Padding(padding: EdgeInsets.all(12), child: LinearProgressIndicator())],
          if (u.keyPoints.isNotEmpty) ...[const Section('Key points'), for (final k in u.keyPoints) Card(child: ListTile(leading: const Icon(Icons.circle, size: 10, color: T.pri), title: Text(k, style: const TextStyle(fontSize: 17)), trailing: const Icon(Icons.volume_up, color: T.mute), onTap: () => d.speak(k)))],
          if (u.simple.isNotEmpty) Card(color: T.priSoft, child: ListTile(title: const Text('In simple words'), subtitle: Text(u.simple, style: const TextStyle(fontSize: 18)), onTap: () => d.speak(u.simple))),
          if (!u.loading && u.keyPoints.isEmpty) Card(child: Padding(padding: const EdgeInsets.all(14), child: Text(cloud ? 'Tap “Show in simple language”, or just read it aloud.' : 'Offline: I can read it aloud and show it one piece at a time.', style: const TextStyle(fontSize: 16)))),
          const SizedBox(height: 8), BigButton('Show in simple language', cloud ? () => _explain('simpler') : null, kind: BK.soft), const SizedBox(height: 10),
          BigButton('Continue', () => setState(() => step = _S.style))]);
      case _S.style:
        body = ListView(padding: const EdgeInsets.all(16), children: [
          Row(children: [for (final e in [('Audio', Icons.headphones, 0), ('Pictures', Icons.image_outlined, 3), ('Simplify', Icons.auto_awesome, 1), ('Quiz', Icons.check_circle_outline, 2)]) Expanded(child: Padding(padding: const EdgeInsets.all(3), child: AspectRatio(aspectRatio: .9, child: PastelTile(icon: e.$2, label: e.$1, color: e.$3, selected: styles.contains(e.$1), onTap: () => setState(() => styles.contains(e.$1) ? styles.remove(e.$1) : styles.add(e.$1))))))]),
          const Section('Recommended for you'),
          for (final r in ['Short sections', 'Audio explanation', 'Key vocabulary']) Container(margin: const EdgeInsets.symmetric(vertical: 4), padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: T.mintSoft, borderRadius: BorderRadius.circular(16)), child: Row(children: [const Icon(Icons.check_circle, color: T.mint), const SizedBox(width: 10), Text(r, style: const TextStyle(fontWeight: FontWeight.w700))])),
          const Padding(padding: EdgeInsets.all(8), child: Center(child: Text('Pre-selected from what you told me.', style: TextStyle(fontSize: 12, color: T.mute)))),
          Card(child: SwitchListTile(title: const Text('Remember this choice'), value: remember, onChanged: (v) => setState(() => remember = v))),
          const SizedBox(height: 14), BigButton('Apply', () async { if (remember) { await ref.read(dbProvider).setAxis('comprehension', styles.join(',').toLowerCase()); } setState(() => step = _S.reader); if (styles.contains('Simplify') && cloud) { _explain('simpler'); } })]);
      case _S.reader:
        final pop = picked == null ? null : u.vocab.where((v) => v['word']!.toLowerCase() == picked!.toLowerCase().replaceAll(RegExp(r'[^A-Za-z]'), '')).firstOrNull;
        final concept = _concept(), png = concept == null ? null : visuals[concept];
        body = ListView(padding: const EdgeInsets.all(16), children: [
          if (png != null) ...[ClipRRect(borderRadius: BorderRadius.circular(18), child: Image.memory(png, height: 180, fit: BoxFit.cover)), const SizedBox(height: 8),
            Center(child: Text('A picture of $concept', style: const TextStyle(fontSize: 12, color: T.mute))), const SizedBox(height: 6)]
          else if (styles.contains('Pictures') && concept != null && cloud) ...[BigButton('Show a picture of $concept', () => d.onShowImage?.call(concept), kind: BK.soft), const SizedBox(height: 14)]
          else ...[Container(height: 120, decoration: BoxDecoration(color: const Color(0xFFCFE6FA), borderRadius: BorderRadius.circular(18)), child: const Icon(Icons.image_outlined, size: 44, color: Color(0xFF4B7FB5))), const SizedBox(height: 14)],
          Container(padding: const EdgeInsets.all(8), color: tint ? const Color(0xFFFFF4D6) : null, child: Wrap(spacing: 6, runSpacing: 6, children: [for (var i = 0; i < words.length; i++) Opacity(opacity: focus && cur >= 0 && (i < cur - 6 || i > cur + 6) ? .25 : 1, child: GestureDetector(onTap: () { setState(() => picked = words[i]); d.speak(words[i]); }, child: Container(key: keys[i], padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(color: i == cur ? T.amberSoft : null, border: i == cur ? Border.all(color: T.amber) : null, borderRadius: BorderRadius.circular(6)), child: Text(words[i], style: TextStyle(fontSize: 22 * d.textScale.clamp(1.0, 1.3), height: d.lineSpacing, color: T.ink)))))])),
          if (picked != null) Center(child: Container(margin: const EdgeInsets.symmetric(vertical: 10), padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: T.pri)), child: Column(mainAxisSize: MainAxisSize.min, children: [
            Row(mainAxisSize: MainAxisSize.min, children: [Text(syllables(picked!), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)), const SizedBox(width: 8), const Icon(Icons.volume_up, color: T.pri, size: 20)]),
            Text(pop?['meaning'] ?? 'Tap Listen to hear it in the sentence', style: const TextStyle(fontSize: 12, color: T.mute))]))),
          Row(children: [for (final b in [('Focus', Icons.center_focus_strong, () => setState(() => focus = !focus)), ('Speed ${_speeds[speedIdx]}x', Icons.speed, () => setState(() => speedIdx = (speedIdx + 1) % 3)), ('Overlay', Icons.layers, () => setState(() => tint = !tint)), ('Big words', Icons.text_fields, () => Navigator.push(context, MaterialPageRoute(builder: (_) => BigWordScreen(words: words, meanings: {for (final v in u.vocab) '${v['word']}'.toLowerCase(): '${v['meaning']}'}))))]) Expanded(child: Padding(padding: const EdgeInsets.all(4), child: FilledButton.tonal(style: FilledButton.styleFrom(minimumSize: const Size(0, 52), backgroundColor: T.priSoft, foregroundColor: T.pri), onPressed: b.$3, child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(b.$2, size: 18), Text(b.$1, style: const TextStyle(fontSize: 11))]))))]),
          const SizedBox(height: 8), Row(children: [Expanded(flex: 2, child: BigButton('Listen', _listen, icon: Icons.volume_up)), const SizedBox(width: 10), Expanded(child: BigButton('Next', () => setState(() => step = _S.check), kind: BK.soft))]),
          Center(child: TextButton.icon(onPressed: _keep, icon: const Icon(Icons.bookmark_add_outlined), label: const Text('Keep this text')))]);
      case _S.check:
        final q = u.check;
        body = ListView(padding: const EdgeInsets.all(16), children: [
          Text(q == null ? 'What is the main idea?' : '${q['q']}', textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)), const SizedBox(height: 14),
          RadioGroup<int>(groupValue: int.tryParse((picked ?? '').startsWith('q') ? picked!.substring(1) : '') ?? -1,
            onChanged: (v) { if (v == null) return; setState(() => picked = 'q$v'); final right = q == null || v == (q['answer_index'] as int? ?? 0); d.emote('encouraging', i: .8, hold: 3, force: true); d.speak(right ? 'Nice thinking.' : 'Let’s look at this part again.', tone: right ? 'warm' : 'calm'); ref.read(dbProvider).progress('check'); },
            child: Column(children: [for (var i = 0; i < (q == null ? 3 : (q['options'] as List).length); i++) Card(child: RadioListTile<int>(value: i,
              title: Text(q == null ? ['It is about one big idea', 'It lists many facts', 'It is not important'][i] : '${(q['options'] as List)[i]}', style: const TextStyle(fontSize: 17))))])),
          const SizedBox(height: 10), const Center(child: Text('No scores. Effort is celebrated.', style: TextStyle(color: T.mute, fontWeight: FontWeight.w700))), const SizedBox(height: 14),
          BigButton('Next', () { d.celebrate(); setState(() { step = _S.bring; picked = null; }); })]);
    }
    return MiloScreen(title: title, kind: 'understand', onBack: _back, bg: step == _S.photo ? const Color(0xFF454B66) : null, body: body);
  }
}

/// Pre-reader large single-word view (wireframe 12.3): one word at a time,
/// huge, with its meaning, Listen, Again and Slower. Fully offline.
class BigWordScreen extends ConsumerStatefulWidget {
  const BigWordScreen({super.key, required this.words, this.meanings = const {}});
  final List<String> words;
  final Map<String, String> meanings;
  @override ConsumerState<BigWordScreen> createState() => _BigWordState();
}

class _BigWordState extends ConsumerState<BigWordScreen> {
  int i = 0;
  bool slow = false;
  @override
  Widget build(BuildContext context) {
    final d = ref.read(directorProvider);
    if (widget.words.isEmpty) return MiloScreen(title: 'Big words', body: const Center(child: Text('No words to show yet.')));
    final w = widget.words[i.clamp(0, widget.words.length - 1).toInt()];
    final meaning = widget.meanings[w.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '')];
    void hear({bool again = false}) => d.speak(again ? w : (meaning == null ? w : '$w. $meaning'), rate: slow ? .6 : 1);
    return MiloScreen(title: 'Big words (${i + 1}/${widget.words.length})', body: Padding(padding: const EdgeInsets.all(20), child: Column(children: [
      const Spacer(),
      Text(w, textAlign: TextAlign.center, style: const TextStyle(fontSize: 64, fontWeight: FontWeight.w800, height: 1.1)),
      const SizedBox(height: 6), Text(syllables(w), textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, color: T.mute)),
      if (meaning != null) Padding(padding: const EdgeInsets.only(top: 10), child: Text(meaning, textAlign: TextAlign.center, style: const TextStyle(fontSize: 20))),
      const Spacer(),
      Row(children: [Expanded(child: BigButton('Listen', () => hear(), icon: Icons.volume_up)), const SizedBox(width: 10), Expanded(child: BigButton('Again', () => hear(again: true), kind: BK.soft))]),
      const SizedBox(height: 10),
      Row(children: [Expanded(child: BigButton(slow ? 'Normal speed' : 'Slower', () => setState(() => slow = !slow), kind: BK.outline)), const SizedBox(width: 10),
        Expanded(child: BigButton(i + 1 >= widget.words.length ? 'Done' : 'Next', () { if (i + 1 >= widget.words.length) { Navigator.pop(context); } else { setState(() => i++); } }, kind: BK.mint))]),
      const SizedBox(height: 90),
    ])));
  }
}
