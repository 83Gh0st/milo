import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../companion/director.dart';
import '../../companion/emotion.dart';
import '../../companion/milo_view.dart';
import '../../companion/v2/frame.dart';
import '../../companion/v2/renderer.dart';
import '../../core/providers.dart';
import '../theme.dart';

/// Milo Lab (debug only): pose the 12 expressions in Stage/Buddy/Chip boxes,
/// fire every clip, steer gaze, switch renderer/look/LOD, and read Director
/// channels plus layout-derived dp. Opened by long-pressing the version in About.
class MiloLab extends ConsumerWidget {
  const MiloLab({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!kDebugMode) return const SizedBox();
    final d = ref.watch(directorProvider);
    final rd = ref.read(directorProvider);
    return Scaffold(appBar: AppBar(title: const Text('Milo Lab')), body: ListView(padding: const EdgeInsets.all(16), children: [
      const Section('Renderer + look (2A pick lives here)'),
      Card(child: SwitchListTile(title: const Text('Legacy renderer (pre-Phase-2, for comparison)'), value: d.legacyRenderer, onChanged: (v) => rd.set(() => rd.legacyRenderer = v))),
      Wrap(spacing: 8, children: [for (final l in MiloLook.values) ChoiceChip(label: Text('Look ${l.name.toUpperCase()}'), selected: d.look == l, onSelected: (_) => rd.set(() => rd.look = l))]),
      const Section('Expressions (tap: pose all previews)'),
      Wrap(spacing: 8, runSpacing: 8, children: [for (final e in faces.keys) ChoiceChip(label: Text(e), selected: d.emo == e, onSelected: (_) => rd.emote(e, i: 1, hold: 30))]),
      const Section('Previews + measured dp'),
      _Measured(label: 'stage', w: null, h: 200, legacy: d.legacyRenderer),
      Row(children: [Expanded(child: _Measured(label: 'buddy', w: 110, h: 128, legacy: d.legacyRenderer)), Expanded(child: _Measured(label: 'chip', w: 40, h: 40, legacy: d.legacyRenderer)), const Expanded(child: _GazePad())]),
      const Section('Clips'),
      Wrap(spacing: 8, runSpacing: 8, children: [for (final c in Director.clipNames) OutlinedButton(onPressed: () => rd.gesture(c, force: true), child: Text(c))]),
      const Section('Idle (fire one now)'),
      Wrap(spacing: 8, runSpacing: 8, children: [for (final n in Director.idleFull) OutlinedButton(onPressed: () => rd.debugFidget(n), child: Text(n))]),
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
        'render ${d.legacyRenderer ? 'legacy' : 'v2/${d.look.name}'} · mood ${d.moodBase.toStringAsFixed(2)} · days ${d.daysTogether}\n'
        'mic ${d.micLevel.toStringAsFixed(2)} · speaking ${d.speaking} · caption “${d.caption}”\n'
        'face eye ${d.face.eye.toStringAsFixed(2)} smile ${d.face.smile.toStringAsFixed(2)} browA ${d.face.browA.toStringAsFixed(2)}\n'
        'choices ${d.choices.length} · clips ${d.clips.length} · reduce ${d.reduce || d.forceReduce}',
        style: const TextStyle(fontSize: 13)))),
      const Section('Voice (live)'),
      Card(child: Padding(padding: const EdgeInsets.all(12), child: Text(
        'engine ${d.voice.engineInUse} (mode ${d.voiceEngine.name}) · sink ${d.voice.neural.sink.isReal ? 'real' : 'noop (timed, silent)'}\n'
        'neural ready ${d.voice.neuralReady} · last engine ${d.voice.neural.lastEngine.isEmpty ? '—' : d.voice.neural.lastEngine}\n'
        'first audio ${d.voice.neural.lastFirstAudioMs} ms · queue ${d.voice.neural.queueDepth} · mouth ${d.mouth.toStringAsFixed(2)}',
        style: const TextStyle(fontSize: 13)))),
      Wrap(spacing: 8, runSpacing: 8, children: [
        OutlinedButton(onPressed: () => rd.speak('Hello! This is a voice test with two sentences. How do I sound?', tone: 'warm'), child: const Text('speak test')),
        OutlinedButton(onPressed: () => rd.setListening(true), child: const Text('listen')),
        OutlinedButton(onPressed: () { rd.notePartial(); }, child: const Text('partial')),
        OutlinedButton(onPressed: () => rd.setListening(false), child: const Text('stop listen')),
        OutlinedButton(onPressed: () => rd.cancelSpeech(), child: const Text('barge-in')),
      ]),
    ]));
  }
}

/// A fixed demo box reporting its REAL laid-out size, the auto LOD, and the
/// painter part sizes derived from it (v2: 200-unit viewbox, body 150×148,
/// eyes 30×38, gaze ±7 design units + physical minimums).
class _Measured extends StatefulWidget {
  const _Measured({required this.label, required this.w, required this.h, required this.legacy});
  final String label;
  final double? w;
  final double h;
  final bool legacy;
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
    String nums() {
      if (s == null) return '…';
      if (widget.legacy) {
        final k = s.width / 260 < s.height / 300 ? s.width / 260 : s.height / 300;
        return 'body ${(130 * k).toStringAsFixed(0)}×${(138 * k).toStringAsFixed(0)} eye ${(17 * k).toStringAsFixed(1)} gaze ±${(4.5 * k).toStringAsFixed(1)}';
      }
      final lod = lodForSize(s);
      if (lod == MiloLod.avatar) {
        final k = (s.width < s.height ? s.width : s.height) / 120;
        return 'avatar head ${(108 * k).toStringAsFixed(0)} eye ${(30 * 1.25 * k).toStringAsFixed(1)}';
      }
      final k = lod == MiloLod.full ? (s.width < s.height ? s.width : s.height) / 200 : (s.width / 200 < s.height / 170 ? s.width / 200 : s.height / 170);
      final g = gainFor(lod, s.height);
      final travel = (7.0 * g < (lod == MiloLod.full ? 5 : 3) / k ? (lod == MiloLod.full ? 5 : 3) / k : 7.0 * g) * k;
      return '${lod.name} body ${(150 * k).toStringAsFixed(0)}×${(148 * k).toStringAsFixed(0)} eye ${(30 * k).toStringAsFixed(1)} gaze ±${travel.toStringAsFixed(1)}';
    }

    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(color: const Color(0xFFE9EDFF), child: SizedBox(width: widget.w, height: widget.h, child: const MiloView())),
      Text('${widget.label}${s == null ? '' : ' ${s.width.toStringAsFixed(0)}×${s.height.toStringAsFixed(0)}'}', style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)),
      Text(nums(), style: const TextStyle(fontSize: 11, color: T.mute)),
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
