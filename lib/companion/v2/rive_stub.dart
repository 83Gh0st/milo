import 'package:flutter/material.dart';
import 'frame.dart';
import 'renderer.dart';

/// Future Rive renderer adapter (spec 2F). STUB: throws until a real,
/// properly licensed `.riv` asset exists. Do NOT add the `rive` dependency
/// until then. State-machine inputs map 1:1 to [DirectorFrame] channels —
/// see `docs/CHARACTER_RIG_SPEC.md`.
class RiveRenderer extends MiloRenderer {
  const RiveRenderer();
  @override
  void paint(Canvas c, Size s, DirectorFrame f) {
    throw UnimplementedError(
        'RiveRenderer needs a real .riv asset (see docs/CHARACTER_RIG_SPEC.md). Using the code-drawn v2 renderer.');
  }

  @override
  Rect sproutZone(Size s) => Rect.fromCenter(center: s.center(Offset.zero), width: 0, height: 0);
}
