import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../companion/milo_view.dart';
import '../contracts/brain_contract.dart';
import '../core/providers.dart';
import 'screen.dart';
import 'theme.dart';

/// Wireframe 9.3: reachable in one tap from every screen. Never scored, recorded or reported.
class BreakTimeScreen extends ConsumerStatefulWidget { const BreakTimeScreen({super.key}); @override ConsumerState<BreakTimeScreen> createState() => _BreakState(); }
class _BreakState extends ConsumerState<BreakTimeScreen> {
  int left = 300;
  Timer? t;
  VoidCallback? _onExit; // captured where ref is legal: ref.read in dispose() throws (widget defunct)
  @override
  void initState() {
    super.initState();
    final d = ref.read(directorProvider);
    left = d.breakSecs; // a validated set_timer action may have set this; default 5:00
    _onExit = () { try { d.setBreathing(false); } catch (_) {} }; // the director may already be gone (fast pop); breathing off is best-effort
    WidgetsBinding.instance.addPostFrameCallback((_) { d.setBreathing(true); d.emote('sleepy', i: 1, hold: 1e9, force: true); });
    t = Timer.periodic(const Duration(seconds: 1), (_) { if (left > 0 && mounted) setState(() => left--); });
  }
  @override
  void dispose() { t?.cancel(); final cb = _onExit; WidgetsBinding.instance.addPostFrameCallback((_) => cb?.call()); super.dispose(); }
  @override
  Widget build(BuildContext context) => Scaffold(backgroundColor: const Color(0xFFE6E4FA), body: SafeArea(child: Padding(padding: const EdgeInsets.all(24), child: SingleChildScrollView(child: Column(children: [
    const SizedBox(height: 24), const MiloStage(),
    const Text('Take your time.', style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800)), const Text('I’m right here.', style: TextStyle(color: T.mute, fontSize: 16)), const SizedBox(height: 18),
    Container(padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 14), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(18)), child: Text('${left ~/ 60}:${(left % 60).toString().padLeft(2, '0')}', style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800))),
    const SizedBox(height: 24),
    BigButton('Back to what I was doing', () => Navigator.pop(context)), const SizedBox(height: 10),
    BigButton('Longer break', () => setState(() => left += 300), kind: BK.soft), const SizedBox(height: 10),
    TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BreatheScreen())), child: const Text('Breathe with Milo')),
  ])))));
}

/// Wireframe 9.2: Milo breathes 4 s in, 4 s out, driven by the same breath input as the rig. Optional soft haptic.
class BreatheScreen extends ConsumerStatefulWidget { const BreatheScreen({super.key}); @override ConsumerState<BreatheScreen> createState() => _BreatheState(); }
class _BreatheState extends ConsumerState<BreatheScreen> {
  bool? last;
  @override
  Widget build(BuildContext context) {
    final d = ref.watch(directorProvider);
    return Scaffold(backgroundColor: const Color(0xFFE2E6FF), body: SafeArea(child: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
      const Text('Breathe with Milo', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800)), const Spacer(),
      AnimatedBuilder(animation: d.frame, builder: (_, __) => Transform.scale(scale: 1 + .12 * d.br, child: Container(width: 250, height: 250, decoration: const BoxDecoration(color: Colors.white, shape: BoxShape.circle), child: const Padding(padding: EdgeInsets.all(20), child: MiloView())))),
      const SizedBox(height: 24),
      AnimatedBuilder(animation: d.frame, builder: (_, __) { if (d.haptics && last != d.inhale) { last = d.inhale; } return Text(d.inhale ? 'Breathe in…' : 'Breathe out…', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w800)); }),
      const Spacer(), BigButton('I’m okay now', () => Navigator.pop(context)), const SizedBox(height: 10), BigButton('Stop', () => Navigator.pop(context), kind: BK.outline),
    ]))));
  }
}

/// Wireframe 9.1: optional, never required. Answers are not stored.
class CheckInScreen extends ConsumerWidget {
  const CheckInScreen({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.read(directorProvider);
    final faces = [(Icons.sentiment_very_satisfied, T.mint, 'happy'), (Icons.sentiment_satisfied, const Color(0xFF8AD66F), 'happy'), (Icons.sentiment_neutral, T.amber, 'calm'), (Icons.sentiment_dissatisfied, const Color(0xFFFF9F6B), 'concerned'), (Icons.sentiment_very_dissatisfied, T.coral, 'concerned')];
    return MiloScreen(title: 'Check in', body: Padding(padding: const EdgeInsets.all(20), child: SingleChildScrollView(child: Column(children: [
      const MiloStage(),
      const Text('How are you feeling?', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)), const Text('You can skip this any time.', style: TextStyle(color: T.mute)), const SizedBox(height: 18),
      Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [for (final f in faces) IconButton(iconSize: 48, color: f.$2, icon: Icon(f.$1), onPressed: () async { if (await ref.read(dbProvider).flag('checkin.counts')) ref.read(dbProvider).progress('checkin'); d.emote(f.$3, i: .7, hold: 4, force: true); /* opt-in count only (plan 7.11): answers are never stored */ if (f.$3 == 'concerned') { d.perform(const BrainTurn(emotion: 'concerned', say: ['Thank you for telling me.', 'Would a little break help?'], followup: 'wait')); d.set(() => d.choices = ['Take a break', 'Keep going']); } else { d.speak('Thanks for telling me.'); } })]),
      TextButton(onPressed: () => d.speak('That is okay.'), child: const Text('Not sure')), const SizedBox(height: 24),
      BigButton('I need a break', () { Navigator.pop(context); openScreen('break'); }, kind: BK.soft), const SizedBox(height: 10),
      BigButton('Keep going', () => Navigator.pop(context)), const SizedBox(height: 10), BigButton('Skip', () => Navigator.pop(context), kind: BK.outline),
    ]))));
  }
}
