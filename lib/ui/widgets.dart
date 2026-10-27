import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config.dart';
import '../contracts/brain_contract.dart';
import '../core/payload.dart';
import '../companion/director.dart';
import '../companion/milo_view.dart';
import '../core/providers.dart';
import 'theme.dart';

class Bubble extends StatelessWidget {
  final String text;
  const Bubble(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(color: Theme.of(context).colorScheme.primaryContainer, borderRadius: BorderRadius.circular(18)),
        child: Text(text, style: const TextStyle(fontSize: 17, height: 1.35)),
      );
}

class BreakOverlay extends ConsumerWidget {
  const BreakOverlay({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    return Material(
      color: const Color(0xEE141733),
      child: SafeArea(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          SizedBox(
            height: 320,
            child: Stack(alignment: Alignment.center, children: [
              AnimatedBuilder(
                animation: d.frame,
                builder: (_, __) => Transform.scale(
                    scale: 1 + .16 * d.br,
                    child: Container(width: 270, height: 270, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: const Color(0x995B6CFF), width: 6)))),
              ),
              const SizedBox(width: 230, height: 260, child: MiloView()),
            ]),
          ),
          AnimatedBuilder(animation: d.frame, builder: (_, __) => Text(d.inhale ? 'Breathe in…' : 'Breathe out…', style: const TextStyle(color: Colors.white, fontSize: 26))),
          const SizedBox(height: 24),
          FilledButton(onPressed: () => d.setBreathing(false), child: const Padding(padding: EdgeInsets.all(8), child: Text('I’m okay now', style: TextStyle(fontSize: 18)))),
        ]),
      ),
    );
  }
}

Widget _chips<T>(List<T> v, T sel, String Function(T) label, void Function(T) on) =>
    Wrap(spacing: 8, runSpacing: 4, children: [for (final x in v) ChoiceChip(label: Text(label(x)), selected: x == sel, onSelected: (_) => on(x))]);

void showSettings(BuildContext context) {
  showModalBottomSheet(
    context: context, isScrollControlled: true,
    builder: (_) => Consumer(builder: (ctx, ref, _) {
      final d = ref.watch(directorProvider);
      Widget h(String s) => Padding(padding: const EdgeInsets.only(top: 14, bottom: 6), child: Text(s, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)));
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          h('Presentation'),
          _chips<Profile>(Profile.values, d.profile, (p) => p.name, d.setProfile),
          h('Presence'),
          _chips<Presence?>([null, ...Presence.values], d.presenceOverride, (p) => p?.name ?? 'auto', d.setPresence),
          h('Voice'),
          _chips<String>(['Friendly', 'Calm', 'Energetic'], d.voice, (s) => s, (v) { d.set(() => d.voice = v); d.applyVoice().then((_) => d.speak('Hello, I’m Milo.')); }),
          h('Language'),
          _chips<String>(kLangNames.keys.take(5).toList(), d.lang, (k) => kLangNames[k]!, (v) => d.set(() => d.lang = v)),
          SwitchListTile(title: const Text('Read everything aloud (picture mode)'), value: d.preReader, onChanged: (v) => d.set(() => d.preReader = v)),
          h('Waiting time before a gentle nudge'),
          _chips<int>([3, 8, 20], d.paceSecs, (s) => s == 3 ? 'Instant' : s == 8 ? 'Slower' : 'Extra time', (v) => d.set(() => d.paceSecs = v)),
          h('Milo’s colour'),
          Row(children: [
            for (final c in [0xFF5B6CFF, 0xFF34C38F, 0xFFFF7A7A, 0xFFB583FF, 0xFFFFA94D])
              GestureDetector(
                onTap: () => d.set(() => d.color = Color(c)),
                child: Container(margin: const EdgeInsets.only(right: 12), width: 44, height: 44,
                    decoration: BoxDecoration(color: Color(c), shape: BoxShape.circle, border: Border.all(width: 3, color: d.color == Color(c) ? Colors.black87 : Colors.transparent))),
              ),
          ]),
          SwitchListTile(title: const Text('Quiet presence (blink and breathe only)'), value: d.quiet, onChanged: (v) => d.set(() => d.quiet = v)),
          SwitchListTile(title: const Text('Touch reactions'), value: d.reactions, onChanged: (v) => d.set(() => d.reactions = v)),
          SwitchListTile(title: const Text('Speak aloud'), value: d.voiceOn, onChanged: (v) => d.set(() => d.voiceOn = v)),
          SwitchListTile(title: const Text('Reduce motion'), value: d.forceReduce, onChanged: (v) => d.set(() => d.forceReduce = v)),
        ]),
      );
    }),
  );
}

/// The one call-confirmation sheet in the app: Milo opens the phone's own dialer
/// only after an explicit tap, and never places a call itself.
Future<void> callConfirm(BuildContext c, String label, String number) async {
  final ok = await showModalBottomSheet<bool>(context: c, builder: (_) => Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.phone_iphone, size: 36, color: T.pri), const SizedBox(height: 8),
    Text('Open the phone to call\n$label?', textAlign: TextAlign.center, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
    const SizedBox(height: 6), const Text('Milo opens your phone app. You press call yourself.', style: TextStyle(color: T.mute)), const SizedBox(height: 16),
    Row(children: [Expanded(child: OutlinedButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel'))), const SizedBox(width: 12), Expanded(child: FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Open phone')))]),
  ])));
  if (ok == true) await launchUrl(Uri(scheme: 'tel', path: number));
}

/// Shown when the support flow is active: large buttons for a trusted contact and the configured helpline.
class SupportBar extends ConsumerWidget {
  const SupportBar({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    if (!d.supportActive) return const SizedBox.shrink();
    return Material(color: const Color(0xFFFFF1E0), elevation: 4, child: Padding(padding: const EdgeInsets.all(12), child: FutureBuilder<String?>(
      future: ref.read(dbProvider).get('local.trusted_phone'),
      builder: (_, s) => Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('You are not alone.', style: TextStyle(fontSize: 20, color: Color(0xFF1F2340), fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        if ((s.data ?? '').isNotEmpty) FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 64)), onPressed: () => callConfirm(context, 'my trusted person', s.data!), child: const Text('Call my trusted person', style: TextStyle(fontSize: 18))),
        if (Env.helpline.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: FilledButton.tonal(style: FilledButton.styleFrom(minimumSize: const Size(double.infinity, 64)), onPressed: () => callConfirm(context, 'the helpline', Env.helpline), child: Text('Helpline ${Env.helpline}', style: const TextStyle(fontSize: 18)))),
        TextButton(onPressed: () => d.set(() => d.supportActive = false), child: const Text('I’m okay for now')),
      ]),
    )));
  }
}

/// Plain-words consent for every memory write. Milo confirms only AFTER the operation succeeded.
class MemoryConfirm extends ConsumerWidget {
  const MemoryConfirm({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mem = ref.watch(memoryProvider), p = mem.pending;
    if (p == null) return const SizedBox.shrink();
    return Material(elevation: 8, borderRadius: BorderRadius.circular(16), color: Theme.of(context).colorScheme.surface, child: Padding(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text(p.label, style: const TextStyle(fontSize: 18)),
      const SizedBox(height: 12),
      Row(children: [
        Expanded(child: OutlinedButton(style: OutlinedButton.styleFrom(minimumSize: const Size(0, 56)), onPressed: mem.dismiss, child: const Text('No', style: TextStyle(fontSize: 18)))),
        const SizedBox(width: 12),
        Expanded(child: FilledButton(style: FilledButton.styleFrom(minimumSize: const Size(0, 56)), onPressed: () async {
          final msg = await mem.confirm();
          if (msg != null) ref.read(directorProvider).perform(BrainTurn(emotion: 'happy', say: [msg]));
        }, child: const Text('Yes', style: TextStyle(fontSize: 18)))),
      ]),
    ])));
  }
}
