import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../companion/director.dart';
import '../core/payload.dart';
import '../core/providers.dart';
import '../net/api.dart';
import '../voice/voice_output.dart';
import 'dev/milo_lab.dart';
import 'pin.dart';
import 'screen.dart';
import 'theme.dart';
import 'trusted_screen.dart';

class MoreScreen extends ConsumerWidget {
  const MoreScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider), db = ref.read(dbProvider);
    void go(Widget w) => Navigator.push(context, MaterialPageRoute(builder: (_) => w));
    return ListView(padding: const EdgeInsets.all(16), children: [

      RowCard(icon: Icons.person_outline, title: 'My profile', subtitle: 'Name, goals', onTap: () => go(const ProfileScreen())),
      RowCard(icon: Icons.accessibility_new, title: 'Accessibility', subtitle: 'Text, font, contrast, motion', color: 1, onTap: () => go(const AccessibilityScreen())),
      RowCard(icon: Icons.favorite_border, title: 'Milo', subtitle: 'Look, voice, presence', color: 3, onTap: () => go(const MiloSettingsScreen())),
      RowCard(icon: Icons.language, title: 'Language', subtitle: 'Screen, speech, listening', color: 2, onTap: () => go(const LanguageScreen())),
      Card(child: SwitchListTile(secondary: const Icon(Icons.airplanemode_active, color: T.pri), title: const Text('Offline mode', style: TextStyle(fontWeight: FontWeight.w700)), subtitle: const Text('Local only. Nothing leaves this phone.'),
          value: d.offlineForced, onChanged: (v) async { await db.putFlag('offline.forced', v); d.set(() => d.offlineForced = v); ref.read(ladderProvider.notifier).refresh(); })),
      RowCard(icon: Icons.lock_outline, title: 'Data and privacy', subtitle: 'Memory, cloud ledger, sync, delete', onTap: () => go(const DataPrivacyScreen())),
      RowCard(icon: Icons.shield_outlined, title: 'Trusted adult', subtitle: 'PIN protected', color: 1, onTap: () async { if (await Pin.gate(context, ref.read(storeProvider))) { if (context.mounted) go(const TrustedScreen()); } }),
      RowCard(icon: Icons.info_outline, title: 'About Milo', subtitle: 'Version and licences', color: 2, onTap: () => go(const AboutScreen())),
      const Padding(padding: EdgeInsets.all(12), child: Text('Milo is an AI companion. It is not a person, a therapist or a doctor.', textAlign: TextAlign.center, style: TextStyle(color: T.mute))),
    ]);
  }
}

Widget _chips<X>(List<X> v, X sel, String Function(X) label, void Function(X) on) => Wrap(spacing: 8, runSpacing: 8, children: [for (final x in v) ChoiceChip(label: Text(label(x), style: TextStyle(fontWeight: FontWeight.w700, color: x == sel ? Colors.white : T.pri)), selected: x == sel, selectedColor: T.pri, backgroundColor: T.priSoft, side: BorderSide.none, showCheckmark: false, onSelected: (_) => on(x))]);

Widget _toggle(String t, bool v, void Function(bool) f, {String? sub}) => Card(child: SwitchListTile(title: Text(t, style: const TextStyle(fontWeight: FontWeight.w700)), subtitle: sub == null ? null : Text(sub), value: v, onChanged: f));

class AccessibilityScreen extends ConsumerWidget {
  const AccessibilityScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    return MiloScreen(title: 'Accessibility', body: ListView(padding: const EdgeInsets.all(16), children: [
      const Section('Text size'),
      Slider(value: d.textScale, min: .9, max: 2.0, divisions: 11, label: '${(d.textScale * 100).round()}%', onChanged: (v) => d.set(() => d.textScale = v)),
      Card(child: Padding(padding: const EdgeInsets.all(16), child: Text('Aa   The ocean is big.', style: TextStyle(fontSize: 18, height: d.lineSpacing)))),
      const Section('Font'),
      _chips<String>(const ['Lexend', 'AtkinsonHyperlegible', 'OpenDyslexic'], d.font, (s) => s == 'AtkinsonHyperlegible' ? 'Atkinson' : s, (v) => d.set(() => d.font = v)),
      const Section('Spacing'),
      Slider(value: d.lineSpacing, min: 1.2, max: 2.6, onChanged: (v) => d.set(() => d.lineSpacing = v)),
      _toggle('High contrast (7:1)', d.highContrast, (v) => d.set(() => d.highContrast = v)),
      _toggle('Reduce motion', d.forceReduce, (v) => d.set(() => d.forceReduce = v), sub: 'Also follows your phone setting'),
      _toggle('Captions on all speech', d.captions, (v) => d.set(() => d.captions = v)),
      _toggle('Haptics', d.haptics, (v) => d.set(() => d.haptics = v)),
      _toggle('Ignore repeated taps', d.ignoreTaps, (v) => d.set(() => d.ignoreTaps = v), sub: 'Taps within half a second count once (tremor)'),
      _toggle('Left-handed layout', d.leftHanded, (v) => d.set(() => d.leftHanded = v), sub: 'Milo and choices move to the left'),
      _toggle('Read everything aloud (picture mode)', d.preReader, (v) => d.set(() => d.preReader = v)),
      _toggle('Scanning (switch access)', d.scanMode, (v) => d.set(() => d.scanMode = v), sub: 'On the board, a highlight moves by itself and any tap picks it'),
      if (d.scanMode) ...[const Section('Scanning speed'), Slider(value: d.scanMs.toDouble(), min: 400, max: 3000, divisions: 13, label: '${(d.scanMs / 1000).toStringAsFixed(1)} s', onChanged: (v) => d.set(() => d.scanMs = v.round()))],
    ]));
  }
}

class MiloSettingsScreen extends ConsumerWidget {
  const MiloSettingsScreen({super.key});
  static const colours = [0xFF8E9BFF, 0xFFFFA3C0, 0xFF6FD9B0, 0xFFFFD166, 0xFFC3A6FF];
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    return MiloScreen(title: 'Milo', body: ListView(padding: const EdgeInsets.all(16), children: [
      const Section('Presentation'),
      _chips<Profile>(Profile.values, d.profile, (p) => p.name[0].toUpperCase() + p.name.substring(1), d.setProfile),
      const Section('Presence'),
      _chips<Presence?>([null, ...Presence.values], d.presenceOverride, (p) => p == null ? 'Auto' : p.name[0].toUpperCase() + p.name.substring(1), d.setPresence),
      const Padding(padding: EdgeInsets.only(top: 6), child: Text('Auto: Stage on Home, Buddy for reading and tasks, Chip on the communication board.', style: TextStyle(fontSize: 12, color: T.mute))),
      const Section('Voice style'),
      _chips<String>(const ['Friendly', 'Calm', 'Energetic', 'Device'], d.voiceStyle, (s) => s, (v) { d.set(() => d.voiceStyle = v); d.applyVoice().then((_) => d.speak('Hello, I’m Milo.', tone: 'warm')); }),
      const Section('Milo’s voice (this phone)'),
      if (d.ttsVoices.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Using this phone’s default voice.', style: TextStyle(color: T.mute)))
      else Wrap(spacing: 8, runSpacing: 8, children: [for (final v in d.ttsVoices) ChoiceChip(
          label: Text('${v['name']!.length > 20 ? '${v['name']!.substring(0, 20)}…' : v['name']!} · ${v['locale']!}', style: TextStyle(fontWeight: FontWeight.w700, color: v['name'] == d.ttsVoice ? Colors.white : T.pri)),
          selected: v['name'] == d.ttsVoice, selectedColor: T.pri, backgroundColor: T.priSoft, side: BorderSide.none, showCheckmark: false,
          onSelected: (_) => d.selectVoice(v['name']!, v['locale']!))]),
      const Padding(padding: EdgeInsets.all(8), child: Text('Choosing plays a preview. Phones do not offer a true child voice; Milo picks the warmest match.', style: TextStyle(fontSize: 12, color: T.mute))),
      Slider(value: d.voiceSpeed, min: .6, max: 1.4, onChanged: (v) => d.set(() => d.voiceSpeed = v)),
      const Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [Text('Slower', style: TextStyle(fontSize: 12, color: T.mute)), Text('Faster', style: TextStyle(fontSize: 12, color: T.mute))]),
      _toggle('Clear speech', d.clearSpeech, (v) => d.set(() => d.clearSpeech = v), sub: 'A little slower and extra careful (helps dyslexic readers)'),
      const Section('Online voice'),
      _chips<VoiceEngineMode>(VoiceEngineMode.values, d.voiceEngine, (m) => m.name[0].toUpperCase() + m.name.substring(1), d.setVoiceEngine),
      Padding(padding: const EdgeInsets.all(8), child: Text(
          d.voice.neural.sink.isReal ? 'Online voice is set up. Milo keeps the same voice no matter which AI it thinks with.' : 'Online voice is not set up on this phone yet — Milo uses the phone voice above. Nothing sounds different until the natural voice arrives.',
          style: const TextStyle(fontSize: 12, color: T.mute))),
      const _DownloadLinesButton(),
      const Section('Milo’s colour'),
      Row(children: [for (final c in colours) GestureDetector(onTap: () => d.set(() => d.color = Color(c)), child: Container(margin: const EdgeInsets.only(right: 12), width: 44, height: 44, decoration: BoxDecoration(color: Color(c), shape: BoxShape.circle, border: Border.all(width: 3, color: d.color == Color(c) ? T.ink : Colors.transparent))))]),
      const Section('Behaviour'),
      _toggle('Quiet presence', d.quiet, (v) => d.set(() => d.quiet = v), sub: 'Milo only breathes and blinks'),
      _toggle('Touch reactions', d.reactions, (v) => d.set(() => d.reactions = v)),
      _toggle('Greetings', d.greetings, (v) => d.set(() => d.greetings = v)),
    ]));
  }
}

class _DownloadLinesButton extends ConsumerStatefulWidget {
  const _DownloadLinesButton();
  @override
  ConsumerState<_DownloadLinesButton> createState() => _DownloadLinesState();
}

class _DownloadLinesState extends ConsumerState<_DownloadLinesButton> {
  bool busy = false;
  String? done;
  @override
  Widget build(BuildContext context) {
    final d = ref.read(directorProvider);
    if (done != null) return Padding(padding: const EdgeInsets.all(8), child: Text(done!, style: const TextStyle(color: T.mute)));
    if (busy) return const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator());
    return BigButton('Download voice lines for offline', () async {
      setState(() => busy = true);
      final (ok, total) = await d.cacheFixedLines();
      if (mounted) setState(() { busy = false; done = ok == total ? 'Saved $ok lines. They play instantly, even offline.' : 'Saved $ok of $total lines. Try again on a good connection.'; });
    }, kind: BK.soft);
  }
}

class LanguageScreen extends ConsumerWidget {
  const LanguageScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    return MiloScreen(title: 'Language', body: ListView(padding: const EdgeInsets.all(16), children: [
      for (final e in kLangNames.entries) Card(child: ListTile(title: Text(e.value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)), subtitle: const Text('Speech and listening'), trailing: d.lang == e.key ? const Icon(Icons.check_circle, color: T.pri) : IconButton(tooltip: 'Hear ${e.value}', icon: const Icon(Icons.volume_up), onPressed: () => d.previewLang(e.key)),
          onTap: () { d.set(() => d.lang = e.key); d.refreshVoices(); })),
      const Padding(padding: EdgeInsets.all(8), child: Text('Voices come from your phone. Download extra voices in your phone’s text-to-speech settings.', style: TextStyle(color: T.mute))),
    ]));
  }
}

class ProfileScreen extends ConsumerStatefulWidget { const ProfileScreen({super.key}); @override ConsumerState<ProfileScreen> createState() => _ProfState(); }
class _ProfState extends ConsumerState<ProfileScreen> {
  final name = TextEditingController();
  Set<String> goals = {};
  @override
  void initState() { super.initState(); final db = ref.read(dbProvider); db.get('name').then((v) => name.text = v ?? ''); db.get('goals').then((v) => setState(() => goals = (v ?? '').split(',').where((x) => x.isNotEmpty).toSet())); }
  @override
  Widget build(BuildContext context) {
    final db = ref.read(dbProvider), d = ref.watch(directorProvider);
    return MiloScreen(title: 'My profile', body: ListView(padding: const EdgeInsets.all(16), children: [
      const Section('Name (optional)'),
      TextField(controller: name, onChanged: (v) => db.put('name', v), decoration: const InputDecoration(hintText: 'Stays on this phone unless you allow names')),
      const Section('My goals'),
      Wrap(spacing: 8, runSpacing: 8, children: [for (final g in ['Read a story', 'Words', 'Asking for help', 'Daily routine']) FilterChip(label: Text(g, style: TextStyle(fontWeight: FontWeight.w700, color: goals.contains(g) ? Colors.white : T.pri)), selected: goals.contains(g), selectedColor: T.pri, backgroundColor: T.priSoft, showCheckmark: false, side: BorderSide.none,
          onSelected: (v) { setState(() => v ? goals.add(g) : goals.remove(g)); db.put('goals', goals.join(',')); })]),
      const Section('Voice on this phone'),
      Card(child: ListTile(leading: Icon(d.ttsReady ? Icons.check_circle : Icons.error_outline, color: d.ttsReady ? T.mint : T.coral), title: Text(d.ttsReady ? 'A voice is installed' : 'No voice found'), subtitle: const Text('Checks that offline speech will work'))),
      const SizedBox(height: 12),
      BigButton('Delete everything', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DataPrivacyScreen())), kind: BK.outline),
    ]));
  }
}

/// About page (launch checklist): version, AI disclosure, and the bundled font licences.
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});
  static const _licenses = {'Lexend': 'assets/fonts/OFL-Lexend.txt', 'Atkinson Hyperlegible': 'assets/fonts/OFL-Atkinson.txt', 'OpenDyslexic': 'assets/fonts/OFL-OpenDyslexic.txt'};
  @override
  Widget build(BuildContext context) => MiloScreen(title: 'About Milo', body: ListView(padding: const EdgeInsets.all(16), children: [
    Center(child: Padding(padding: const EdgeInsets.all(8), child: GestureDetector(onLongPress: kDebugMode ? () => Navigator.push(context, MaterialPageRoute(builder: (_) => const MiloLab())) : null, child: const Text('Milo Companion 1.0.0', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))))),
    const Padding(padding: EdgeInsets.all(8), child: Text('Milo is an AI companion for learning and communication. It is not a person, a therapist or a doctor.', textAlign: TextAlign.center, style: TextStyle(color: T.mute))),
    const Section('Connection'),
    const ConnectionCheckRow(),
    const Section('Font licences (SIL Open Font License)'),
    for (final e in _licenses.entries) Card(child: ExpansionTile(title: Text(e.key, style: const TextStyle(fontWeight: FontWeight.w700)), children: [
      FutureBuilder(future: DefaultAssetBundle.of(context).loadString(e.value), builder: (_, s) => Padding(padding: const EdgeInsets.all(16), child: Text((s.data ?? 'Loading…').split('\n').take(12).join('\n'), style: const TextStyle(fontSize: 12))))])),
  ]));
}

/// Phase 0 connection check (More → About): which server, what /v1/health
/// says, and the failure reason in plain words. Reports raw reachability;
/// gates (offline mode, cloud consent) stay visible in the ladder banner.
class ConnectionCheckRow extends ConsumerWidget {
  const ConnectionCheckRow({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final check = ref.watch(connectionCheckProvider);
    return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [const Expanded(child: Text('Thinking cloud', style: TextStyle(fontWeight: FontWeight.w700)),
        IconButton(tooltip: 'Check again', onPressed: () => ref.refresh(connectionCheckProvider), icon: const Icon(Icons.refresh))]),
      ...check.when(
        data: (s) => [Text('Server: ${s.apiBase}', style: const TextStyle(color: T.mute, fontSize: 13)),
          Text(s.provider == null ? 'Health: unreachable' : 'Health: ok · ${s.provider} · ${s.brainMode ?? 'json'} · budget ${s.budgetOk == true ? 'ok' : 'used'}', style: const TextStyle(color: T.mute, fontSize: 13)),
          const SizedBox(height: 6), Text(s.words, style: const TextStyle(fontSize: 15))],
        loading: () => [const Text('Checking…', style: TextStyle(color: T.mute))],
        error: (e, _) => [Text(connectionWords(health: null, error: e is ApiError ? e.code : 'error'), style: const TextStyle(fontSize: 15))],
      ),
    ])));
  }
}

class DataPrivacyScreen extends ConsumerStatefulWidget { const DataPrivacyScreen({super.key}); @override ConsumerState<DataPrivacyScreen> createState() => _DPState(); }
class _DPState extends ConsumerState<DataPrivacyScreen> {
  Future<void> _msg(String s) async => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(s)));
  Future<void> _sync() async {
    final sync = ref.read(syncProvider);
    final on = await sync.enabled;
    if (!mounted) return;
    showModalBottomSheet(context: context, builder: (ctx) => Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Sync between my devices', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
      const SizedBox(height: 8),
      const Text('Everything is encrypted on this phone before it leaves. The server only stores scrambled data it cannot read. You keep the sync key; if it is lost, the cloud copy cannot be opened.'),
      const SizedBox(height: 12),
      if (on) ...[
        FilledButton(onPressed: () async { Navigator.pop(ctx); try { await sync.syncNow(); _msg('Synced.'); } catch (_) { _msg('Could not sync right now.'); } }, child: const Text('Sync now')),
        TextButton(onPressed: () async { Navigator.pop(ctx); await sync.disable(); _msg('Sync is off and the cloud copy was deleted.'); }, child: const Text('Turn off and delete the cloud copy')),
      ] else ...[
        FilledButton(onPressed: () async {
          Navigator.pop(ctx);
          try {
            final secret = await sync.enable();
            if (!mounted) return;
            showDialog(context: context, builder: (_) => AlertDialog(title: const Text('Your sync key'), content: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text('Write this down or keep it somewhere safe. It is shown only once.'), const SizedBox(height: 12), SelectableText(secret, style: const TextStyle(fontSize: 20, fontFamily: 'monospace'))]),
              actions: [TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: secret)), child: const Text('Copy')), FilledButton(onPressed: () => Navigator.pop(context), child: const Text('I saved it'))]));
          } on CloudDisabled { _msg('Turn on cloud use first in Privacy.'); } catch (_) { _msg('Could not reach the server. Try again later.'); }
        }, child: const Text('Turn on sync (this is my first device)')),
        TextButton(onPressed: () async {
          Navigator.pop(ctx);
          final t = TextEditingController();
          final secret = await showDialog<String>(context: context, builder: (_) => AlertDialog(title: const Text('Enter your sync key'), content: TextField(controller: t, autofocus: true, textCapitalization: TextCapitalization.characters),
              actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(context, t.text), child: const Text('Join'))]));
          if (secret == null || secret.trim().isEmpty) return;
          try { await sync.join(secret); _msg('This phone is now synced.'); } catch (_) { _msg('That key did not work.'); }
        }, child: const Text('Add this phone to my sync (I have a key)')),
      ],
    ])));
  }

  @override
  Widget build(BuildContext context) {
    final db = ref.read(dbProvider), d = ref.read(directorProvider);
    return MiloScreen(title: 'Data and privacy', body: ListView(padding: const EdgeInsets.all(16), children: [
      FutureBuilder(future: db.get('ai.family_key'), builder: (_, s) => Card(child: ListTile(
          leading: Icon((s.data ?? '').isNotEmpty ? Icons.key : Icons.cloud, color: T.pri),
          title: Text('Milo is thinking with ${(s.data ?? '').isNotEmpty ? 'your family AI' : 'the shared cloud'}'),
          subtitle: const Text('Change it in Trusted adult → AI connections')))),
      RowCard(icon: Icons.psychology_alt_outlined, title: 'What Milo remembers', subtitle: 'See it, change it, forget it', onTap: () => openScreen('memory')),
      RowCard(icon: Icons.cloud_outlined, title: 'Cloud and consent', subtitle: 'What was sent, and what never is', color: 2, onTap: () => openScreen('privacy')),
      RowCard(icon: Icons.sync, title: 'Sync between devices', subtitle: 'End-to-end encrypted, optional', color: 3, onTap: _sync),
      RowCard(icon: Icons.delete_forever_outlined, title: 'Delete everything', subtitle: 'Erase all Milo data and keys on this phone', color: 1, onTap: () async {
        final ok = await showDialog<bool>(context: context, builder: (_) => AlertDialog(title: const Text('Delete everything?'), content: const Text('This erases your data, keys and memories on this phone. If sync is on, the cloud copy is deleted too.'),
            actions: [TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Keep')), FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete'))]));
        if (ok != true) return;
        final sync = ref.read(syncProvider);
        if (await sync.enabled) { await sync.disable(); }
        await db.deleteEverything();
        d.cancelSpeech();
        if (mounted) showDialog(barrierDismissible: false, context: context, builder: (_) => const AlertDialog(title: Text('All data deleted'), content: Text('Please close and reopen Milo to start fresh.')));
      }),
    ]));
  }
}
