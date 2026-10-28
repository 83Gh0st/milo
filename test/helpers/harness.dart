import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 0 layout harness (the Phase 1 matrix in brief §4 builds on this).
const kHarnessSizes = {'small': Size(360, 640), 'standard': Size(393, 852), 'large': Size(412, 915)};

/// Loads bundled Lexend so widget/golden text renders as glyphs, not boxes.
Future<void> loadLexend() async {
  final loader = FontLoader('Lexend')..addFont(rootBundle.load('assets/fonts/Lexend-Regular.ttf'));
  await loader.load();
}

/// Pumps [child] (already wrapped in any providers it needs) inside a plain
/// MaterialApp at every harness size and text scale, then runs [check].
/// Surfaces reset after each case. Fails on any render overflow.
Future<void> pumpAtSizes(WidgetTester t, Widget child, {List<double> scales = const [1.0, 2.0], void Function()? check}) async {
  for (final e in kHarnessSizes.entries) {
    for (final s in scales) {
      t.view.physicalSize = Size(e.value.width * 3, e.value.height * 3);
      t.view.devicePixelRatio = 3.0;
      await t.pumpWidget(MaterialApp(home: Builder(builder: (c) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(s)), child: child))));
      await t.pumpAndSettle();
      check?.call();
      expect(t.takeException(), isNull, reason: '${e.key} @${s}x');
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    }
  }
}

/// Phase 1 overlap guard: two on-screen regions must not intersect.
void expectNoOverlap(WidgetTester t, Finder a, Finder b) {
  expect(t.getRect(a).overlaps(t.getRect(b)), isFalse);
}
