import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'frame.dart';

/// Phase 2 code-drawn Milo (spec 2B/2C). Design viewbox 200×200; the
/// character's tight bounds plus ~8% margin, so Milo fills its box at every
/// size. Paints only from [DirectorFrame]; the Director stays the writer.
///
/// Design space (look A): feet at y≈0, body centre (0,-78), face centre
/// (0,-100), sprout base (0,-148), sprout tip (0,-189). All looks share the
/// anchor; [LookParams] vary the proportions.

// Character bounds in design units (all looks fit inside; C's legs reach y=0
// exactly like the feet). Used by the fill-fraction test.
const kCharW = 190.0, kCharTop = -189.0, kCharBottom = 8.0;

/// Bounding-box fill per LOD, computed from the same transforms [paintMilo2]
/// uses: min(charW/boxW, charH/boxH). All must clear 0.85 (spec 2B).
double designFill(MiloLod lod) {
  switch (lod) {
    case MiloLod.full:
      return math.min(kCharW / 200, (kCharBottom - kCharTop) / 200);
    case MiloLod.bust:
      return math.min(kCharW / 200, (-30 - kCharTop) / 170); // cropped at the waist (y=-30)
    case MiloLod.avatar:
      return math.min(108 / 120, 108 / 120); // head r=54 in a 120 box
  }
}

void paintMilo2(Canvas c, Size s, DirectorFrame f) {
  switch (f.lod) {
    case MiloLod.avatar:
      _paintAvatar(c, s, f);
    case MiloLod.full:
    case MiloLod.bust:
      _paintBody(c, s, f);
  }
}

Rect v2SproutZone(Size s, MiloLod lod) {
  if (lod == MiloLod.avatar) return Rect.fromCenter(center: s.center(Offset.zero), width: s.width * .3, height: 0);
  final k = lod == MiloLod.full ? math.min(s.width, s.height) / 200 : math.min(s.width / 200, s.height / 170);
  final cx = s.width / 2, cy = lod == MiloLod.full ? s.height * .96 : s.height + 30 * k;
  return Rect.fromLTRB(cx - 30 * k, cy - 189 * k, cx + 30 * k, cy - 140 * k);
}

void _paintBody(Canvas c, Size s, DirectorFrame f) {
  final bust = f.lod == MiloLod.bust;
  final k = bust ? math.min(s.width / 200, s.height / 170) : math.min(s.width, s.height) / 200;
  final lp = kLooks[f.look]!;
  final feat = bust ? 1.12 : 1.0; // bust features slightly larger (spec 2B)
  c.save();
  c.translate(s.width / 2, bust ? s.height + 30 * k : s.height * .96);
  c.scale(k);
  final col = f.color, g = f.gain;

  Color sh(double l) { final h = HSLColor.fromColor(col); return h.withLightness((h.lightness + l).clamp(0.0, 1.0).toDouble()).toColor(); }
  final dark = sh(-.16), light = sh(.2), ink = const Color(0xFF1F2340);

  // Contact shadow (skipped in bust: cropped at the waist).
  final up = (-f.hop / 120).clamp(0.0, 1.0).toDouble();
  if (!bust) {
    c.drawOval(Rect.fromCenter(center: const Offset(0, 4), width: lp.bodyW * (1 - .4 * up), height: 12 * (1 - .4 * up)),
        Paint()..color = Colors.black.withAlpha(30));
  }

  c.save();
  c.translate(0, f.hop);
  c.rotate(f.lean);
  // Breath: design amplitude, boosted so it reads ≥2 dp on small screens.
  final breathAmp = breathAmpFor(f.face.arousal, lp.bodyH, k, g);
  final sy = 1 + f.breath * breathAmp * g + f.squash + f.chZoom, sx = 1 - (sy - 1) * .7 + f.chJig;
  c.scale(sx, sy);

  // Legs (look C) or nub feet; feet shuffle gently when idle-but-awake.
  // Drawn before the body so their tops tuck under the volume.
  final shuffle = (f.quiet || f.aac || f.state.name == 'calm') ? 0.0 : math.sin(f.clock * 2.2) * 2.5 * g;
  if (!bust) _feet(c, lp, col, dark, f.hop * .3, shuffle);

  // Limbs first: the shoulders hide inside the body, so the joints melt into
  // the volume instead of sitting on it as separate sticks.
  _arms(c, f, lp, col, dark);

  // Body: one soft velvety volume. Layered radial shading, ambient occlusion
  // at the base, a single broad sheen - no outline, no gloss sticker. High
  // contrast keeps a thin edge whisper for definition.
  final body = Rect.fromCenter(center: const Offset(0, -78), width: lp.bodyW, height: lp.bodyH);
  c.drawOval(body, Paint()..shader = RadialGradient(center: const Alignment(-.35, -.55), radius: 1.05,
      colors: [light, col, dark], stops: const [0, .5, 1]).createShader(body));
  c.save();
  c.clipPath(Path()..addOval(body));
  c.drawOval(Rect.fromCenter(center: const Offset(0, -12), width: lp.bodyW * .92, height: 64),
      Paint()..color = dark.withAlpha(70)); // grounding occlusion, lower body
  c.restore();
  c.drawOval(Rect.fromCenter(center: const Offset(-30, -118), width: 88, height: 46),
      Paint()..color = Colors.white.withAlpha(42)); // broad key-light sheen
  c.drawArc(Rect.fromCenter(center: const Offset(6, -74), width: lp.bodyW * .86, height: lp.bodyH * .86), .5, 1.1, false,
      Paint()..color = Colors.white.withAlpha(55)..style = PaintingStyle.stroke..strokeWidth = 4..strokeCap = StrokeCap.round); // bounce-light rim
  if (f.highContrast) {
    c.drawOval(body, Paint()..color = dark.withAlpha(150)..style = PaintingStyle.stroke..strokeWidth = 2.5);
  }

  _sprout(c, f, lp);

  // The face lives ON the body and rides the head spring with it: no head
  // disc, no seam, no separate shading - one continuous plush volume.
  final hx = f.headX * g, hy = f.headY * g;
  c.save();
  c.translate(hx, -100 + hy + f.chDip * .6);
  _face(c, s, f, lp, k, ink, feat);
  c.restore();
  c.restore();
  if (f.lod != MiloLod.avatar) _fx(c, f);
  c.restore();
}

void _feet(Canvas c, LookParams lp, Color col, Color dark, double hopLift, double shuffle) {
  final p = Paint()..color = col; // feet share the body material, not a dark outline tone
  if (lp.legH > 0) {
    for (final i in [-1, 1]) {
      c.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(i * 26.0, -lp.legH / 2), width: 24, height: lp.legH + 8), const Radius.circular(12)), p);
    }
  }
  for (final i in [-1, 1]) {
    final center = Offset(i * 30.0 + (i > 0 ? shuffle : -shuffle), -4 + hopLift * .3);
    c.drawOval(Rect.fromCenter(center: center, width: lp.feetW, height: 18), p);
    c.drawOval(Rect.fromCenter(center: center + const Offset(-6, -4), width: lp.feetW * .5, height: 8),
        Paint()..color = Colors.white.withAlpha(38)); // top light in the same key direction
  }
}

void _arms(Canvas c, DirectorFrame f, LookParams lp, Color col, Color dark) {
  // Single-piece curved limbs in the body colour: one quadratic stroke with
  // round caps per arm, a rounded hand, and a whisper of underside shade.
  // The shoulder starts inside the body (drawn before it), so gestures pivot
  // from a hidden joint instead of swinging a disconnected stick.
  for (final i in [-1, 1]) {
    final a = (i < 0 ? f.armL : f.armR) + (i < 0 ? f.chAl : f.chAr);
    final s = Offset(i * (lp.bodyW / 2 - 16), -54);
    final h = s + Offset(math.sin(a) * 52 + i * 10, math.cos(a) * 52 + 6);
    final mid = Offset((s.dx + h.dx) / 2 + i * 7, (s.dy + h.dy) / 2); // gentle natural elbow bow
    c.drawPath(Path()..moveTo(s.dx, s.dy)..quadraticBezierTo(mid.dx, mid.dy, h.dx, h.dy),
        Paint()..color = col..style = PaintingStyle.stroke..strokeWidth = 17..strokeCap = StrokeCap.round);
    c.drawPath(Path()..moveTo(s.dx - i * 3, s.dy + 6)..quadraticBezierTo(mid.dx - i * 3, mid.dy + 6, h.dx - i * 3, h.dy + 4),
        Paint()..color = dark.withAlpha(50)..style = PaintingStyle.stroke..strokeWidth = 5..strokeCap = StrokeCap.round);
    c.drawCircle(h, 10.5, Paint()..color = col);
  }
}

void _sprout(Canvas c, DirectorFrame f, LookParams lp) {
  // Same chain geometry as before (tap zone and LOD bounds unchanged), drawn
  // as one smooth stem through the joints with a planting shadow, and a
  // single pair of plump leaves at the tip instead of two thin pairs.
  final len = (20 + 8 * f.face.perk.clamp(-1.0, 1.0)).toDouble() * lp.sproutLen;
  var p = const Offset(0, -148);
  var a = 0.0;
  final pts = [p];
  for (final s in [f.s1, f.s2, f.s3]) { a += s; p = p + Offset(math.sin(a) * len, -math.cos(a) * len); pts.add(p); }
  c.drawOval(Rect.fromCenter(center: pts[0], width: 24, height: 9),
      Paint()..color = const Color(0xFF1F2340).withAlpha(30)); // planting shadow: the sprout grows FROM the body
  final stem = Path()..moveTo(pts[0].dx, pts[0].dy);
  for (var j = 1; j < pts.length - 1; j++) {
    final mid = (pts[j] + pts[j + 1]) / 2;
    stem.quadraticBezierTo(pts[j].dx, pts[j].dy, mid.dx, mid.dy);
  }
  stem.lineTo(pts.last.dx, pts.last.dy);
  c.drawPath(stem, Paint()..color = const Color(0xFF35B981)..style = PaintingStyle.stroke..strokeWidth = 8..strokeCap = StrokeCap.round);
  final flare = .8 + f.face.arousal * .12; // leaves open with excitement
  for (final i in [-1, 1]) {
    c.save();
    c.translate(pts.last.dx, pts.last.dy);
    c.rotate(a + i * flare);
    c.drawOval(const Rect.fromLTWH(-2, -12, 34, 22), Paint()..color = const Color(0xFF3CC483));
    c.drawOval(const Rect.fromLTWH(4, 1, 24, 8), Paint()..color = const Color(0xFF2AA673)); // soft leaf underside
    c.restore();
  }
}

void _face(Canvas c, Size s, DirectorFrame f, LookParams lp, double k, Color ink, double feat) {
  final face = f.face, g = f.gain;
  final es = lp.eyeSize * feat, eg = lp.eyeGap;

  // No face patch: the features sit directly on the body volume. Cheeks are
  // three nested soft layers (diffused blush), lifting with the smile.
  final cheekY = 26 - face.smile * 4; // smile lifts the cheeks
  final cheekBase = (face.blush * 150).round().clamp(0, 255).toInt();
  for (final i in [-1, 1]) {
    final cc = Offset(i * 44.0 * eg, cheekY);
    c.drawOval(Rect.fromCenter(center: cc, width: 36 * lp.cheek, height: 21 * lp.cheek),
        Paint()..color = const Color(0xFFFF9A86).withAlpha((cheekBase * .35).round())); // brand coral blush
    c.drawOval(Rect.fromCenter(center: cc, width: 27 * lp.cheek, height: 15 * lp.cheek),
        Paint()..color = const Color(0xFFFF8A70).withAlpha((cheekBase * .6).round()));
    c.drawOval(Rect.fromCenter(center: cc, width: 18 * lp.cheek, height: 10 * lp.cheek),
        Paint()..color = const Color(0xFFFF8A70).withAlpha(cheekBase));
  }

  // Gaze travel with a physical minimum (spec 2B: ≥3 dp bust, ≥5 dp full).
  final travel = gazeTravelDesign(f.lod, k, g);
  final gx = f.eyeX * travel, gy = f.eyeY * travel * .8;
  var open = f.blinkOpen;
  if (f.listening) open = (open + f.micLevel * .2).clamp(0.0, 1.4).toDouble(); // eyes widen with the voice
  final pupilBoost = (f.emo == 'excited' || f.emo == 'curious') ? 1.18 : 1.0;

  for (final i in [-1, 1]) {
    final ex = i * 26.0 * eg, ey = -6.0;
    if (f.happyEyes) {
      c.drawArc(Rect.fromCenter(center: Offset(ex, ey + 4), width: 20 * es, height: 15 * es), math.pi, math.pi, false,
          Paint()..color = ink..style = PaintingStyle.stroke..strokeWidth = 4..strokeCap = StrokeCap.round);
    } else {
      final ew = 34 * es, eh = 38 * es; // round, open eyes with matched proportions
      final rect = Rect.fromCenter(center: Offset(ex, ey), width: ew, height: eh);
      c.drawOval(rect, Paint()..color = Colors.white); // sclera
      c.save();
      c.clipPath(Path()..addOval(rect));
      final px = ex + gx, py = ey + gy;
      c.drawCircle(Offset(px, py), 9.5 * es * pupilBoost, Paint()..color = const Color(0xFF0D5C66)); // iris: deep sea teal
      c.drawCircle(Offset(px, py), 4.8 * es * pupilBoost, Paint()..color = ink); // pupil
      c.drawCircle(Offset(px - 3 * es, py - 4 * es), 3 * es, Paint()..color = Colors.white); // catchlights
      c.drawCircle(Offset(px + 3.5 * es, py + 3 * es), 1.4 * es, Paint()..color = Colors.white.withAlpha(220));
      c.drawArc(Rect.fromCenter(center: Offset(ex, ey - 3), width: ew, height: eh), math.pi * 1.15, math.pi * .7, false,
          Paint()..color = ink.withAlpha(35)..style = PaintingStyle.stroke..strokeWidth = 3..strokeCap = StrokeCap.round); // soft lid shadow
      final shut = (1 - open).clamp(0.0, 1.0).toDouble(); // lids: droop when sleepy, lag gaze
      if (shut > .01) {
        final lid = Paint()..color = f.color;
        c.drawRect(Rect.fromLTRB(rect.left, rect.top, rect.right, rect.top + rect.height * shut), lid);
        c.drawRect(Rect.fromLTRB(rect.left, rect.bottom - rect.height * shut * .35, rect.right, rect.bottom), lid);
      }
      c.restore();
      c.drawOval(rect, Paint()..color = ink.withAlpha(f.highContrast ? 90 : 28)..style = PaintingStyle.stroke..strokeWidth = 1.5);
    }
    _brow(c, f, lp, k, ink, i, ex, ey, feat);
  }
  _mouth(c, f, ink, feat);
}

void _brow(Canvas c, DirectorFrame f, LookParams lp, double k, Color ink, int i, double ex, double ey, double feat) {
  // Soft short strokes, never harsh wedges. Same expression math (inner ends
  // rise with concern, the right brow takes the curious one-up), drawn as a
  // thin rounded arc at reduced alpha so it reads as plush, not inked.
  var be = browEnds(f.face, f.gain);
  var inner = be.inner - (i > 0 ? f.face.browAsym * 6 * f.gain : 0);
  var outer = be.outer;
  final diff = outer - inner; // brow difference between emotions, boosted to ≥3 dp at bust
  if (diff.abs() > .01 && f.lod == MiloLod.bust) {
    final need = 3 / math.max(k, 1e-3);
    if (diff.abs() < need) { final m = (inner + outer) / 2, sc = need / diff.abs(); inner = m + (inner - m) * sc; outer = m + (outer - m) * sc; }
  }
  final by = ey - 30 * feat + f.face.browY * f.gain;
  final arch = lp.browArch * 6 * feat;
  final x0 = ex - i * 12.0 * feat, x1 = ex + i * 12.0 * feat; // outer, inner
  final p0 = Offset(x0, by + outer - arch * .3), p1 = Offset(x1, by + inner - arch);
  final mid = Offset((x0 + x1) / 2, (p0.dy + p1.dy) / 2 - arch * .5);
  c.drawPath(Path()..moveTo(p0.dx, p0.dy)..quadraticBezierTo(mid.dx, mid.dy, p1.dx, p1.dy),
      Paint()..color = ink.withAlpha(f.highContrast ? 255 : 150)..style = PaintingStyle.stroke..strokeWidth = f.highContrast ? 5 : 4.5..strokeCap = StrokeCap.round);
}

void _mouth(Canvas c, DirectorFrame f, Color ink, double feat) {
  final face = f.face, w = face.width * feat, sm = face.smile, m = f.mouth;
  final speaking = f.state.name == 'speaking';
  c.save();
  c.translate(0, 30 * feat);
  final shape = mouthShape(smile: sm, open: m, tongue: f.tongue);
  final stroke = Paint()..color = ink..style = PaintingStyle.stroke..strokeWidth = 3.5..strokeCap = StrokeCap.round;
  final dark = Paint()..color = const Color(0xFF0A3F38); // mouth interior: deep teal ink
  switch (shape) {
    case MouthShape.tongue:
      final p = Path()..moveTo(-w, 0)..quadraticBezierTo(0, 14, w, 0)..quadraticBezierTo(0, 14 + m * 30 + 8, -w, 0)..close();
      c.drawPath(p, dark);
      c.save();
      c.clipPath(p);
      c.drawOval(Rect.fromCenter(center: Offset(0, 10 + m * 22), width: w * 1.1, height: 14), Paint()..color = const Color(0xFFFF8A70));
      c.restore();
    case MouthShape.frown:
      c.drawPath(Path()..moveTo(-w, 6)..quadraticBezierTo(0, 6 + sm * 16, w, 6), stroke);
    case MouthShape.flat:
      c.drawLine(Offset(-w * .9, 0), Offset(w * .9, 0), stroke);
    case MouthShape.openA || MouthShape.openO || MouthShape.bigSmile:
      final jaw = m * (shape == MouthShape.openO ? 30 : 38);
      final p = Path()..moveTo(-w, 0)..quadraticBezierTo(0, sm * 14, w, 0)
          ..quadraticBezierTo(0, sm * 14 + jaw + (sm > 0 ? sm * 6 : 0), -w, 0)..close();
      c.drawPath(p, dark);
      if (m > .5 || f.tongue) {
        c.save();
        c.clipPath(p);
        c.drawOval(Rect.fromCenter(center: Offset(0, sm * 8 + m * 26), width: w * 1.1, height: 12), Paint()..color = const Color(0xFFFF8A70));
        c.restore();
      }
    case MouthShape.smile || MouthShape.rest:
      final p = Path()..moveTo(-w, 0)..quadraticBezierTo(0, sm * 16, w, 0);
      if (m > .08) {
        p.quadraticBezierTo(0, sm * 16 + m * 34 + (sm > 0 ? sm * 6 : 0), -w, 0);
        p.close();
        c.drawPath(p, dark);
      } else if (isPressedShut(open: m, speaking: speaking)) {
        c.drawLine(Offset(-w * 1.1, 1), Offset(w * 1.1, 1), stroke); // pressed M/B/P
      } else {
        c.drawPath(p, stroke);
      }
    case MouthShape.closedMBP:
      c.drawLine(Offset(-w * 1.1, 1), Offset(w * 1.1, 1), stroke);
  }
  c.restore();
}

void _t(Canvas c, String s, Offset o, double sz, Color col) {
  final tp = TextPainter(text: TextSpan(text: s, style: TextStyle(fontSize: sz, color: col)), textDirection: TextDirection.ltr)..layout();
  tp.paint(c, o - Offset(tp.width / 2, tp.height / 2));
}

void _fx(Canvas c, DirectorFrame f) {
  final t = f.clock, fx = f.fx;
  if (fx == 'dots') {
    for (var i = 0; i < 3; i++) {
      final al = .35 + .65 * ((math.sin(t * 5 - i * .9) + 1) / 2);
      c.drawCircle(Offset(44 + i * 14.0, -170), 4.5, Paint()..color = Colors.blueGrey.withAlpha((al * 220).round()));
    }
  }
  if (fx == 'arcs') {
    final m = f.listening ? (.45 + .55 * f.micLevel.clamp(0.0, 1.0)) : 1.0;
    final al = (((math.sin(t * 5) + 1) / 2 * 150 + 60) * m).round();
    for (final r in [92.0, 106.0]) {
      final p = Paint()..color = const Color(0xFF149E87).withAlpha(al)..style = PaintingStyle.stroke..strokeWidth = 4..strokeCap = StrokeCap.round; // listening arcs: brand teal
      final rect = Rect.fromCircle(center: const Offset(0, -78), radius: r);
      c.drawArc(rect, -.6, 1.2, false, p);
      c.drawArc(rect, math.pi - .6, 1.2, false, p);
    }
  }
  if (fx == 'zzz') {
    for (var i = 0; i < 3; i++) {
      final ph = (t * .5 + i / 3) % 1.0;
      _t(c, 'z', Offset(56 + ph * 18, -150 - ph * 50), 14 + i * 3.0, Colors.indigo.withAlpha(((1 - ph) * 220).round()));
    }
  }
  for (final p in f.parts) {
    final al = (1 - p.age / p.life).clamp(0.0, 1.0);
    final col = p.ch == '♥' ? const Color(0xFFFF7A7A) : p.ch == '♪' ? const Color(0xFF149E87) : const Color(0xFFFFC857);
    _t(c, p.ch, Offset(p.x, p.y), 20, col.withAlpha((al * 255).round()));
  }
}

/// Header-chip avatar: head only, features 1.25×, tiny sprout. Same Milo.
void _paintAvatar(Canvas c, Size s, DirectorFrame f) {
  final k = math.min(s.width, s.height) / 120;
  final lp = kLooks[f.look]!;
  const ink = Color(0xFF1F2340);
  c.save();
  c.translate(s.width / 2 + f.headX * f.gain * k, s.height / 2 + f.headY * f.gain * k);
  c.scale(k);
  HSLColor h() => HSLColor.fromColor(f.color);
  final dark = h().withLightness((h().lightness - .16).clamp(0.0, 1.0).toDouble()).toColor();
  final light = h().withLightness((h().lightness + .2).clamp(0.0, 1.0).toDouble()).toColor();
  final head = Rect.fromCircle(center: Offset.zero, radius: 54);
  c.drawCircle(Offset.zero, 54, Paint()..shader = RadialGradient(center: const Alignment(-.35, -.55), radius: 1.05, colors: [light, f.color, dark], stops: const [0, .5, 1]).createShader(head));
  c.drawCircle(Offset(-12, -16), 30, Paint()..color = Colors.white.withAlpha(38)); // soft key-light sheen, same direction as the body
  if (f.highContrast) {
    c.drawCircle(Offset.zero, 54, Paint()..color = dark.withAlpha(150)..style = PaintingStyle.stroke..strokeWidth = 2.5);
  }
  c.drawPath(Path()..moveTo(0, -52)..quadraticBezierTo(4, -68, 0, -80),
      Paint()..color = const Color(0xFF34C38F)..style = PaintingStyle.stroke..strokeWidth = 6..strokeCap = StrokeCap.round);
  c.drawOval(const Rect.fromLTWH(-26, -88, 24, 11), Paint()..color = const Color(0xFF2FB584));
  c.drawOval(const Rect.fromLTWH(2, -88, 24, 11), Paint()..color = const Color(0xFF2FB584));
  _face(c, s, f, lp, k, ink, 1.25);
  c.restore();
}
