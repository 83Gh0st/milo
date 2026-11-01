import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/ui/segment_overlay.dart';

void main() {
  test('validateRegions clamps, drops degenerate, caps count', () {
    expect(validateRegions(null), isEmpty);
    expect(validateRegions('nope'), isEmpty);
    final rs = validateRegions([
      {'id': 'r1', 'label': 'heart', 'box': [0.1, 0.2, 0.4, 0.5], 'object_id': '1'},
      {'id': 'r2', 'label': '  ', 'box': [0, 0, 1, 1]}, // empty label dropped
      {'id': 'r3', 'label': 'dot', 'box': [0.5, 0.5, 0.51, 0.51]}, // degenerate dropped
      {'id': 'r4', 'label': 'wide', 'box': [-1, -1, 2, 2]}, // clamped, kept
      {'id': 'r5', 'label': 'bad', 'box': ['x', 0, 1, 1]}, // non-numeric dropped
    ]);
    expect(rs.map((r) => r.id), ['r1', 'r4']);
    expect(rs[1].box, const Rect.fromLTRB(0, 0, 1, 1));
    final many = validateRegions([for (var i = 0; i < 30; i++) {'id': 'r$i', 'label': 'thing', 'box': [0, 0, 1, 1]}]);
    expect(many.length, 20);
  });

  testWidgets('overlay draws tappable labeled regions over the photo', (t) async {
    String? tapped;
    await t.pumpWidget(MaterialApp(
        home: Scaffold(
            body: SegmentOverlay(
                imageBytes: Uint8List(8), // corrupt bytes: fallback art, boxes still render
                imageAspect: 1.5,
                regions: validateRegions([
                  {'id': 'r1', 'label': 'heart', 'box': [0.1, 0.2, 0.4, 0.5]},
                  {'id': 'r2', 'label': 'lung', 'box': [0.5, 0.2, 0.9, 0.6]},
                ]),
                selectedId: 'r1',
                onRegionTap: (id) => tapped = id))));
    await t.pump();
    expect(find.text('heart'), findsOneWidget);
    expect(find.text('lung'), findsOneWidget);
    // Accessibility contract, asserted on the widget configuration (not tree
    // assembly internals): each region is an explicit button node with an
    // "Explain <label>" announcement for screen readers.
    final region = find.byType(Semantics).evaluate().map((e) => e.widget as Semantics).where((s) => s.properties.label == 'Explain heart').single;
    expect(region.container, isTrue);
    expect(region.properties.button, isTrue);
    await t.tap(find.text('lung'));
    await t.pump();
    expect(tapped, 'r2');
    expect(t.takeException(), isNull);
  });
}
