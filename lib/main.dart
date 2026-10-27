import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/providers.dart';
import 'data/db.dart';
import 'data/secure_store.dart';
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
      builder: (c, w) => MediaQuery(data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(d.textScale)), child: w!), // text scales to 200%
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

  @override
  Widget build(BuildContext context) {
    final d = ref.watch(directorProvider);
    final tab = ref.watch(tabProvider), ladder = ref.watch(ladderProvider), syncBanner = ref.watch(syncBannerProvider);
    ref.listen<int>(tabProvider, (_, n) => d.setTab(n));
    final banner = switch (ladder) { Ladder.offline => 'Offline. Your essentials are ready.', Ladder.resting => 'My thinking cloud is resting. I can still help with what is on your phone.', _ => null };
    return Listener(
      onPointerDown: (e) { d.pointerAt(e.position); if (_first) { _first = false; d.greet(); } }, // eyes look where you touch
      onPointerMove: (e) => d.pointerAt(e.position),
      child: Scaffold(
        bottomNavigationBar: NavigationBar(selectedIndex: tab, onDestinationSelected: (i) => ref.read(tabProvider.notifier).state = i, destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.explore_outlined), selectedIcon: Icon(Icons.explore), label: 'Explore'),
          NavigationDestination(icon: Icon(Icons.chat_bubble_outline), selectedIcon: Icon(Icons.chat_bubble), label: 'Milo'),
          NavigationDestination(icon: Icon(Icons.bar_chart_outlined), selectedIcon: Icon(Icons.bar_chart), label: 'Progress'),
          NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More'),
        ]),
        body: SafeArea(child: Overlays(bottomPad: 8, child: Column(children: [
          if (banner != null) Container(width: double.infinity, color: T.amberSoft, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8), child: Row(children: [const Icon(Icons.cloud_off, size: 18), const SizedBox(width: 8), Expanded(child: Text(banner, style: const TextStyle(fontWeight: FontWeight.w600)))])),
          if (syncBanner != null) Container(width: double.infinity, color: T.amberSoft, padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4), child: Row(children: [const Icon(Icons.sync_problem, size: 18), const SizedBox(width: 8), Expanded(child: Text(syncBanner, style: const TextStyle(fontWeight: FontWeight.w600))),
            TextButton(onPressed: _sync, child: const Text('Retry')), IconButton(tooltip: 'Dismiss', onPressed: () => ref.read(syncBannerProvider.notifier).state = null, icon: const Icon(Icons.close, size: 18))])),
          Padding(padding: const EdgeInsets.fromLTRB(12, 2, 8, 0), child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
            IconButton(tooltip: 'Break', onPressed: () => openScreen('break'), icon: const Icon(Icons.bedtime_outlined)),
            FilledButton.tonal(style: FilledButton.styleFrom(minimumSize: const Size(0, 40), backgroundColor: T.coralSoft, foregroundColor: T.coral), onPressed: () => showHelpSheet(context, ref), child: const Text('Help me')),
          ])),
          Expanded(child: IndexedStack(index: tab, children: const [HomeScreen(), ExploreScreen(), ChatScreen(), ProgressScreen(), MoreScreen()])),
        ]))),
      ),
    );
  }
}
