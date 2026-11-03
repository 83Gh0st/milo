import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../core/payload.dart';
import '../core/providers.dart';
import '../companion/react.dart';
import '../genui/panel.dart';
import '../genui/widgets.dart';
import '../media/photo.dart';
import '../net/api.dart' show ApiError;
import 'screen.dart';
import 'theme.dart';

/// Milo tab: chat with shared context (wireframe 7.1). Not saved unless the person asks Milo to remember.
class ChatScreen extends ConsumerStatefulWidget { const ChatScreen({super.key}); @override ConsumerState<ChatScreen> createState() => _ChatState(); }
class _ChatState extends ConsumerState<ChatScreen> {
  final c = TextEditingController();
  final sc = ScrollController();
  double _lastPx = 0;
  int _lastMs = 0;
  void _send(String t) {
    if (t.trim().isEmpty) return;
    c.clear();
    MiloReact.sent();
    ref.read(chatProvider.notifier).user(t);
    ref.read(directorProvider).ask(t);
  }

  /// "Show Milo": the Understand route from inside chat. Same prep as the
  /// reader (resize + EXIF wipe + original deleted); the explanation is
  /// spoken and lands in this thread; the ledger shows the send.
  Future<void> _showMilo() async {
    final x = await ImagePicker().pickImage(source: ImageSource.camera, maxWidth: 2400);
    if (x == null || !mounted) return;
    final jpg = await compute(preparePhoto, await x.readAsBytes());
    try { await File(x.path).delete(); } catch (_) {}
    if (!mounted) return;
    final b64 = base64Encode(jpg);
    ref.read(chatProvider.notifier).userPhoto(b64);
    MiloReact.sent();
    await ref.read(routerProvider).explain(ref.read(directorProvider), '', imageB64: b64);
  }
  @override
  void initState() {
    super.initState();
    // Scroll velocity from public pixels + timestamps (ScrollPosition.activity is protected).
    sc.addListener(() {
      final now = DateTime.now().millisecondsSinceEpoch, px = sc.hasClients ? sc.position.pixels : 0.0, dt = now - _lastMs;
      final v = dt > 0 ? (px - _lastPx) / dt * 1000 : 0.0;
      _lastPx = px;
      _lastMs = now;
      if (v.abs() > 50) MiloReact.scrolled(v);
    });
  }
  @override
  void dispose() { sc.dispose(); c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final msgs = ref.watch(chatProvider), d = ref.watch(directorProvider), chips = ref.watch(chipsProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) { if (sc.hasClients) sc.animateTo(sc.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut); });
    return Column(children: [
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        IconButton(tooltip: 'What Milo knows', onPressed: () => openScreen('context'), icon: Badge(isLabelVisible: chips.isNotEmpty, label: Text('${chips.length}'), child: const Icon(Icons.layers_outlined))),
        IconButton(tooltip: 'Read the last answer', onPressed: () { final l = msgs.where((m) => m.milo).lastOrNull; if (l != null) d.speak(l.text); }, icon: const Icon(Icons.volume_up_outlined)),
      ]),
      Expanded(child: msgs.isEmpty
          ? Center(child: SingleChildScrollView(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [const MiloStage(), const Text('Ask me anything, by voice or by typing.', textAlign: TextAlign.center, style: TextStyle(fontSize: 18)),
              const SizedBox(height: 12), Wrap(spacing: 8, children: [for (final s in ['Explain', 'Simplify', 'Examples']) ActionChip(label: Text(s), onPressed: () => _send(s))])]))))
          : ListView(controller: sc, padding: const EdgeInsets.all(14), children: [
              for (final m in msgs) Align(alignment: m.milo ? Alignment.centerLeft : Alignment.centerRight, child: Container(
                margin: const EdgeInsets.symmetric(vertical: 5), padding: const EdgeInsets.all(14), constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .8),
                decoration: BoxDecoration(color: m.milo ? T.priSoft : T.pri, borderRadius: BorderRadius.circular(18)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (m.imageB64 != null) Padding(padding: const EdgeInsets.only(bottom: 8), child: ClipRRect(borderRadius: BorderRadius.circular(12), child: _SafeB64Image(b64: m.imageB64!))),
                  if (m.text.isNotEmpty) Text(m.text, style: TextStyle(fontSize: 17, height: d.lineSpacing / 1.5 * 1.35, color: m.milo ? T.ink : Colors.white)),
                  if (m.steps.isNotEmpty) _StepsCard(steps: m.steps),
                  if (m.milo && m.text.isNotEmpty) Align(alignment: Alignment.centerRight, child: InkWell(onTap: () => d.speak(m.text), child: const Padding(padding: EdgeInsets.only(top: 6), child: Icon(Icons.volume_up, size: 18, color: T.pri))))]))),
              if (msgs.isNotEmpty && msgs.last.milo) Wrap(spacing: 8, children: [for (final s in ['Explain', 'Simplify', 'Examples']) OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size(0, 40), foregroundColor: T.pri, side: const BorderSide(color: T.pri)), onPressed: () => _send(s), child: Text(s))]),
              _ActivityPanel(send: _send),
            ])),
      Padding(padding: const EdgeInsets.fromLTRB(12, 4, 12, 10), child: MiloReact.watch(child: TextField(controller: c, onSubmitted: _send, onChanged: (_) => MiloReact.typed(context), decoration: InputDecoration(hintText: 'Ask me anything…', suffixIconConstraints: const BoxConstraints(minWidth: 144, maxWidth: 144, minHeight: 48), suffixIcon: Row(mainAxisSize: MainAxisSize.min, children: [IconButton(tooltip: 'Show Milo', icon: const Icon(Icons.photo_camera_outlined, color: T.pri), onPressed: _showMilo), IconButton(tooltip: 'Speak to Milo', icon: const Icon(Icons.mic, color: T.pri), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const VoiceListenScreen()))), IconButton(tooltip: 'Send', icon: const Icon(Icons.send, color: T.pri), onPressed: () => _send(c.text))]))))),
    ]);
  }
}

/// Honest words for a failed picture creation, by cause. Pure: unit-tested.
/// Blocked prompts, missing picture access (BYOK Meta key), offline, and
/// plain outages each say their thing - never a silent spinner.
String genImageErrorWords(ApiError e) {
  final err = e.detail is Map ? (e.detail as Map)['error'] : null;
  if (err == 'prompt_not_allowed' || e.code == 'prompt_not_allowed') return 'I can only draw kind pictures for kids. What else shall we draw?';
  if (e.code == 'demo_quota_exceeded') return 'Demo picture limit reached for today. Your board still works offline.';
  if (e.code == 'demo_busy') return 'Milo is busy drawing for other visitors. Try again in a moment.';
  if (e.code == 'demo_disabled') return 'Hosted drawing is turned off right now. Your board still works offline.';
  if (e.code == 'bad_image_response' || e.code == 'image_empty') return 'The picture did not come back properly. We can try again.';
  if (e.code == 'http_422') return 'That request did not work. Try different words?';
  if (e.code == 'auth_failed' || e.code == 'http_401' || e.code == 'http_403') return 'Drawing needs a grown-up to set up picture access first.';
  if (e.code == 'offline') return 'I need the internet to draw that. Your board still works.';
  return 'The drawing did not work just now. We can try again later.';
}

/// Honest words for a failed listen, by cause. Pure: unit-tested.
String voiceErrorWords(String code) => switch (code) {
      'mic_denied' => 'The microphone is off. You can allow it in Settings, or type instead.',
      'cloud_off' => 'Voice needs cloud AI. Turn it on in Privacy, or type.',
      'too_short' => 'I did not hear anything. Hold still, speak, then tap stop.',
      'no_speech' => 'I could not hear words in that. Try again closer to the phone, or type.',
      'demo_quota_exceeded' => 'Demo voice limit reached for today. You can still type.',
      'demo_disabled' => 'Hosted voice is turned off right now. You can still type.',
      'budget_exhausted' => 'The thinking cloud is resting. You can still type.',
      'offline' => 'Voice needs the internet. You can still type.',
      _ => 'Voice is not available right now. You can type instead.',
    };

/// Photo the person showed Milo, decoded defensively: corrupt stored data
/// shows a placeholder, never a build exception (the old red box).
class _SafeB64Image extends StatelessWidget {
  const _SafeB64Image({required this.b64});
  final String b64;
  @override
  Widget build(BuildContext context) {
    try {
      return Image.memory(base64Decode(b64), width: 180, fit: BoxFit.cover, semanticLabel: 'Photo you showed Milo',
          errorBuilder: (_, __, ___) => const SizedBox(width: 180, height: 100, child: Center(child: Icon(Icons.broken_image_outlined, color: T.mute, size: 32))));
    } catch (_) {
      return const SizedBox(width: 180, height: 100, child: Center(child: Icon(Icons.broken_image_outlined, color: T.mute, size: 32)));
    }
  }
}

/// The generative activity panel, pinned at the end of the thread. Hidden
/// companion mode renders nothing; featured mode gives Milo the stage.
class _ActivityPanel extends ConsumerWidget {
  const _ActivityPanel({required this.send});
  final void Function(String) send;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final panel = ref.watch(panelProvider);
    if (!panel.active || panel.companion == 'hidden') return const SizedBox.shrink();
    final d = ref.read(directorProvider);
    return PanelView(panel: panel,
        companionHeader: panel.companion == 'featured' ? const MiloStage() : null,
        cb: PanelCallbacks(ask: send, speak: d.speak, openScreen: (s) => openScreen(s), showImage: (c) async {
          if (ref.read(visualProvider).containsKey(c)) return;
          try {
            ref.read(visualProvider.notifier).put(c, await ref.read(apiProvider).visual(c));
          } catch (_) {}
        }, generateImage: (p) async {
          final k = genImageKey(p);
          if (ref.read(genImageProvider).containsKey(k)) return;
          if (ref.read(genImageStateProvider)[k] == 'busy') return; // double-taps never race two generations
          ref.read(genImageStateProvider.notifier).state = {...ref.read(genImageStateProvider), k: 'busy'};
          try {
            ref.read(genImageProvider.notifier).put(k, await ref.read(apiProvider).generateImage(p));
            ref.read(genImageStateProvider.notifier).state = {...ref.read(genImageStateProvider)}..remove(k);
          } on ApiError catch (e) {
            ref.read(genImageStateProvider.notifier).state = {...ref.read(genImageStateProvider), k: e.code};
            d.speak(genImageErrorWords(e));
          } catch (_) {
            ref.read(genImageStateProvider.notifier).state = {...ref.read(genImageStateProvider), k: 'error'};
            d.speak('The drawing did not work just now. We can try again later.');
          }
        }));
  }
}

/// Checklist card from the brain's break_into_steps tool: check steps off
/// locally; "Save to Do" (the visible confirmation) stores the plan.
class _StepsCard extends ConsumerStatefulWidget {
  const _StepsCard({required this.steps});
  final List<String> steps;
  @override
  ConsumerState<_StepsCard> createState() => _StepsCardState();
}

class _StepsCardState extends ConsumerState<_StepsCard> {
  final checked = <int>{};
  bool saved = false;
  Future<void> _save() async {
    final db = ref.read(dbProvider);
    var tasks = <Map<String, dynamic>>[];
    try {
      final raw = await db.get('local.tasks');
      if (raw != null && raw.isNotEmpty) tasks = [for (final t in jsonDecode(raw) as List) Map<String, dynamic>.from(t as Map)];
    } catch (_) {}
    tasks.add({'t': 'Chat plan', 's': [for (final s in widget.steps) ['•', s]]});
    await db.put('local.tasks', jsonEncode(tasks));
    if (mounted) {
      setState(() => saved = true);
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved to Do.')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (var i = 0; i < widget.steps.length; i++)
        InkWell(onTap: () => setState(() => checked.contains(i) ? checked.remove(i) : checked.add(i)),
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Row(children: [
              Icon(checked.contains(i) ? Icons.check_circle : Icons.circle_outlined, color: T.pri),
              const SizedBox(width: 8),
              Expanded(child: Text(widget.steps[i], style: TextStyle(fontSize: 16, decoration: checked.contains(i) ? TextDecoration.lineThrough : null))),
            ]))),
      const SizedBox(height: 4),
      OutlinedButton.icon(onPressed: saved ? null : _save, icon: const Icon(Icons.save_outlined), label: Text(saved ? 'Saved' : 'Save to Do')),
    ]);
  }
}

/// Wireframe 7.2: live transcript chips from Voice Transcribe; typed input is always available.
class VoiceListenScreen extends ConsumerStatefulWidget { const VoiceListenScreen({super.key}); @override ConsumerState<VoiceListenScreen> createState() => _VoiceState(); }
class _VoiceState extends ConsumerState<VoiceListenScreen> {
  String text = '';
  String? error;
  final c = TextEditingController();
  VoidCallback? _onExit; // captured where ref is legal: ref.read in dispose() throws (widget defunct)
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addPostFrameCallback((_) => _start()); }
  Future<void> _start() async {
    final v = ref.read(voiceProvider), d = ref.read(directorProvider), chat = ref.read(chatProvider.notifier);
    _onExit = () { try { v.stop(); d.setListening(false); } catch (_) {} }; // best-effort: the providers may already be gone on a fast pop
    d.setListening(true);
    await v.start(lang: kLangNames[d.lang] ?? 'English',
      onLevel: (l) => d.micLevel = l, // field only: the frame clock repaints, no rebuilds
      onPartial: (t) { d.notePartial(); if (mounted) setState(() { text = t; c.text = t; }); },
      onFinal: (t) { d.setListening(false); if (!mounted) return; Navigator.pop(context); final heard = t.trim(); if (heard.isNotEmpty) { chat.user(heard); d.ask(heard); } },
      onError: (e) { d.setListening(false); if (mounted) setState(() => error = voiceErrorWords(e)); });
  }
  @override
  void dispose() { _onExit?.call(); c.dispose(); super.dispose(); }
  @override
  Widget build(BuildContext context) {
    final d = ref.watch(directorProvider);
    final words = text.split(' ').where((w) => w.isNotEmpty).toList();
    return Scaffold(backgroundColor: const Color(0xFFE9EDFF), body: SafeArea(child: Padding(padding: const EdgeInsets.all(20), child: Column(children: [
      const Text('Listening…', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
      const MiloStage(),
      Wrap(spacing: 8, runSpacing: 8, children: [for (final w in words.length > 6 ? words.sublist(words.length - 6) : words) Chip(label: Text(w, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600)), backgroundColor: Colors.white, side: const BorderSide(color: T.pri))]),
      Text(error ?? 'You can edit what I heard.', style: const TextStyle(color: T.mute)),
      if (error != null) Padding(padding: const EdgeInsets.only(top: 10), child: TextField(controller: c, autofocus: true, onSubmitted: (t) { Navigator.pop(context); ref.read(chatProvider.notifier).user(t); d.ask(t); }, decoration: const InputDecoration(hintText: 'Type here'))),
      const Spacer(),
      SizedBox(height: 60, child: AnimatedBuilder(animation: d.frame, builder: (_, __) {
        final live = d.attenLive, lvl = live ? (.2 + .8 * d.micLevel.clamp(0.0, 1.0)) : .2;
        return Row(mainAxisAlignment: MainAxisAlignment.center, children: [for (var i = 0; i < 28; i++) Container(width: 5, margin: const EdgeInsets.symmetric(horizontal: 2), height: 10 + 38 * (.5 + .5 * math.sin(d.clock * 7 + i * .6)) * lvl, decoration: BoxDecoration(color: T.pri, borderRadius: BorderRadius.circular(3)))]);
      })),
      const SizedBox(height: 16),
      GestureDetector(onTap: () async {
            final heard = text.trim();
            await ref.read(voiceProvider).stop(); // waits briefly for the final transcript; onFinal pops + asks on success
            if (!mounted) return;
            if (error != null) return; // failure words + type fallback stay on screen
            if (heard.isNotEmpty) {
              // Deliberate stop with only a partial: the words on screen are
              // what Milo heard - send them, never lose them.
              Navigator.pop(context);
              ref.read(chatProvider.notifier).user(heard);
              d.ask(heard);
            } else {
              Navigator.pop(context);
            }
          },
          child: Container(width: 84, height: 84, decoration: const BoxDecoration(color: T.coral, shape: BoxShape.circle), child: const Icon(Icons.stop, color: Colors.white, size: 40))),
      const SizedBox(height: 8), const Text('Tap to stop', style: TextStyle(color: T.mute)),
    ]))));
  }
}

/// Wireframe 7.3: exactly what Milo will send. Removing a chip removes it from the very next request.
class ContextScreen extends ConsumerWidget {
  const ContextScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chips = ref.watch(chipsProvider), d = ref.read(directorProvider);
    return MiloScreen(title: 'Your context', kind: 'context', body: ListView(padding: const EdgeInsets.all(16), children: [
      const Section('What Milo will use'),
      if (chips.isEmpty) const Padding(padding: EdgeInsets.all(8), child: Text('Nothing is shared right now.', style: TextStyle(color: T.mute, fontSize: 16))),
      for (final c in chips) Container(margin: const EdgeInsets.symmetric(vertical: 4), padding: const EdgeInsets.fromLTRB(16, 8, 8, 8), decoration: BoxDecoration(color: T.priSoft, borderRadius: BorderRadius.circular(18)),
          child: Row(children: [Expanded(child: Text(c.label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700))), IconButton(tooltip: 'Do not share this', onPressed: () => ref.read(chipsProvider.notifier).remove(c), icon: const Icon(Icons.close, size: 20))])),
      Container(margin: const EdgeInsets.symmetric(vertical: 10), padding: const EdgeInsets.all(14), decoration: BoxDecoration(color: T.mintSoft, borderRadius: BorderRadius.circular(16)), child: const Text('These chips are exactly what Milo sends. Tap × to remove one.', style: TextStyle(fontWeight: FontWeight.w600))),
      const Section('How should I help next?'),
      Wrap(spacing: 8, children: [for (final s in ['Explain', 'Simplify', 'Give examples']) ActionChip(backgroundColor: T.priSoft, side: BorderSide.none, label: Text(s, style: const TextStyle(color: T.pri, fontWeight: FontWeight.w700)), onPressed: () { Navigator.pop(context); ref.read(tabProvider.notifier).state = 2; ref.read(chatProvider.notifier).user(s); d.ask(s); })]),
      const SizedBox(height: 16), const Center(child: Text('Every cloud send is logged in the Cloud ledger.', style: TextStyle(fontSize: 12, color: T.mute))),
    ]));
  }
}
