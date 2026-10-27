import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../companion/director.dart';
import '../companion/milo_view.dart';
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

/// Buddy Milo, caption bubble, choices, consent card and the support bar: shared by tabs and pushed screens.
class Overlays extends ConsumerWidget {
  const Overlays({super.key, required this.child, this.bottomPad = 8});
  final Widget child;
  final double bottomPad;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    final buddy = d.presence == Presence.buddy, left = d.leftHanded;
    return Stack(children: [
      child,
      if (buddy) Positioned(left: left ? 6 : null, right: left ? null : 6, bottom: bottomPad, width: 110, height: 128, child: const IgnorePointer(ignoring: false, child: MiloView())),
      if (buddy && d.captions && d.caption.isNotEmpty && d.state != CState.idle) Positioned(left: left ? 118 : null, right: left ? null : 118, bottom: bottomPad + 56, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 210), child: Speech(d.caption))),
      if (d.choices.isNotEmpty) Positioned(left: buddy && left ? 124 : 12, right: buddy && !left ? 124 : 12, bottom: bottomPad, child: Wrap(spacing: 8, runSpacing: 8, children: [for (final c in d.choices) ActionChip(backgroundColor: T.priSoft, side: BorderSide.none, label: Text(c, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: T.pri)), onPressed: () => d.ask(c))])),
      Positioned(left: 12, right: 12, bottom: bottomPad + 70, child: const MemoryConfirm()),
      const Positioned(left: 0, right: 0, top: 0, child: SupportBar()),
    ]);
  }
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
  Widget build(BuildContext context) => Scaffold(backgroundColor: widget.bg, body: SafeArea(child: Overlays(child: Column(children: [
        if (!widget.noHeader) ScreenHeader(widget.title, onBack: widget.onBack ?? () => Navigator.pop(context), trailing: widget.trailing),
        Expanded(child: widget.body)]))));
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
