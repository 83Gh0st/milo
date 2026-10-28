import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../director.dart';
import '../emotion.dart';
import 'look.dart';
export 'look.dart';

/// Level of detail: Stage shows the full body, Buddy the bust, the header
/// chip a face-only avatar. The Director stays the single writer; the LOD
/// only changes what the renderer draws.
enum MiloLod { full, bust, avatar }

/// Proportions per look, in v2 design units (200-unit viewbox).
class LookParams {
  final double bodyW, bodyH, headR, eyeSize, eyeGap, sproutLen, legH, feetW, cheek, browArch;
  const LookParams({required this.bodyW, required this.bodyH, required this.headR, required this.eyeSize,
    required this.eyeGap, required this.sproutLen, required this.legH, required this.feetW, required this.cheek, required this.browArch});
}

const kLooks = {
  MiloLook.a: LookParams(bodyW: 150, bodyH: 148, headR: 62, eyeSize: 1, eyeGap: 1, sproutLen: 1, legH: 0, feetW: 40, cheek: 1, browArch: .5),
  MiloLook.b: LookParams(bodyW: 168, bodyH: 136, headR: 66, eyeSize: 1.1, eyeGap: 1.05, sproutLen: .55, legH: 0, feetW: 34, cheek: 1.2, browArch: .8),
  MiloLook.c: LookParams(bodyW: 126, bodyH: 160, headR: 56, eyeSize: .95, eyeGap: .95, sproutLen: 1.1, legH: 24, feetW: 36, cheek: .9, browArch: .4),
};

/// Reference heights (dp) at which the design-unit motion reads clearly.
/// Smaller renderings get a motion boost so Milo never goes visually still.
const kLodRefDp = {MiloLod.full: 260.0, MiloLod.bust: 140.0, MiloLod.avatar: 48.0};

/// Motion gain by physical size: boost small renderings so gaze, breath and
/// brows stay visible. Pure and unit-tested.
double gainFor(MiloLod lod, double renderedDp) =>
    (kLodRefDp[lod]! / math.max(1, renderedDp)).clamp(1.0, 2.5).toDouble();

/// Minimum gaze travel in dp per LOD (spec 2B).
double minGazeDp(MiloLod lod) => lod == MiloLod.full ? 5.0 : lod == MiloLod.bust ? 3.0 : 2.0;

/// Gaze travel in design units: 7× gain, raised so it reads ≥ [minGazeDp]
/// on screen. Pure and unit-tested; the renderer multiplies by eyeX/eyeY.
double gazeTravelDesign(MiloLod lod, double k, double gain) =>
    math.max(7.0 * gain, minGazeDp(lod) / math.max(k, 1e-3));

/// Breath amplitude (fraction of body height): design value, raised so the
/// chest moves ≥ 2 dp. Pure and unit-tested.
double breathAmpFor(double arousal, double bodyH, double k, double gain) =>
    math.max(.012 + .008 * arousal, 2 / (bodyH * math.max(k, 1e-3) * gain));

/// Read-only snapshot of the Director's channels for one paint. The renderer
/// draws only from this; it never touches the Director.
class DirectorFrame {
  final Face face;
  final double eyeX, eyeY, headX, headY, armL, armR, s1, s2, s3;
  final double lean, breath, mouth, pulse, micLevel, clock, hop, squash, blinkOpen;
  final bool happyEyes, tongue, vis, listening, quiet, aac, highContrast;
  final String fx, emo;
  final CState state;
  final Color color;
  final List<Part> parts;
  final double chAr, chAl, chTilt, chDip, chZoom, chJig, chYawn, chLean;
  final MiloLod lod;
  final MiloLook look;
  final double gain;

  const DirectorFrame({required this.face, required this.eyeX, required this.eyeY, required this.headX, required this.headY,
    required this.armL, required this.armR, required this.s1, required this.s2, required this.s3, required this.lean,
    required this.breath, required this.mouth, required this.pulse, required this.micLevel, required this.clock,
    required this.hop, required this.squash, required this.blinkOpen, required this.happyEyes, required this.tongue,
    required this.vis, required this.listening, required this.quiet, required this.aac, required this.highContrast,
    required this.fx, required this.emo, required this.state, required this.color, required this.parts,
    required this.chAr, required this.chAl, required this.chTilt, required this.chDip, required this.chZoom,
    required this.chJig, required this.chYawn, required this.chLean, required this.lod, required this.look, required this.gain});

  factory DirectorFrame.fromDirector(Director d, {required MiloLod lod, required MiloLook look, required double renderedDp}) {
    final f = d.face;
    final open = (f.eye * d.bf * (1 - d.ch.eyes * .95) * (1 - d.ch.yawn * .6)).clamp(.05, 1.4).toDouble();
    return DirectorFrame(face: f, eyeX: d.eyeX.x, eyeY: d.eyeY.x, headX: d.headX.x, headY: d.headY.x,
      armL: d.armL.x, armR: d.armR.x, s1: d.s1.x, s2: d.s2.x, s3: d.s3.x, lean: d.lean.x,
      breath: d.br, mouth: d.mouth, pulse: d.pulse, micLevel: d.micLevel, clock: d.clock,
      hop: d.hop.x, squash: d.sq.x, blinkOpen: open, happyEyes: f.happyEyes, tongue: f.tongue,
      vis: d.vis, listening: d.state == CState.listening, quiet: d.quiet, aac: d.aac,
      highContrast: d.highContrast, fx: d.fx, emo: d.emo, state: d.state, color: d.color,
      parts: d.parts, chAr: d.ch.ar, chAl: d.ch.al, chTilt: d.ch.tilt, chDip: d.ch.dip,
      chZoom: d.ch.zoom, chJig: d.ch.jig, chYawn: d.ch.yawn, chLean: d.ch.lean,
      lod: lod, look: look, gain: gainFor(lod, renderedDp));
  }
}

/// Five colourways derived from one base colour by a fixed lightness rule
/// (spec 2A). Used by settings swatches and the logo sheet.
List<Color> colorways(Color base) {
  final h = HSLColor.fromColor(base);
  return [for (final l in [.35, .45, .55, .65, .75]) h.withLightness(l).toColor()];
}

/// Brow geometry (design units, up is negative). Positive [Face.browA] raises
/// the inner ends (concerned); negative lowers them (angry). The renderer
/// adds [Face.browAsym] to the right brow only (curious one-up). Pure and
/// unit-tested (angry-brow rule).
({double inner, double outer}) browEnds(Face f, double gain) {
  final inner = -f.browA * 10 * gain;
  final outer = f.browA * 4 * gain;
  return (inner: inner, outer: outer);
}

/// The nine mouth shapes (spec 2C). The renderer interpolates continuously
/// around the selected shape. Pure and unit-tested.
enum MouthShape { rest, smile, bigSmile, openA, openO, closedMBP, frown, flat, tongue }

MouthShape mouthShape({required double smile, required double open, required bool tongue}) {
  if (tongue) return MouthShape.tongue;
  if (smile < -.25 && open < .25) return MouthShape.frown;
  if (open > .65) return smile > .2 ? MouthShape.openA : MouthShape.openO;
  if (open > .2) return smile > .55 ? MouthShape.bigSmile : MouthShape.smile;
  if (smile.abs() < .12) return MouthShape.flat;
  return smile < 0 ? MouthShape.frown : MouthShape.smile;
}

/// True when the mouth is pressed shut mid-speech (M/B/P): speaking energy
/// but (near-)zero jaw opening.
bool isPressedShut({required double open, required bool speaking}) => speaking && open < .08;
