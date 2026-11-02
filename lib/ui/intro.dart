import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../companion/milo_view.dart';
import '../companion/v2/frame.dart';
import '../core/providers.dart';
import 'brand.dart';

/// Opening veil: warm cream, Milo fading/scaling in, the `milo` wordmark
/// underneath, then a crossfade into the app (~1.7 s total, tap to skip).
/// The Shell builds underneath from the first frame, so sync and startup
/// work are never delayed by the animation. Reduced motion (system or Milo
/// setting) gets a brief static hold instead - no fade, no scale.
const introVeilMs = 1700; // full veil: entrance + hold + crossfade (spec: 1.5-2 s)
const introSkipGate = .3; // tap skips once the controller passes this fraction
const introReducedHoldMs = 500; // reduced-motion static hold, then a straight cut

class MiloIntro extends ConsumerStatefulWidget {
  const MiloIntro({super.key});
  @override
  ConsumerState<MiloIntro> createState() => _MiloIntroState();
}

class _MiloIntroState extends ConsumerState<MiloIntro> with SingleTickerProviderStateMixin {
  AnimationController? _c;
  bool _gone = false, _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    final d = ref.read(directorProvider);
    if (MediaQuery.disableAnimationsOf(context) || d.forceReduce || d.reduce) {
      Future.delayed(const Duration(milliseconds: introReducedHoldMs), _done);
    } else {
      _c = AnimationController(vsync: this, duration: const Duration(milliseconds: introVeilMs))..addStatusListener((s) { if (s == AnimationStatus.completed) _done(); });
      _c!.forward();
    }
  }

  void _done() {
    if (_gone || !mounted) return;
    _gone = true;
    try {
      ref.read(introDoneProvider.notifier).state = true;
    } catch (_) {}
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const cream = Color(0xFFFEF4E5); // same cream as the native splash: no flash between them
    if (_c == null) return const Scaffold(backgroundColor: cream, body: Center(child: MiloBrand(size: 120)));
    final c = _c!;
    final mascotIn = CurvedAnimation(parent: c, curve: const Interval(0, .4, curve: Curves.easeOut));
    final wordIn = CurvedAnimation(parent: c, curve: const Interval(.35, .6, curve: Curves.easeOut));
    final veilOut = CurvedAnimation(parent: c, curve: const Interval(.8, 1, curve: Curves.easeInOut));
    return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () { if (c.value > introSkipGate) _done(); }, // skippable once the entrance has landed
        child: AnimatedBuilder(
            animation: c,
            builder: (_, __) => Opacity(
                opacity: 1 - veilOut.value,
                child: Scaffold(
                    backgroundColor: cream,
                    body: Center(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                      Opacity(
                          opacity: mascotIn.value,
                          child: Transform.scale(
                              scale: .92 + .08 * mascotIn.value,
                              child: const AbsorbPointer(child: SizedBox(width: 240, height: 240, child: MiloView(lod: MiloLod.full))))),
                      Opacity(
                          opacity: wordIn.value,
                          child: const Padding(
                              padding: EdgeInsets.only(top: 12),
                              child: Text('milo', style: TextStyle(fontFamily: 'Lexend', fontWeight: FontWeight.w600, fontSize: 40, letterSpacing: 1, color: MiloBrand.ink, height: 1)))),
                    ]))))));
  }
}
