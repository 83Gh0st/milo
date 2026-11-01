// Real UI captures for the hackathon submission: pumps actual screens with
// the standard fakes and saves widget-tree PNGs to screenshots/. These are
// tester renders (no device chrome, no status bar) — honest widget captures,
// labeled as such in screenshots/README.md. Device captures remain manual;
// the runbook + driver sketch live in that README.
// Runs in CI (needs loopback, like all flutter tests); writes are local only.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:milo/companion/director.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/data/secure_store.dart';
import 'package:milo/genui/panel.dart';
import 'package:milo/genui/widgets.dart';
import 'package:milo/net/api.dart';
import 'package:milo/ui/chat_screen.dart';
import 'package:milo/ui/express_screen.dart';
import 'package:milo/ui/home_screen.dart';
import 'package:milo/ui/intro.dart';
import 'package:milo/ui/more_screen.dart';
import 'package:milo/ui/segment_overlay.dart';
import 'package:milo/ui/trusted_screen.dart';
import 'package:milo/ui/understand_screen.dart';

import 'helpers/fake_db.dart';
import 'helpers/harness.dart';

Future<void> capture(WidgetTester t, ProviderContainer c, Widget screen, String name, {int settleMs = 200}) async {
  mockConnectivity(t);
  t.view.physicalSize = const Size(393 * 3, 852 * 3);
  t.view.devicePixelRatio = 3.0;
  final key = GlobalKey();
  await t.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Builder(
              builder: (c2) => MediaQuery(
                  data: MediaQuery.of(c2).copyWith(textScaler: TextScaler.linear(1.0)),
                  child: Scaffold(body: RepaintBoundary(key: key, child: screen)))))));
  await t.pump();
  await t.pump(Duration(milliseconds: settleMs));
  final boundary = key.currentContext!.findRenderObject() as RenderRepaintBoundary;
  final im = await boundary.toImage(pixelRatio: 2.0);
  final raw = (await im.toByteData(format: ui.ImageByteFormat.rawRgba))!;
  final png = img.encodePng(img.Image.fromBytes(width: im.width, height: im.height, bytes: raw.buffer, numChannels: 4));
  final f = File('screenshots/$name.png')..writeAsBytesSync(png);
  expect(f.lengthSync(), greaterThan(1000));
  expect(t.takeException(), isNull);
  await t.pumpWidget(Container()); // unmount between captures: no state carries over visually
  await t.pump();
  t.view.resetPhysicalSize();
  t.view.resetDevicePixelRatio();
}

void main() {
  testWidgets('capture submission screenshots', (t) async {
    Directory('screenshots').createSync(recursive: true);
    await loadLexend();
    final db = FakeDb();
    final c = ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      storeProvider.overrideWithValue(SecureStore()),
      directorProvider.overrideWith((_) => Director()),
      apiProvider.overrideWithValue(FakeApi(db, SecureStore())),
      syncProvider.overrideWithValue(FakeSync(db, FakeApi(db, SecureStore()), SecureStore())),
      connectionCheckProvider.overrideWith((_) => Future.value(const ConnStatus(apiBase: 'http://test', ok: true, provider: 'mock', brainMode: 'json', budgetOk: true, words: 'Connected.'))),
    ]);

    await capture(t, c, const MiloIntro(), '01-intro', settleMs: 800); // mid-veil: mascot + wordmark
    c.read(introDoneProvider.notifier).state = true; // veil done for the rest
    await capture(t, c, const HomeScreen(), '02-home');
    c.read(chatProvider.notifier)
      ..user('What do I need for school?')
      ..said('Let us pack together.')
      ..addSteps(['Water bottle', 'Lunch box', 'Shoes on']);
    await capture(t, c, const ChatScreen(), '03-chat');
    await capture(t, c, const UnderstandScreen(), '04-understand');
    await capture(t, c, const ExpressScreen(), '05-express');
    await capture(t, c, const AccessibilityScreen(), '06-accessibility');
    await capture(t, c, const ProviderKeyScreen(), '07-connections');
    await capture(t, c, const AboutScreen(), '08-about');
    await capture(
        t,
        c,
        PanelView(
            panel: const PanelState(activity: 'school-prep', intent: 'guide', mode: 'activity', root: {
              'id': 'panel',
              'type': 'card',
              'title': 'Get ready for school',
              'children': [
                {'id': 't1', 'type': 'text', 'text': 'Let us pack your bag.'},
                {
                  'id': 'cl',
                  'type': 'checklist',
                  'items': [
                    {'id': 'i1', 'text': 'Water bottle', 'done': true},
                    {'id': 'i2', 'text': 'Lunch box'}
                  ]
                },
                {'id': 'g1', 'type': 'genimage', 'prompt': 'a friendly school backpack', 'alt': 'A teal cartoon backpack smiling'},
              ]
            }),
            cb: PanelCallbacks(ask: (_) {}, speak: (_) {}, openScreen: (_) {}, showImage: (_) async {}, generateImage: (_) async {})),
        '09-genui-panel');
    await capture(
        t,
        c,
        SegmentOverlay(
            imageBytes: Uint8List(8),
            imageAspect: 1.5,
            regions: validateRegions([
              {'id': 'r1', 'label': 'heart', 'box': [0.1, 0.2, 0.4, 0.5]},
              {'id': 'r2', 'label': 'lung', 'box': [0.5, 0.2, 0.9, 0.6]},
            ]),
            selectedId: 'r1',
            onRegionTap: (_) {}),
        '10-segment-fixture');
    c.read(ladderProvider.notifier).failed('offline');
    await capture(t, c, const ExpressScreen(), '11-offline');
    c.dispose();
  });
}
