import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'director.dart';
import 'emotion.dart';

/// Renderer B (doc 5.8): Milo drawn from vector shapes with spring physics. No assets, no editor.
/// Swap for a Rive renderer later behind the same Director inputs.
class MiloPainter extends CustomPainter {
  final Director d;
  MiloPainter(this.d) : super(repaint: d.frame);
  static const ink = Color(0xFF1F2340);

  Color _sh(Color c, double l) { final h = HSLColor.fromColor(c); return h.withLightness((h.lightness + l).clamp(0.0, 1.0).toDouble()).toColor(); }
  void _t(Canvas c, String s, Offset o, double sz, Color col) {
    final tp = TextPainter(text: TextSpan(text: s, style: TextStyle(fontSize: sz, color: col)), textDirection: TextDirection.ltr)..layout();
    tp.paint(c, o - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas c, Size s) {
    final k = math.min(s.width / 260, s.height / 300);
    c.save(); c.translate(s.width / 2, s.height * .94); c.scale(k);
    final f = d.face, col = d.color, a = d.amp;
    final up = (-d.hop.x / 120).clamp(0.0, 1.0).toDouble();
    c.drawOval(Rect.fromCenter(center: const Offset(0, 3), width: 120 * (1 - .4 * up), height: 14 * (1 - .4 * up)), Paint()..color = Colors.black.withAlpha(40));
    c.save();
    c.translate(0, d.hop.x); c.rotate(d.lean.x);
    final sy = 1 + d.br * .015 + d.sq.x + d.ch.zoom * a, sx = 1 - (sy - 1) * .7 + d.ch.jig * a;
    c.scale(sx, sy);
    final dark = _sh(col, -.16), light = _sh(col, .2);
    for (final i in [-1, 1]) { c.drawOval(Rect.fromCenter(center: Offset(i * 26.0, -6), width: 38, height: 18), Paint()..color = dark); }
    final body = Rect.fromCenter(center: const Offset(0, -76), width: 130, height: 138);
    c.drawOval(body, Paint()..shader = RadialGradient(center: const Alignment(-.35, -.55), radius: 1.05, colors: [light, col, dark], stops: const [0, .55, 1]).createShader(body));
    c.drawOval(Rect.fromCenter(center: const Offset(0, -46), width: 72, height: 54), Paint()..color = Colors.white.withAlpha(60));
    c.drawOval(Rect.fromCenter(center: const Offset(-22, -118), width: 44, height: 24), Paint()..color = Colors.white.withAlpha(95)); // glossy highlight
    _sprout(c, f);
    c.save(); c.translate(d.headX.x, -80 + d.headY.x); _face(c, f); c.restore();
    _arm(c, -1, d.armL.x, dark, col); _arm(c, 1, d.armR.x, dark, col);
    c.restore();
    _fx(c);
    c.restore();
  }

  void _arm(Canvas c, int side, double a, Color dark, Color col) {
    final sx = side * 56.0, sy = -70.0, hx = sx + side * math.sin(a) * 30, hy = sy + math.cos(a) * 30;
    final p = Path()..moveTo(sx, sy)..quadraticBezierTo((sx + hx) / 2 + side * 6, (sy + hy) / 2, hx, hy);
    c.drawPath(p, Paint()..color = dark..style = PaintingStyle.stroke..strokeWidth = 13..strokeCap = StrokeCap.round);
    c.drawCircle(Offset(hx, hy), 11, Paint()..color = col);
  }

  void _sprout(Canvas c, Face f) {
    final double len = (20 + 8 * f.perk.clamp(-1.0, 1.0)).toDouble();
    var p = const Offset(0, -140);
    var a = 0.0;
    final pts = [p];
    final angs = <double>[];
    for (final s in [d.s1, d.s2, d.s3]) { a += s.x; angs.add(a); p = p + Offset(math.sin(a) * len, -math.cos(a) * len); pts.add(p); }
    final path = Path()..moveTo(pts[0].dx, pts[0].dy);
    for (final q in pts.skip(1)) { path.lineTo(q.dx, q.dy); }
    c.drawPath(path, Paint()..color = const Color(0xFF34C38F)..style = PaintingStyle.stroke..strokeWidth = 6..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round);
    final leaf = Paint()..color = const Color(0xFF2FB584);
    for (final i in [1, 2]) {
      for (final rot in [angs[i] - .7, angs[i] - math.pi + .7]) {
        c.save(); c.translate(pts[i + 1].dx, pts[i + 1].dy); c.rotate(rot);
        c.drawOval(const Rect.fromLTWH(0, -5, 22, 10), leaf); c.restore();
      }
    }
  }

  void _face(Canvas c, Face f) {
    final open = (f.eye * d.bf * (1 - d.ch.eyes * .95) * (1 - d.ch.yawn * .6)).clamp(.05, 1.4).toDouble();
    final happy = f.happyEyes || d.ch.eyes > .5;
    for (final i in [-1, 1]) {
      final ex = i * 24.0;
      const ey = -8.0;
      if (happy) {
        c.drawArc(Rect.fromCenter(center: Offset(ex, ey + 3), width: 18, height: 14), math.pi, math.pi, false,
            Paint()..color = ink..style = PaintingStyle.stroke..strokeWidth = 3.5..strokeCap = StrokeCap.round);
      } else {
        final gx = d.eyeX.x * 4.5, gy = d.eyeY.x * 3.5; // eyes lead, head follows
        c.drawOval(Rect.fromCenter(center: Offset(ex + gx, ey + gy), width: 17, height: 24 * open), Paint()..color = ink);
        c.drawCircle(Offset(ex + gx - 3, ey + gy - 5 * open), 3, Paint()..color = Colors.white);
      }
      final by = ey - 21 + f.browY;
      c.drawLine(Offset(ex - i * 8.0, by - f.browA * 6), Offset(ex + i * 8.0, by + f.browA * 6), Paint()..color = ink..strokeWidth = 3.5..strokeCap = StrokeCap.round);
      c.drawOval(Rect.fromCenter(center: Offset(i * 40.0, 10), width: 15, height: 9), Paint()..color = const Color(0xFFFF7A7A).withAlpha((f.blush * 170).round().clamp(0, 255).toInt()));
    }
    _mouth(c, f);
  }

  void _mouth(Canvas c, Face f) {
    final w = f.width * (.9 + (d.vis && d.pulse > .2 ? .2 : 0)), sm = f.smile, m = d.mouth;
    c.save(); c.translate(0, 24);
    final p = Path()..moveTo(-w, 0)..quadraticBezierTo(0, sm * 16, w, 0);
    if (m > .08) {
      p.quadraticBezierTo(0, sm * 16 + m * 40 + (sm > 0 ? sm * 6 : 0), -w, 0); p.close();
      c.drawPath(p, Paint()..color = const Color(0xFF3B1E3F));
      if (f.tongue || m > .5) {
        c.save(); c.clipPath(p);
        c.drawOval(Rect.fromCenter(center: Offset(0, sm * 8 + m * 30), width: w * 1.1, height: 12), Paint()..color = const Color(0xFFFF8FA3));
        c.restore();
      }
    } else {
      c.drawPath(p, Paint()..color = ink..style = PaintingStyle.stroke..strokeWidth = 3.5..strokeCap = StrokeCap.round);
    }
    c.restore();
  }

  void _fx(Canvas c) {
    final t = d.clock, f = d.fx;
    if (f == 'dots') {
      for (var i = 0; i < 3; i++) {
        final al = .35 + .65 * ((math.sin(t * 5 - i * .9) + 1) / 2);
        c.drawCircle(Offset(44 + i * 14.0, -170), 4.5, Paint()..color = Colors.blueGrey.withAlpha((al * 220).round()));
      }
    }
    if (f == 'arcs') {
      final m = d.state == CState.listening ? (.45 + .55 * d.micLevel.clamp(0.0, 1.0)) : 1.0; // listening rings breathe with the voice
      final al = (((math.sin(t * 5) + 1) / 2 * 150 + 60) * m).round();
      for (final r in [92.0, 106.0]) {
        final p = Paint()..color = const Color(0xFF5B6CFF).withAlpha(al)..style = PaintingStyle.stroke..strokeWidth = 4..strokeCap = StrokeCap.round;
        final rect = Rect.fromCircle(center: const Offset(0, -80), radius: r);
        c.drawArc(rect, -.6, 1.2, false, p); c.drawArc(rect, math.pi - .6, 1.2, false, p);
      }
    }
    if (f == 'zzz') {
      for (var i = 0; i < 3; i++) {
        final ph = (t * .5 + i / 3) % 1.0;
        _t(c, 'z', Offset(56 + ph * 18, -150 - ph * 50), 14 + i * 3.0, Colors.indigo.withAlpha(((1 - ph) * 220).round()));
      }
    }
    for (final p in d.parts) {
      final al = (1 - p.age / p.life).clamp(0.0, 1.0);
      final col = p.ch == '♥' ? const Color(0xFFFF7A7A) : p.ch == '♪' ? const Color(0xFF5B6CFF) : const Color(0xFFFFC857);
      _t(c, p.ch, Offset(p.x, p.y), 20, col.withAlpha((al * 255).round()));
    }
  }

  @override
  bool shouldRepaint(covariant MiloPainter old) => old.d != d;
}
