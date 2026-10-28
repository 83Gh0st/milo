import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers.dart';
import 'data/db.dart';
import 'data/secure_store.dart';
import 'sys/share_in.dart';
import 'ui/chat_screen.dart';
import 'ui/explore_screen.dart';
import 'ui/home_screen.dart';
import 'ui/more_screen.dart';
import 'ui/onboarding.dart';
import 'ui/progress_screen.dart';
import 'ui/screen.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = SecureStore();
  final db = await MiloDb.open(store);
  runApp(ProviderScope(overrides: [storeProvider.overrideWithValue(store), dbProvider.overrideWithValue(db)], child: const MiloApp()));
}

class MiloApp extends ConsumerWidget {
  const MiloApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    return MaterialApp(
      title: 'Milo', debugShowCheckedModeBanner: false, navigatorKey: navKey, theme: miloTheme(d), themeMode: ThemeMode.light, home: const Gate(),
      builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear((MediaQuery.of(c).textScaler.scale(1.0) * d.textScale).clamp(0.85, 2.4).toDouble())), child: w!), // text scales to 200%
    );
  }
}

class Gate extends ConsumerStatefulWidget { const Gate({super.key}); @override ConsumerState<Gate> createState() => _GateState(); }
class _GateState extends ConsumerState<Gate> {
  late Future<String?> _f = ref.read(dbProvider).get('onboarded');
  @override
  Widget build(BuildContext context) => FutureBuilder<String?>(future: _f, builder: (_, s) {
    if (s.connectionState != ConnectionState.done) return const Scaffold(body: SizedBox());
    return s.data == '1' ? const Shell() : Onboarding(onDone: () => setState(() => _f = Future.value('1')));
  });
}

class Shell extends ConsumerStatefulWidget { const Shell({super.key}); @override ConsumerState<Shell> createState() => _ShellState(); }

class _ShellState extends ConsumerState<Shell> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final Ticker _tk;
  Duration _last = Duration.zero;
  bool _first = true;
  Timer? _syncT, _nudgeT;
  DateTime _started = DateTime.now();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final d = ref.read(directorProvider), sync = ref.read(syncProvider);
    d.onOpenScreen = (s) { if (s == 'home') { ref.read(tabProvider.notifier).state = 0; openScreen('home'); } else { openScreen(s); } };
    sync.onApplied = () async => d.loadSettings(await ref.read(dbProvider).allSettings());
    _tk = createTicker((e) { final dt = (e - _last).inMicroseconds / 1e6; _last = e; d.tick(dt); })..start(); // one 60 fps clock for the whole companion
    _syncT = Timer.periodic(const Duration(minutes: 3), (_) => _sync());
    _nudgeT = Timer.periodic(const Duration(minutes: 1), (_) => _breakNudge()); // gentle time limits: set by a grown-up, one suggestion, never forced
    _sync();
    Future.delayed(const Duration(seconds: 3), () { if (mounted && !d.ttsReady) openScreen('novoice'); });
    armShareIn((t) { ref.read(sharedTextProvider.notifier).state = t; if (mounted) openScreen('understand'); }); // plan 7.13: late share while open
    WidgetsBinding.instance.addPostFrameCallback((_) async { // cold start with shared text (no-op without the native side)
      final t = await fetchInitialSharedText();
      if (t.isNotEmpty && mounted) { ref.read(sharedTextProvider.notifier).state = t; openScreen('understand'); }
    });
  }
  Future<void> _sync() async {
    try {
      await ref.read(syncProvider).syncNow();
      ref.read(syncBannerProvider.notifier).state = null;
    } catch (e) {
      ref.read(syncBannerProvider.notifier).state = syncBannerFor(e); // generic text only, never content
    }
  }
  void _breakNudge() {
    final d = ref.read(directorProvider);
    if (d.breakNudgeMin > 0 && DateTime.now().difference(_started).inMinutes >= d.breakNudgeMin && !d.quiet) { _started = DateTime.now(); d.speak('Would you like a little break?'); d.set(() => d.choices = ['Take a break', 'Keep going']); }
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState s) { if (s == AppLifecycleState.resumed) { _sync(); ref.read(ladderProvider.notifier).refresh(); } }
  @override
  void dispose() { WidgetsBinding.instance.removeObserver(this); _syncT?.cancel(); _nudgeT?.cancel(); _tk.dispose(); super.dispose(); }

  Ladder? _said; // Milo speaks once per ladder state change (rate-limited by design)
  @override
  Widget build(BuildContext context) {
    final d = ref.watch(directorProvider);
    final tab = ref.watch(tabProvider);
    ref.listen<int>(tabProvider, (_, n) => d.setTab(n));
    ref.listen<Ladder>(ladderProvider, (_, n) { if (n != _said) { _said = n; if (!d.quiet) d.speak(ladderWords(n)); } });
    const titles = ['Home', 'Explore', 'Milo', 'Progress', 'More'];
    const kinds = ['home', 'explore', 'chat', 'progress', 'more'];
    const tabs = [HomeScreen(), ExploreScreen(), ChatScreen(), ProgressScreen(), MoreScreen()];
    final mq = MediaQuery.sizeOf(context);
    final railMode = winClassOf(mq.width) != WinClass.compact || isWideLayout(mq);
    final hideLabels = d.textScale >= 1.6;
    const dests = [(Icons.home_outlined, Icons.home, 'Home'), (Icons.explore_outlined, Icons.explore, 'Explore'), (Icons.chat_bubble_outline, Icons.chat_bubble, 'Milo'), (Icons.bar_chart_outlined, Icons.bar_chart, 'Progress'), (Icons.more_horiz, Icons.more_horiz, 'More')];
    final indexed = IndexedStack(index: tab, children: [for (var i = 0; i < 5; i++) ProviderScope(overrides: [miloScopeProvider.overrideWithValue(i)], child: MiloScaffold(title: titles[i], kind: kinds[i], body: tabs[i]))]);
    void setTab(int i) => ref.read(tabProvider.notifier).state = i;
    return Listener(
      onPointerDown: (e) { d.pointerAt(e.position); if (_first) { _first = false; d.greet(); } }, // eyes look where you touch
      onPointerMove: (e) => d.pointerAt(e.position),
      child: Scaffold(
        bottomNavigationBar: railMode ? null : NavigationBar(selectedIndex: tab, labelBehavior: hideLabels ? NavigationDestinationLabelBehavior.onlyShowSelected : NavigationDestinationLabelBehavior.alwaysShow, onDestinationSelected: setTab, destinations: [for (final x in dests) NavigationDestination(icon: Icon(x.$1), selectedIcon: Icon(x.$2), label: x.$3)]),
        body: SafeArea(
            child: railMode
                ? Row(children: [
                    if (d.leftHanded) Expanded(child: indexed),
                    NavigationRail(selectedIndex: tab, labelType: hideLabels ? NavigationRailLabelType.selected : NavigationRailLabelType.all, onDestinationSelected: setTab, destinations: [for (final x in dests) NavigationRailDestination(icon: Icon(x.$1), selectedIcon: Icon(x.$2), label: Text(x.$3))]),
                    if (!d.leftHanded) Expanded(child: indexed),
                  ])
                : indexed),
      ),
    );
  }
}
