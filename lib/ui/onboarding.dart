import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../companion/director.dart';
import '../companion/milo_view.dart';
import '../core/payload.dart';
import '../core/providers.dart';
import 'pin.dart';
import 'theme.dart';

/// Wireframes 1.1 to 1.10. Under 90 seconds, no reading required, every step skippable, works in airplane mode.
class Onboarding extends ConsumerStatefulWidget { const Onboarding({super.key, required this.onDone}); final VoidCallback onDone; @override ConsumerState<Onboarding> createState() => _OState(); }

class _OState extends ConsumerState<Onboarding> {
  final pc = PageController();
  int i = 0;
  String lang = 'en', who = 'self', voice = 'Friendly';
  final comm = <String>{'Touch'}, brings = <String>{'Learn and understand'};
  bool readAloud = false, cloud = true, sendName = false, mic = false, cam = false;
  Color col = const Color(0xFF8E9BFF);
  final name = TextEditingController();
  static const _n = 10;

  void _say(String s) => ref.read(directorProvider).speak(s);
  void _next() { if (i < _n - 1) { pc.nextPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut); } else { _finish(); } }
  void _back() { if (i > 0) pc.previousPage(duration: const Duration(milliseconds: 250), curve: Curves.easeOut); }

  Future<void> _finish({bool skipped = false}) async {
    final db = ref.read(dbProvider), d = ref.read(directorProvider);
    await db.setAxis('communication', comm.join(',').toLowerCase());
    await db.setAxis('context', brings.join(',').toLowerCase());
    await db.put('lang', lang);
    await db.putFlag('cloud.enabled', !skipped && cloud);
    await db.putFlag('cloud.name', sendName);
    if (name.text.trim().isNotEmpty) await db.put('name', name.text.trim());
    await db.logConsent('cloud.enabled', !skipped && cloud ? 'on' : 'off', 'user');
    await db.logConsent('ai_disclosure', 'acknowledged', 'user'); // "Milo is an AI", said in plain words
    if (who == 'child') await db.put('local.child', '1');
    await db.put('onboarded', skipped ? '0' : '1');
    d.set(() { d.lang = lang; d.voice = voice; d.color = col; d.preReader = readAloud; });
    d.setProfile(who == 'child' ? Profile.playful : Profile.friendly);
    d.applyVoice();
    ref.read(ladderProvider.notifier).refresh();
    widget.onDone();
  }

  Widget _page(String title, List<Widget> body, {String? say, String next = 'Next'}) => Padding(padding: const EdgeInsets.fromLTRB(20, 8, 20, 16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    Row(children: [SizedBox(width: 44, child: i > 0 ? IconButton(onPressed: _back, icon: const Icon(Icons.chevron_left, size: 30)) : null), Expanded(child: Text(title, textAlign: TextAlign.center, style: const TextStyle(fontSize: 21, fontWeight: FontWeight.w800))),
      SizedBox(width: 44, child: say == null ? null : IconButton(tooltip: 'Hear it', onPressed: () => _say(say), icon: const Icon(Icons.volume_up, color: T.pri)))]),
    const SizedBox(height: 8), Expanded(child: ListView(children: body)),
    BigButton(next, _next), if (i < _n - 1) TextButton(onPressed: () => _finish(skipped: true), child: const Text('Skip')),
  ]));

  Widget _row(String t, String sub, bool on, VoidCallback f, {IconData? icon}) => Card(color: on ? T.priSoft : null, child: ListTile(leading: icon == null ? null : Icon(icon, color: T.pri), title: Text(t, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)), subtitle: Text(sub), trailing: on ? const Icon(Icons.check_circle, color: T.pri) : const Icon(Icons.circle_outlined, color: T.line), onTap: f));

  @override
  Widget build(BuildContext context) {
    final d = ref.watch(directorProvider);
    return Scaffold(backgroundColor: i == 0 || i == 9 ? const Color(0xFFE9EDFF) : T.bg, body: SafeArea(child: PageView(controller: pc, physics: const NeverScrollableScrollPhysics(), onPageChanged: (v) => setState(() => i = v), children: [
      _page('', [const SizedBox(height: 330, child: MiloView()), const Center(child: Text('Hi! I’m Milo.', style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800))), const Center(child: Text('Your AI companion.\nLet’s get to know each other.', textAlign: TextAlign.center, style: TextStyle(color: T.mute, fontSize: 16)))], say: 'Hi! I’m Milo. Your AI companion.', next: 'Get started'),
      _page('Choose your language', [for (final e in kLangNames.entries.take(5)) _row(e.value, 'Speech and text', lang == e.key, () => setState(() { lang = e.key; d.set(() => d.lang = e.key); }), icon: Icons.language)], say: 'Which language would you like?'),
      _page('Who is using Milo?', [const SizedBox(height: 110, child: MiloView()), Row(children: [Expanded(child: AspectRatio(aspectRatio: .95, child: PastelTile(icon: Icons.person_outline, label: 'Me', color: 0, selected: who == 'self', speaker: true, onTap: () => setState(() => who = 'self')))), const SizedBox(width: 12),
        Expanded(child: AspectRatio(aspectRatio: .95, child: PastelTile(icon: Icons.favorite, label: 'A child I support', color: 1, selected: who == 'child', speaker: true, onTap: () async { setState(() => who = 'child'); final p = await Pin.ask(context, 'Create a 4-digit PIN'); if (p != null && p.length == 4) await Pin.set(ref.read(storeProvider), p); })))]),
        const Padding(padding: EdgeInsets.all(14), child: Text('This only sets up Milo.\nIt is never an age check.', textAlign: TextAlign.center, style: TextStyle(color: T.mute)))], say: 'Who is using Milo?'),
      _page('Read to you?', [const SizedBox(height: 120, child: MiloView()), const Speech('Shall I read everything aloud for you?'), const SizedBox(height: 14),
        Row(children: [Expanded(child: AspectRatio(aspectRatio: 1, child: PastelTile(icon: Icons.hearing, label: 'Yes, read to me', color: 3, selected: readAloud, speaker: true, onTap: () => setState(() => readAloud = true)))), const SizedBox(width: 12), Expanded(child: AspectRatio(aspectRatio: 1, child: PastelTile(icon: Icons.menu_book_outlined, label: 'I can read', color: 0, selected: !readAloud, speaker: true, onTap: () => setState(() => readAloud = false))))])], say: 'Shall I read everything aloud for you?'),
      _page('How do you like to talk?', [GridView.count(crossAxisCount: 2, shrinkWrap: true, physics: const NeverScrollableScrollPhysics(), mainAxisSpacing: 12, crossAxisSpacing: 12, children: [
        for (final e in [(Icons.touch_app, 'Touch', 0), (Icons.mic, 'Speak', 1), (Icons.keyboard, 'Type', 3), (Icons.image_outlined, 'Pictures', 2)]) PastelTile(icon: e.$1, label: e.$2, color: e.$3, selected: comm.contains(e.$2), speaker: true, onTap: () => setState(() => comm.contains(e.$2) ? comm.remove(e.$2) : comm.add(e.$2)))]),
        TextButton(onPressed: _next, child: const Text('I’ll explore'))], say: 'How do you like to communicate? Touch, speak, type, or pictures.'),
      _page('What brings you here?', [for (final b in [('Learn and understand', Icons.menu_book_outlined), ('Express and communicate', Icons.chat_bubble_outline), ('Daily tasks', Icons.check_circle_outline), ('Just explore', Icons.explore_outlined)]) _row(b.$1, '', brings.contains(b.$1), () => setState(() => brings.contains(b.$1) ? brings.remove(b.$1) : brings.add(b.$1)), icon: b.$2)], say: 'What would you like Milo to help with?'),
      _page('Personalise Milo', [const SizedBox(height: 170, child: MiloView()),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (final c in [0xFF8E9BFF, 0xFFFFA3C0, 0xFF6FD9B0, 0xFFFFD166, 0xFFC3A6FF]) GestureDetector(onTap: () { setState(() => col = Color(c)); d.set(() => d.color = Color(c)); }, child: Container(margin: const EdgeInsets.all(6), width: 40, height: 40, decoration: BoxDecoration(color: Color(c), shape: BoxShape.circle, border: Border.all(width: 3, color: col == Color(c) ? T.ink : Colors.transparent))))]),
        const Section('Voice'), for (final v in [('Friendly', 'Warm and bright'), ('Calm', 'Soft and slow'), ('Energetic', 'Quick and playful')]) _row(v.$1, v.$2, voice == v.$1, () { setState(() => voice = v.$1); d.set(() => d.voice = v.$1); d.applyVoice().then((_) => d.speak('Hello, I’m Milo.')); }, icon: Icons.play_arrow),
        const SizedBox(height: 6), TextField(controller: name, decoration: const InputDecoration(hintText: 'Name (optional, stays on this phone)'))], say: 'This is how I look and sound. Pick what you like.'),
      _page('Privacy, in plain words', [
        for (final c in [(Icons.smart_toy_outlined, 'Milo is an AI', 'A helper, not a person.', 0), (Icons.lock_outline, 'Your things stay here', 'Saved on this phone only.', 3), (Icons.language, 'You choose the internet', 'Milo asks before using it.', 2)]) Container(margin: const EdgeInsets.symmetric(vertical: 6), padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: T.soft[c.$4], borderRadius: BorderRadius.circular(20)), child: Row(children: [Icon(c.$1, color: T.strong[c.$4]), const SizedBox(width: 12), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(c.$2, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)), Text(c.$3)])), const Icon(Icons.volume_up, size: 18, color: T.mute)])),
        Card(child: SwitchListTile(title: const Text('Use the internet to help', style: TextStyle(fontWeight: FontWeight.w700)), subtitle: const Text('Explains new text and photos, listens to your voice. Your voice is not kept.'), value: cloud, onChanged: (v) => setState(() => cloud = v))),
        Card(child: SwitchListTile(title: const Text('Share my first name'), value: sendName, onChanged: (v) => setState(() => sendName = v)))], say: 'Milo is an AI. Your things stay on this phone. You choose when Milo uses the internet.', next: 'I understand'),
      _page('Optional permissions', [for (final p in [(Icons.mic, 'Microphone', 'Talk to Milo', mic, 0), (Icons.photo_camera_outlined, 'Camera', 'Your phone asks the first time you take a photo', cam, 1)]) Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Icon(p.$1, color: T.pri), const SizedBox(width: 10), Text(p.$2, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800))]), Text(p.$3, style: const TextStyle(color: T.mute)), const SizedBox(height: 10),
          Row(children: [Expanded(child: OutlinedButton(onPressed: () {}, child: const Text('Not now'))), const SizedBox(width: 10), Expanded(child: FilledButton(onPressed: () async { if (p.$5 == 0) { final ok = await ref.read(voiceProvider).requestPermission(); setState(() => mic = ok); } else { setState(() => cam = true); } }, child: Text(p.$5 == 0 ? (p.$4 ? 'Allowed' : 'Allow') : (p.$4 ? 'Understood' : 'OK'))))])]))),
        const Padding(padding: EdgeInsets.all(12), child: Text('Everything essential works without these.', textAlign: TextAlign.center, style: TextStyle(color: T.mute, fontSize: 12)))], say: 'You can allow the microphone and camera now, or later.'),
      _page('', [const SizedBox(height: 330, child: MiloView()), Center(child: Text('You’re all set${name.text.trim().isEmpty ? '' : ', ${name.text.trim()}'}!', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800))), const Center(child: Text('Milo is ready to help you.', style: TextStyle(color: T.mute)))], say: 'You are all set. Let us start exploring.', next: 'Start exploring'),
    ])));
  }
}
