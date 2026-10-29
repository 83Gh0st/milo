import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import 'painter.dart';
import 'v2/frame.dart';
import 'v2/milo2.dart';
import 'v2/renderer.dart';

/// Paints Milo and turns touches into local reactions. Fills whatever box it is given
/// (stage, buddy or chip), so presence modes are just different boxes + LODs.
/// Uses the v2 renderer by default; the Lab can flip [Director.legacyRenderer]
/// to compare with the pre-Phase-2 painter.
class MiloView extends ConsumerWidget {
  const MiloView({super.key, this.buddy = false, this.lod});
  final bool buddy;
  final MiloLod? lod; // null = pick from the box size
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.read(directorProvider);
    final legacy = ref.watch(directorProvider.select((d) => d.legacyRenderer));
    final look = ref.watch(directorProvider.select((d) => d.look));
    final mq = MediaQuery.of(context);
    d.reduce = mq.disableAnimations;
    d.screenW = mq.size.width;
    final route = ModalRoute.of(context);
    final scope = ref.read(miloScopeProvider);
    void measure() => WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!context.mounted) return;
          if (!(route?.isCurrent ?? true)) return; // covered by another route: don't aim gaze
          if (scope != null && scope != d.tab) return; // off-screen tab: don't aim gaze
          final rb = context.findRenderObject();
          if (rb is RenderBox && rb.attached && rb.hasSize) d.registerMilo(rb.localToGlobal(rb.size.center(Offset.zero)), !buddy);
        });
    measure();
    return NotificationListener<ScrollEndNotification>(onNotification: (_) { measure(); return false; }, child: LayoutBuilder(builder: (_, bc) {
      final sz = Size(bc.maxWidth, bc.maxHeight);
      final useLod = lod ?? lodForSize(sz);
      Offset n(Offset p) => Offset((p.dx / sz.width * 2 - 1).clamp(-1.0, 1.0).toDouble(), (p.dy / sz.height * 2 - 1).clamp(-1.0, 1.0).toDouble());
      return Semantics(
        label: 'Milo, your AI companion. Tap to say hi.',
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (t) {
            final zone = legacy ? LegacyRenderer(d).sproutZone(sz) : v2SproutZone(sz, useLod);
            if (zone.contains(t.localPosition)) { d.sproutTap(); } else { d.tapMilo(); }
          },
          onLongPress: d.petMilo,
          onPanUpdate: (u) => d.dragTo(n(u.localPosition)),
          onPanEnd: (_) => d.endDrag(),
          child: CustomPaint(
            painter: legacy ? MiloPainter(d) : MiloPainter2(d, lod: useLod, look: look),
            size: Size.infinite,
          ),
        ),
      );
    }));
  }
}
