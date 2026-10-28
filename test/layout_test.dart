import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/ui/calm_screens.dart';
import 'package:milo/ui/chat_screen.dart';
import 'package:milo/ui/do_screen.dart';
import 'package:milo/ui/express_screen.dart';
import 'package:milo/ui/explore_screen.dart';
import 'package:milo/ui/home_screen.dart';
import 'package:milo/ui/learn_screen.dart';
import 'package:milo/ui/more_screen.dart';
import 'package:milo/ui/privacy_screens.dart';
import 'package:milo/ui/progress_screen.dart';
import 'package:milo/ui/scaffold.dart';
import 'package:milo/ui/trusted_screen.dart';
import 'package:milo/ui/understand_screen.dart';

import 'helpers/harness.dart';

/// Crowded director state for the matrix: 3 choices, 4-line bubble, speaking.
void _crowd(Director d, {bool left = false}) => d.set(() {
      d.leftHanded = left;
      d.presence = Presence.buddy; // the crowded state is a dock state; stage shows no dock
      d.choices = ['Explain it again', 'Say it simpler', 'Show a picture'];
      d.caption = 'Line one of the bubble.\nLine two keeps going.\nLine three and more.\nLine four is the last.';
      d.state = CState.speaking;
    });

/// Pumps with a memory proposal showing (MemoryConfirm in the dock).
Future<void> _pumpCrowded(WidgetTester t, Widget screen, {required Size size, required double scale, bool left = false}) async {
  final d = Director();
  _crowd(d, left: left);
  final container = ProviderContainer(overrides: screenOverrides(d));
  container.read(memoryProvider).proposeLocal('use short words');
  await pumpScreen(t, screen, size: size, scale: scale, container: container);
  container.dispose();
}

void main() {
  testWidgets('tabs: no overflow across sizes, scales and hands', (t) async {
    await loadLexend();
    const screens = {'home': HomeScreen(), 'explore': ExploreScreen(), 'chat': ChatScreen(), 'progress': ProgressScreen(), 'more': MoreScreen()};
    for (final e in screens.entries) {
      for (final s in kMatrixSizes.entries) {
        for (final scale in [1.0, 2.0]) {
          for (final left in [false, true]) {
            await _pumpCrowded(t, MiloScaffold(title: e.key, kind: e.key, body: e.value), size: s.value, scale: scale, left: left);
          }
        }
      }
    }
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('pushed screens: no overflow', (t) async {
    await loadLexend();
    const screens = [UnderstandScreen(), ExpressScreen(), DoScreen(), LearnScreen(), BreakTimeScreen(), MemoryScreen(), LedgerScreen(), TrustedScreen()];
    final sizes = [kMatrixSizes['small']!, kMatrixSizes['standard']!, kMatrixSizes['tablet']!, kMatrixSizes['landscape']!];
    for (final w in screens) {
      for (final s in sizes) {
        for (final scale in [1.0, 2.0]) {
          await _pumpCrowded(t, w, size: s, scale: scale);
        }
      }
      await _pumpCrowded(t, w, size: kMatrixSizes['small']!, scale: 1.0, left: true);
    }
  }, timeout: const Timeout(Duration(minutes: 15)));

  testWidgets('crowded small screen: every dock control is present', (t) async {
    await loadLexend();
    final d = Director();
    _crowd(d);
    final container = ProviderContainer(overrides: screenOverrides(d));
    container.read(memoryProvider).proposeLocal('use short words');
    await pumpScreen(t, const MiloScaffold(title: 'chat', kind: 'chat', body: ChatScreen()), size: kMatrixSizes['small']!, scale: 2.0, container: container);
    expect(find.byTooltip('Minimise Milo'), findsOneWidget); // dock collapse is always on top
    // The capped dock scrolls: every control must be reachable by scrolling.
    for (final c in ['Explain it again', 'Say it simpler', 'Show a picture']) {
      await t.ensureVisible(find.text(c, skipOffstage: false));
      await t.pump();
      expect(find.text(c), findsOneWidget);
    }
    await t.ensureVisible(find.textContaining('Want me to remember', skipOffstage: false));
    await t.pump();
    expect(find.textContaining('Want me to remember'), findsOneWidget);
    container.dispose();
  });

  testWidgets('dock and rail never cover the header', (t) async {
    await loadLexend();
    await _pumpCrowded(t, const MiloScaffold(title: 'home', kind: 'home', body: HomeScreen()), size: kMatrixSizes['small']!, scale: 1.0);
    expectNoOverlap(t, find.byType(MiloHeader), find.byType(CompanionDock));
    await _pumpCrowded(t, const MiloScaffold(title: 'home', kind: 'home', body: HomeScreen()), size: kMatrixSizes['tablet']!, scale: 1.0);
    expectNoOverlap(t, find.byType(MiloHeader), find.byType(CompanionRail));
    await _pumpCrowded(t, const MiloScaffold(title: 'home', kind: 'home', body: HomeScreen()), size: kMatrixSizes['small']!, scale: 1.0, left: true);
    expectNoOverlap(t, find.byType(MiloHeader), find.byType(CompanionDock));
  });

  testWidgets('tap targets meet guidelines', (t) async {
    await loadLexend();
    await _pumpCrowded(t, const MiloScaffold(title: 'more', kind: 'more', body: MoreScreen()), size: kMatrixSizes['small']!, scale: 1.0);
    await expectLater(t, meetsGuideline(androidTapTargetGuideline));
    await expectLater(t, meetsGuideline(labeledTapTargetGuideline));
  });

  testWidgets('keyboard peeks the dock', (t) async {
    await loadLexend();
    await pumpScreen(t, const MiloScaffold(title: 'chat', kind: 'chat', body: ChatScreen()),
        size: kMatrixSizes['small']!, insets: const EdgeInsets.only(bottom: 300), d: Director());
    expect(find.byTooltip('Show Milo'), findsOneWidget);
    expect(find.byType(CompanionDock), findsNothing);
  });
}
