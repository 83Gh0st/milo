import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../companion/director.dart';
import '../../companion/emotion.dart';
import '../../companion/milo_view.dart';
import '../../core/providers.dart';
import '../theme.dart';

/// Milo Lab (Phase 0, debug only): pose the 12 expressions in Stage/Buddy/Chip
/// boxes, fire every clip, steer gaze, and read Director channels plus
/// layout-derived dp. Opened by long-pressing the version in About.
class MiloLab extends ConsumerWidget {
  const MiloLab({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!kDebugMode) return const SizedBox();
    final d = ref.watch(directorProvider);
    final rd = ref.read(directorProvider);
    return Scaffold(appBar: AppBar(title: const Text('Milo Lab')), body: ListView(padding: const EdgeInsets.all(16), children: [
      const Section('Expressions (tap: pose all previews)'),
      Wrap(spacing: 8, runSpacing: 8, children: [for (final e in faces.keys) ChoiceChip(label: Text(e), selected: d.emo == e, onSelected: (_) => rd.emote(e, i: 1, hold: 30))]),
      const Section('Previews + measured dp'),
      const _Measured(label: 'stage', w: null, h: 200),
      const Row(children: [Expanded(child: _Measured(label: 'buddy', w: 110, h: 128)), Expanded(child: _Measured(label: 'chip', w: 40, h: 40)), Expanded(child: _GazePad())]),
      const Section('Clips'),
      Wrap(spacing: 8, runSpacing: 8, children: [for (final c in Director.clipNames) OutlinedButton(onPressed: () => rd.gesture(c, force: true), child: Text(c))]),
      const Section('Motion'),
      Text('Text scale ${(d.textScale * 100).round()}%'),
      Slider(value: d.textScale, min: .9, max: 2.0, divisions: 11, onChanged: (v) => rd.set(() => rd.textScale = v)),
      Text('Motion gain ${d.motionGain.toStringAsFixed(2)}× (1.0 = shipped)'),
      Slider(value: d.motionGain, min: 0, max: 2, divisions: 8, onChanged: (v) => rd.set(() => rd.motionGain = v)),
      Card(child: SwitchListTile(title: const Text('Quiet'), value: d.quiet, onChanged: (v) => rd.set(() => rd.quiet = v))),
      Card(child: SwitchListTile(title: const Text('Reduce motion'), value: d.forceReduce, onChanged: (v) => rd.set(() => rd.forceReduce = v))),
      Card(child: SwitchListTile(title: const Text('Left-handed'), value: d.leftHanded, onChanged: (v) => rd.set(() => rd.leftHanded = v))),
      const Section('Director (live)'),
      Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(
        'state ${d.state.name} · emo ${d.emo} ${d.inten.toStringAsFixed(2)} · ${d.presence.name} · ${d.profile.name}\n'
        'mic ${d.micLevel.toStringAsFixed(2)} · speaking ${d.speaking} · caption “${d.caption}”\n'
        'face eye ${d.face.eye.toStringAsFixed(2)} smile ${d.face.smile.toStringAsFixed(2)} browA ${d.face.browA.toStringAsFixed(2)}\n'
        'choices ${d.choices.length} · clips ${d.clips.length} · reduce ${d.reduce || d.forceReduce}',
        style: const TextStyle(fontSize: 13)))),
    ]));
  }
}

/// A fixed demo box that reports its REAL laid-out size plus the painter part
/// sizes derived from it (body 130×138, eyes 17×24, gaze ±4.5/±3.5 design
/// units in a 260×300 box; see MiloPainter).
class _Measured extends StatefulWidget {
  const _Measured({required this.label, required this.w, required this.h});
  final String label;
  final double? w;
  final double h;
  @override
  State<_Measured> createState() => _MeasuredState();
}

class _MeasuredState extends State<_Measured> {
  Size? size;
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) setState(() => size = context.size); }); }
  @override
  Widget build(BuildContext context) {
    final s = size;
    final k = s == null ? 0.0 : (s.width / 260 < s.height / 300 ? s.width / 260 : s.height / 300);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(color: const Color(0xFFE9EDFF), child: SizedBox(width: widget.w, height: widget.h, child: const MiloView())),
      Text('${widget.label}${s == null ? '' : ' ${s.width.toStringAsFixed(0)}×${s.height.toStringAsFixed(0)}'}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
      Text(s == null ? '…' : 'body ${(130 * k).toStringAsFixed(0)}×${(138 * k).toStringAsFixed(0)} eye ${(17 * k).toStringAsFixed(1)} gaze ±${(4.5 * k).toStringAsFixed(1)} breath ±${(2.1 * k).toStringAsFixed(1)}', style: const TextStyle(fontSize: 11, color: T.mute)),
    ]);
  }
}

/// Drag here to steer Milo's gaze (the same channel as touching the screen).
class _GazePad extends ConsumerWidget {
  const _GazePad();
  @override
  Widget build(BuildContext context, WidgetRef ref) => Column(mainAxisSize: MainAxisSize.min, children: [
    GestureDetector(onTapDown: (t) => ref.read(directorProvider).pointerAt(t.globalPosition), onPanUpdate: (t) => ref.read(directorProvider).pointerAt(t.globalPosition),
        child: Container(width: 110, height: 128, decoration: BoxDecoration(color: const Color(0xFFE9EDFF), borderRadius: BorderRadius.circular(12)), child: const Center(child: Text('gaze', style: TextStyle(color: T.mute))))),
    const Text('gaze pad', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
  ]);
}
