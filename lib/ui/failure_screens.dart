import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../companion/milo_view.dart';
import '../core/providers.dart';
import 'screen.dart';
import 'theme.dart';

/// Wireframe 13.3: one plain, honest sentence, then what still works.
class CloudUnreachableScreen extends ConsumerWidget {
  const CloudUnreachableScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.read(directorProvider);
    return MiloScreen(title: 'Offline', noHeader: true, body: Padding(padding: const EdgeInsets.all(20), child: Column(children: [
      const SizedBox(height: 230, child: MiloView()), Speech('I can’t reach my thinking cloud right now. Your things are safe.'), const Spacer(),
      BigButton('Read it aloud', () { final t = ref.read(chipsProvider).where((c) => c.kind == 'document').firstOrNull; if (t != null && t.text.isNotEmpty) d.speak(t.text); Navigator.pop(context); }), const SizedBox(height: 10),
      BigButton('Use my saved explanations', () { Navigator.pop(context); openScreen('understand'); }, kind: BK.soft), const SizedBox(height: 10),
      BigButton('Open my communication board', () { Navigator.pop(context); openScreen('express'); }, kind: BK.soft), const SizedBox(height: 10),
      BigButton('Try again', () { ref.read(ladderProvider.notifier).refresh(); Navigator.pop(context); }, kind: BK.outline), const SizedBox(height: 20),
    ])));
  }
}

/// Wireframe 13.4: the phone has no speech voice; the visual-only level of the offline ladder.
class NoVoiceScreen extends ConsumerWidget {
  const NoVoiceScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.read(directorProvider);
    return MiloScreen(title: 'Milo needs a voice', noHeader: true, body: Padding(padding: const EdgeInsets.all(20), child: Column(children: [
      const SizedBox(height: 230, child: MiloView()), const Text('Milo needs a voice', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)), const Text('This phone has no speech voice yet.', style: TextStyle(color: T.mute)), const SizedBox(height: 16),
      Container(padding: const EdgeInsets.all(16), decoration: BoxDecoration(color: T.amberSoft, borderRadius: BorderRadius.circular(18)), child: const Text('You can still use Milo with large text, pictures and vibration.\nVoices are free to install: open Settings, then Text-to-speech output.', textAlign: TextAlign.center)),
      const Spacer(), BigButton('Use large text', () { d.set(() { d.textScale = 1.4; d.captions = true; }); Navigator.pop(context); }), const SizedBox(height: 10), BigButton('Not now', () => Navigator.pop(context), kind: BK.outline), const SizedBox(height: 20),
    ])));
  }
}
