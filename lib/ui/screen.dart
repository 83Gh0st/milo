import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/providers.dart';
import 'calm_screens.dart';
import 'chat_screen.dart';
import 'do_screen.dart';
import 'express_screen.dart';
import 'failure_screens.dart';
import 'learn_screen.dart';
import 'more_screen.dart';
import 'privacy_screens.dart';
import 'theme.dart';
import 'understand_screen.dart';
import 'widgets.dart';

export 'scaffold.dart'; // presence widgets available everywhere screen.dart is

final navKey = GlobalKey<NavigatorState>();

/// Opens a full screen by name (used by the brain's open_screen action, Home, Explore and hand-offs).
void openScreen(String name, {bool replace = false}) {
  final w = switch (name) {
    'understand' => const UnderstandScreen(), 'express' => const ExpressScreen(), 'do' => const DoScreen(), 'learn' => const LearnScreen(),
    'break' => const BreakTimeScreen(), 'checkin' => const CheckInScreen(), 'memory' => const MemoryScreen(), 'privacy' => const LedgerScreen(),
    'context' => const ContextScreen(), 'unreachable' => const CloudUnreachableScreen(), 'novoice' => const NoVoiceScreen(),
    'accessibility' => const AccessibilityScreen(), _ => null };
  final nav = navKey.currentState;
  if (nav == null) return;
  if (w == null) { nav.popUntil((r) => r.isFirst); return; }
  final route = MaterialPageRoute(builder: (_) => w);
  replace ? nav.pushReplacement(route) : nav.push(route);
}

/// A pushed screen with the wireframe header and Milo's presence for that screen.
class MiloScreen extends ConsumerStatefulWidget {
  const MiloScreen({super.key, required this.title, required this.body, this.kind = '', this.bg, this.trailing, this.onBack, this.noHeader = false});
  final String title, kind;
  final Widget body;
  final Color? bg;
  final Widget? trailing;
  final VoidCallback? onBack;
  final bool noHeader;
  @override
  ConsumerState<MiloScreen> createState() => _MiloScreenState();
}
class _MiloScreenState extends ConsumerState<MiloScreen> {
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addPostFrameCallback((_) => ref.read(directorProvider).setScreenKind(widget.kind)); }
  @override
  void dispose() { WidgetsBinding.instance.addPostFrameCallback((_) { try { ref.read(directorProvider).setScreenKind(''); } catch (_) {} }); super.dispose(); }
  @override
  // noHeader now means "no back button" (top-level states); every screen keeps one
  // MiloHeader so status, Break and Help me are always reachable.
  Widget build(BuildContext context) => Scaffold(
      backgroundColor: widget.bg,
      body: SafeArea(child: MiloScaffold(title: widget.title, kind: widget.kind, onBack: widget.noHeader ? null : widget.onBack ?? () => Navigator.pop(context), actions: widget.trailing, body: widget.body)));
}

Future<void> confirmCall(BuildContext c, String label, String number) => callConfirm(c, label, number);

/// "Help me" sheet: one tap from every screen (wireframe 2.5).
void showHelpSheet(BuildContext context, WidgetRef ref) {
  final d = ref.read(directorProvider);
  showModalBottomSheet(context: context, builder: (_) => Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Text('Help me', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800)), const SizedBox(height: 16),
    BigButton('I need help', () { Navigator.pop(context); ref.read(dbProvider).progress('help'); d.speakAac('I need help'); d.ask('help me'); }, kind: BK.coral),
    const SizedBox(height: 10),
    BigButton('I need a break', () { Navigator.pop(context); openScreen('break'); }),
    const SizedBox(height: 10),
    BigButton('Call my trusted person', () async {
      Navigator.pop(context);
      final n = await ref.read(dbProvider).get('local.trusted_phone');
      if (!context.mounted) return;
      if (n == null || n.isEmpty) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('A grown-up can add a number in the grown-up area.'))); } else { confirmCall(context, 'my trusted person', n); }
    }, kind: BK.soft),
    const SizedBox(height: 10), const Text('Speaks aloud. Calls only after you confirm.', style: TextStyle(fontSize: 12, color: T.mute)),
  ])));
}
