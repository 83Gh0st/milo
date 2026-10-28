import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/data/secure_store.dart';
import 'package:milo/net/api.dart';
import 'package:milo/ui/trusted_screen.dart';

import 'helpers/fake_db.dart';
import 'helpers/harness.dart';

ProviderContainer connContainer(FakeDb db, FakeApi api, FakeSync sync) => ProviderContainer(overrides: [
      dbProvider.overrideWithValue(db),
      storeProvider.overrideWithValue(SecureStore()),
      directorProvider.overrideWith((_) => Director()),
      apiProvider.overrideWithValue(api),
      syncProvider.overrideWithValue(sync),
      connectionCheckProvider.overrideWith((_) => Future.value(const ConnStatus(apiBase: 'http://test', ok: true, provider: 'mock', brainMode: 'json', budgetOk: true, words: 'Connected.'))),
    ]);

Future<void> pumpConn(WidgetTester t, ProviderContainer c, {Size size = const Size(360, 640), double scale = 1.0}) async {
  // NOTE: tests dispose their container in-body at the end; addTearDown runs
  // after the binding's pending-timer invariant check, so it cannot be used.
  mockConnectivity(t);
  t.view.physicalSize = Size(size.width * 3, size.height * 3);
  t.view.devicePixelRatio = 3.0;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  await t.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
          home: Builder(
              builder: (c2) => MediaQuery(
                  data: MediaQuery.of(c2).copyWith(textScaler: TextScaler.linear(scale)),
                  // Scaffold mirrors production: fields, checkboxes, switches and dropdowns need Material.
                  child: const Scaffold(body: ProviderKeyScreen()))))));
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 100));
  expect(t.takeException(), isNull);
}

Future<void> settle(WidgetTester t) async {
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 100));
  await t.pump(const Duration(milliseconds: 100));
}

/// Blind-drags [scrollable] until [f] resolves. ListView lazily builds: below-
/// fold children don't exist in the tree, so scrollUntilVisible/ensureVisible
/// throw "No element" before scrolling a pixel. This forces the build first.
Future<void> dragToBuild(WidgetTester t, Finder f, Finder scrollable, {double dy = -400}) async {
  for (var i = 0; i < 12 && f.evaluate().isEmpty; i++) {
    await t.drag(scrollable, Offset(0, dy));
    await t.pump();
  }
}

void main() {
  testWidgets('sync off shows the gate, sync on shows the four provider tiles', (t) async {
    var db = FakeDb();
    var api = FakeApi(db, SecureStore());
    final c1 = connContainer(db, api, FakeSync(db, api, SecureStore(), on: false));
    await pumpConn(t, c1);
    expect(find.text('Turn on sync first, in Data and privacy. The sync vault identifies your family.'), findsOneWidget);
    await t.pumpWidget(Container()); // unmount: same-type state would otherwise carry syncOn=false into c2
    await t.pump();
    c1.dispose();

    db = FakeDb();
    api = FakeApi(db, SecureStore());
    final c2 = connContainer(db, api, FakeSync(db, api, SecureStore()));
    await pumpConn(t, c2);
    for (final label in ['Meta (recommended)', 'OpenAI', 'Anthropic', 'Custom or local']) {
      expect(find.text(label, skipOffstage: false), findsOneWidget); // lower tiles start below the fold
    }
    expect(find.text('Not connected', skipOffstage: false), findsNWidgets(4));
    expect(t.takeException(), isNull);
    c2.dispose();
  });

  testWidgets('empty vault at 360x640 scale 2.0: everything reachable, save is honest', (t) async {
    final db = FakeDb();
    final api = FakeApi(db, SecureStore());
    final c = connContainer(db, api, FakeSync(db, api, SecureStore()));
    await pumpConn(t, c, scale: 2.0);
    await dragToBuild(t, find.text('Save choices', skipOffstage: false), find.byType(ListView).first);
    await t.scrollUntilVisible(find.text('Save choices', skipOffstage: false), 50);
    await t.ensureVisible(find.text('Save choices', skipOffstage: false)); // fully visible: partial stops tap offscreen
    await t.pump();
    await t.tap(find.text('Save choices'));
    await settle(t);
    expect(find.text('Connect a provider first.'), findsOneWidget); // no silent mock fallback
    // The sheet opens cleanly at 2.0 too.
    await dragToBuild(t, find.text('Custom or local', skipOffstage: false), find.byType(ListView).first, dy: 400);
    await t.scrollUntilVisible(find.text('Custom or local', skipOffstage: false), 50);
    await t.ensureVisible(find.text('Custom or local', skipOffstage: false));
    await t.pump();
    await t.tap(find.text('Custom or local'));
    await settle(t);
    expect(find.text('Custom or local', skipOffstage: false), findsWidgets);
    expect(t.takeException(), isNull);
    c.dispose();
  });

  testWidgets('ack flow: refusal surfaces the checkbox, ack saves the key', (t) async {
    final db = FakeDb();
    final api = FakeApi(db, SecureStore());
    final c = connContainer(db, api, FakeSync(db, api, SecureStore()));
    await pumpConn(t, c);
    await t.ensureVisible(find.text('OpenAI', skipOffstage: false));
    await t.pump();
    await t.tap(find.text('OpenAI'));
    await settle(t);
    await t.enterText(find.byType(TextField).first, 'sk-test-key-12345678');
    await t.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(t);
    await t.ensureVisible(find.text('Please confirm the data note first.', skipOffstage: false));
    await t.pump();
    expect(find.text('Please confirm the data note first.'), findsOneWidget);
    expect(find.text('I understand my data may train their models'), findsOneWidget);
    expect(api.savedConns, isEmpty); // refused: nothing stored
    await t.ensureVisible(find.byType(CheckboxListTile, skipOffstage: false));
    await t.pump();
    await t.tap(find.byType(CheckboxListTile));
    await t.pump();
    await t.tap(find.widgetWithText(FilledButton, 'Save'));
    await settle(t);
    expect(api.savedConns.map((c) => c['provider']), ['openai']);
    await t.ensureVisible(find.textContaining('Key …5678', skipOffstage: false));
    await t.pump();
    expect(find.textContaining('Key …5678'), findsOneWidget);
    // The family switch is usable now and persists the flag.
    await t.ensureVisible(find.byType(SwitchListTile, skipOffstage: false));
    await t.pump();
    await t.tap(find.byType(SwitchListTile));
    await settle(t);
    expect(await db.get('ai.family_key'), 'family');
    expect(t.takeException(), isNull);
    c.dispose();
  });

  testWidgets('test checklist shows pass and fail honestly; models picker fills the field', (t) async {
    final db = FakeDb();
    final api = FakeApi(db, SecureStore());
    api.savedConns.add({'provider': 'openai', 'base_url': '', 'hint': '…5678', 'default_model': 'fake-model',
      'policy': {'trains_on_data': 'unknown', 'needs_ack': true, 'note': 'Fake policy for tests.'}});
    final c = connContainer(db, api, FakeSync(db, api, SecureStore()));
    await pumpConn(t, c);
    await t.ensureVisible(find.text('OpenAI', skipOffstage: false));
    await t.pump();
    await t.tap(find.text('OpenAI'));
    await settle(t);
    await t.ensureVisible(find.text('Test connection', skipOffstage: false).first);
    await t.pump();
    await t.tap(find.text('Test connection'));
    await settle(t);
    for (final row in ['Chat', 'Structured replies', 'Pictures']) {
      // .last: 'Pictures' is also a route-cap label behind the sheet; the checklist row paints later.
      await t.ensureVisible(find.text(row, skipOffstage: false).last);
      await t.pump();
      expect(find.text(row, skipOffstage: false).last, findsOneWidget);
    }
    await t.ensureVisible(find.text('Find', skipOffstage: false).first);
    await t.pump();
    await t.tap(find.text('Find'));
    await settle(t);
    expect(find.text('Pick a model'), findsOneWidget);
    await t.tap(find.text('fake-model-b'));
    await settle(t);
    expect(find.text('fake-model-b'), findsOneWidget); // model field filled, dialog closed

    api.failProbe = true;
    await t.ensureVisible(find.text('Test connection', skipOffstage: false).first);
    await t.pump();
    await t.tap(find.text('Test connection'));
    await settle(t);
    await t.ensureVisible(find.text('Chat', skipOffstage: false).first);
    await t.pump();
    expect(find.text('Chat'), findsOneWidget); // fail row still labelled, no crash
    expect(t.takeException(), isNull);
    c.dispose();
  });

  testWidgets('routes save through to the fake vault; remove disconnects', (t) async {
    final db = FakeDb();
    final api = FakeApi(db, SecureStore());
    api.savedConns.add({'provider': 'openai', 'base_url': '', 'hint': '…5678', 'default_model': 'fake-model', 'policy': {}});
    final c = connContainer(db, api, FakeSync(db, api, SecureStore()));
    await pumpConn(t, c);
    final list = find.byType(ListView).first;
    await dragToBuild(t, find.byType(DropdownButtonFormField<String>, skipOffstage: false).first, list);
    await t.scrollUntilVisible(find.byType(DropdownButtonFormField<String>, skipOffstage: false).first, 50);
    await t.ensureVisible(find.byType(DropdownButtonFormField<String>, skipOffstage: false).first); // fully visible: partial stops tap offscreen
    await t.pump();
    await t.tap(find.byType(DropdownButtonFormField<String>).first); // brain first choice
    await settle(t);
    await t.tap(find.text('openai/fake-model').last);
    await settle(t);
    await dragToBuild(t, find.text('Save choices', skipOffstage: false), list);
    await t.ensureVisible(find.text('Save choices', skipOffstage: false));
    await t.pump();
    await t.tap(find.text('Save choices'));
    await settle(t);
    expect(api.savedRoutes['brain']!.first, {'provider': 'openai', 'model': 'fake-model'});
    expect(find.text('Saved. Milo now uses your choices.'), findsOneWidget);

    await dragToBuild(t, find.text('OpenAI', skipOffstage: false), list, dy: 400);
    await t.ensureVisible(find.text('OpenAI', skipOffstage: false));
    await t.pump();
    await t.tap(find.text('OpenAI'));
    await settle(t);
    await t.ensureVisible(find.text('Remove this connection', skipOffstage: false));
    await t.pump();
    await t.tap(find.text('Remove this connection'));
    await settle(t);
    expect(api.savedConns, isEmpty);
    expect(find.text('Not connected', skipOffstage: false), findsNWidgets(4));
    expect(t.takeException(), isNull);
    c.dispose();
  });
}
