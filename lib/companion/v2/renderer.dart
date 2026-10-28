import 'package:flutter/material.dart';
import '../director.dart';
import '../painter.dart';
import 'frame.dart';
import 'milo2.dart';

/// Renderer interface (plan 5.8): the Director stays the single writer and
/// every renderer paints from a [DirectorFrame]. `RiveRenderer` will slot in
/// here behind the same inputs when a real .riv asset exists.
abstract class MiloRenderer {
  const MiloRenderer();
  void paint(Canvas c, Size s, DirectorFrame f);
  /// Local-space rect of the sprout (tap zone), derived from the LOD transform.
  Rect sproutZone(Size s);
}

/// The pre-Phase-2 painter, kept pixel-identical behind the Lab's
/// "legacy renderer" toggle until v2 is accepted.
class LegacyRenderer extends MiloRenderer {
  final MiloPainter painter;
  LegacyRenderer(Director d) : painter = MiloPainter(d);
  @override
  void paint(Canvas c, Size s, DirectorFrame f) => painter.paint(c, s);
  @override
  Rect sproutZone(Size s) {
    final k = (s.width / 260 < s.height / 300 ? s.width / 260 : s.height / 300).toDouble();
    final cx = s.width / 2, cy = s.height * .94;
    return Rect.fromLTRB(cx - 45 * k, cy - 215 * k, cx + 45 * k, cy - 142 * k);
  }
}

/// The Phase 2 code-drawn renderer (default). LOD + look come from the view.
class V2Renderer extends MiloRenderer {
  const V2Renderer();
  @override
  void paint(Canvas c, Size s, DirectorFrame f) => paintMilo2(c, s, f);
  @override
  Rect sproutZone(Size s) => v2SproutZone(s, MiloLod.full);
}

/// LOD picked from the box when the view does not name one: Stage-sized
/// boxes get the full body, dock-sized the bust, header chips the avatar.
MiloLod lodForSize(Size s) => s.height >= 180 ? MiloLod.full : s.height >= 90 ? MiloLod.bust : MiloLod.avatar;

/// CustomPainter adapter: rebuilds the frame every repaint from the Director.
class MiloPainter2 extends CustomPainter {
  final Director d;
  final MiloLod lod;
  final MiloLook look;
  MiloPainter2(this.d, {required this.lod, required this.look}) : super(repaint: d.frame);
  static const renderer = V2Renderer();
  @override
  void paint(Canvas c, Size s) =>
      renderer.paint(c, s, DirectorFrame.fromDirector(d, lod: lod, look: look, renderedDp: s.height));
  @override
  bool shouldRepaint(covariant MiloPainter2 old) => old.d != d || old.lod != lod || old.look != look;
}
