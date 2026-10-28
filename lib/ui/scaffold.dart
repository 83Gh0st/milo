import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../companion/director.dart';
import '../companion/milo_view.dart';
import '../companion/v2/frame.dart';
import '../core/providers.dart';
import 'screen.dart';
import 'theme.dart';
import 'widgets.dart';

// ---- window classes (never from device names) ----
enum WinClass { compact, medium, expanded }
WinClass winClassOf(double w) => w < 600 ? WinClass.compact : w < 840 ? WinClass.medium : WinClass.expanded;

/// Wide arrangement: landscape where height is phone-like (short side < 480)
/// or markedly wider than tall. Landscape is required: a literal "short side
/// < 480" would match every portrait phone.
bool isWideLayout(Size s) => s.width > s.height && (s.shortestSide < 480 || s.width > s.height * 1.2);

String ladderWords(Ladder l) => switch (l) {
      Ladder.full => 'Back online.',
      Ladder.cloudOff => 'Cloud AI is off. I’ll help with what’s on this phone.',
      Ladder.offline => 'Offline. Your essentials are ready.',
      Ladder.resting => 'My thinking cloud is resting. I can still help with what is on your phone.',
    };

// ---- presence widgets: size from available space ----
/// Stage Milo: 38–45% of content height (min 220, max 440 dp on phones).
class MiloStage extends StatelessWidget {
  const MiloStage({super.key});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (c, bc) {
        final h = bc.hasBoundedHeight ? (bc.maxHeight * .42).clamp(220.0, 440.0).toDouble() : (MediaQuery.sizeOf(c).height * .35).clamp(220.0, 440.0).toDouble();
        return SizedBox(height: h, child: const MiloView(lod: MiloLod.full));
      });
}

/// Buddy Milo: bust LOD (head, shoulders, hands, sprout). Width keeps the
/// scale ≥ .755 so the visible body (159 design units) stays ≥ 120 dp.
class MiloBuddy extends StatelessWidget {
  const MiloBuddy({super.key});
  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (_, bc) {
        final h = bc.hasBoundedHeight ? bc.maxHeight.clamp(200.0, 300.0).toDouble() : 270.0;
        final w = (h * .62).clamp(151.0, 220.0).toDouble();
        return SizedBox(width: w, height: h, child: const MiloView(buddy: true, lod: MiloLod.bust));
      });
}

/// Header avatar 44–56 dp: face-only LOD, features 1.25×.
class MiloAvatar extends StatelessWidget {
  const MiloAvatar({super.key, this.size = 48});
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox(width: size, height: size, child: const MiloView(buddy: true, lod: MiloLod.avatar));
}

/// One header per screen: back | title | status | Break | Help me. Directional-safe.
class MiloHeader extends ConsumerWidget {
  const MiloHeader(this.title, {super.key, this.onBack, this.actions});
  final String title;
  final VoidCallback? onBack;
  final Widget? actions;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    // Narrow phones cannot fit back + title + chip + Break + a full "Help me"
    // button (45 px overflow at 340 px). Below 400 px, or at text scale >= 1.6
    // at any width, Help me compacts to an icon button (same 48 dp target,
    // same semantic label); at text scale >= 1.6, or below 400 px with header
    // actions present, the status chip also compacts to its icon (48 dp,
    // labelled by tooltip, tap still explains).
    return Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 12, 4),
        child: SizedBox(
            height: 56,
            child: LayoutBuilder(builder: (_, bc) {
              final bigText = MediaQuery.textScalerOf(context).scale(1) >= 1.6;
              final narrow = bc.maxWidth < 400 || bigText;
              return Row(children: [
                SizedBox(width: 48, child: onBack == null ? null : IconButton(tooltip: 'Back', onPressed: onBack, icon: const Icon(Icons.chevron_left, size: 30))),
                Expanded(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: onBack == null ? TextAlign.start : TextAlign.center, style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w800))),
                StatusChip(compact: bigText || (narrow && actions != null)),
                if (actions != null) actions!,
                IconButton(tooltip: 'Break', onPressed: () => openScreen('break'), icon: const Icon(Icons.bedtime_outlined)),
                if (d.presence == Presence.chip) const MiloAvatar(size: 44),
                if (narrow)
                  IconButton(tooltip: 'Help me', style: IconButton.styleFrom(backgroundColor: T.coralSoft, foregroundColor: T.coral), onPressed: () => showHelpSheet(context, ref), icon: const Icon(Icons.help_outline))
                else
                  FilledButton.tonal(style: FilledButton.styleFrom(minimumSize: const Size(0, 48), backgroundColor: T.coralSoft, foregroundColor: T.coral), onPressed: () => showHelpSheet(context, ref), child: const Text('Help me')),
              ]);
            })));
  }
}

/// Offline/resting/sync state as one chip (icon + 1–2 words). Tap explains.
/// Compact (large text): icon only, same sheet on tap.
class StatusChip extends ConsumerWidget {
  const StatusChip({super.key, this.compact = false});
  final bool compact;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ladder = ref.watch(ladderProvider), sync = ref.watch(syncBannerProvider) != null;
    final (icon, label) = switch (ladder) {
      Ladder.full => sync ? (Icons.sync_problem, 'Sync') : (Icons.cloud_done, 'Online'),
      Ladder.cloudOff => (Icons.cloud_off, 'Local'),
      Ladder.offline => (Icons.cloud_off, 'Offline'),
      Ladder.resting => (Icons.bedtime, 'Resting'),
    };
    if (compact) return Padding(padding: const EdgeInsetsDirectional.only(end: 4), child: SizedBox(width: 48, height: 48, child: Tooltip(message: label, child: ActionChip(avatar: Icon(icon, size: 16), label: const Text(''), onPressed: () => showStatusSheet(context, ref)))));
    return Padding(padding: const EdgeInsetsDirectional.only(end: 4), child: ActionChip(avatar: Icon(icon, size: 16), label: Text(label), onPressed: () => showStatusSheet(context, ref)));
  }
}

void showStatusSheet(BuildContext context, WidgetRef ref) {
  final ladder = ref.read(ladderProvider), sync = ref.read(syncBannerProvider);
  final title = switch (ladder) { Ladder.full => 'Online', Ladder.cloudOff => 'Cloud AI is off', Ladder.offline => 'You are offline', Ladder.resting => 'Thinking cloud is resting' };
  final works = ladder == Ladder.full ? ['Everything, including cloud thinking'] : ['Communication board', 'Read aloud', 'Routines and steps', 'Memories on this phone'];
  showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (c) => Padding(
          padding: EdgeInsets.only(left: 20, right: 20, top: 20, bottom: 20 + MediaQuery.viewInsetsOf(c).bottom),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(height: 8),
            Text(ladderWords(ladder), style: const TextStyle(fontSize: 16)),
            const SizedBox(height: 12),
            const Text('What works now', style: TextStyle(fontWeight: FontWeight.w700)),
            for (final w in works) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Row(children: [const Icon(Icons.check_circle, color: T.mint, size: 18), const SizedBox(width: 8), Expanded(child: Text(w))])),
            if (sync != null) ...[
              const SizedBox(height: 8),
              Text(sync),
              TextButton(
                  onPressed: () async {
                    try {
                      await ref.read(syncProvider).syncNow();
                      ref.read(syncBannerProvider.notifier).state = null;
                    } catch (e) {
                      ref.read(syncBannerProvider.notifier).state = syncBannerFor(e);
                    }
                    if (c.mounted) Navigator.pop(c);
                  },
                  child: const Text('Retry sync')),
            ],
          ])));
}

/// Bottom companion dock (compact portrait): avatar + bubble + choices +
/// memory proposals. Collapses to a 64 dp peek, remembered per screen kind.
class CompanionDock extends ConsumerWidget {
  const CompanionDock({super.key, required this.kind});
  final String kind;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    final mq = MediaQuery.of(context);
    final peek = d.peeked.contains(kind) || mq.viewInsets.bottom > 0 || (d.textScale >= 1.6 && mq.size.height < 700);
    if (peek) return _PeekBar(kind: kind);
    // The dock yields to content: capped at 300 dp so fixed-chrome bodies
    // (Express at large text needs ~250) always keep room; anything taller
    // (crowded bubble + choices + MemoryConfirm) scrolls inside the dock.
    return Column(mainAxisSize: MainAxisSize.min, children: [const SupportBar(), ConstrainedBox(constraints: const BoxConstraints(maxHeight: 300), child: SingleChildScrollView(child: _DockBody(kind: kind, horizontal: true)))]);
  }
}

/// Side companion column (medium, expanded, wide): same content, vertical.
class CompanionRail extends ConsumerWidget {
  const CompanionRail({super.key, required this.kind});
  final String kind;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    if (d.peeked.contains(kind)) return _PeekBar(kind: kind);
    return Column(children: [const SupportBar(), Expanded(child: SingleChildScrollView(child: _DockBody(kind: kind, horizontal: false)))]);
  }
}

class _PeekBar extends ConsumerWidget {
  const _PeekBar({required this.kind});
  final String kind;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    return SizedBox(
        height: 64,
        child: Row(children: [
          const MiloAvatar(),
          Expanded(child: Text(d.caption, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(color: T.mute))),
          IconButton(tooltip: 'Show Milo', onPressed: () => ref.read(directorProvider).set(() => d.peeked.remove(kind)), icon: const Icon(Icons.expand_less)),
        ]));
  }
}

class _DockBody extends ConsumerWidget {
  const _DockBody({required this.kind, required this.horizontal});
  final String kind;
  final bool horizontal;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    final left = d.leftHanded;
    final texts = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (d.captions && d.caption.isNotEmpty && d.state != CState.idle)
        ConstrainedBox(constraints: const BoxConstraints(maxHeight: 110), child: SingleChildScrollView(child: Speech(d.caption))),
      if (d.choices.isNotEmpty)
        Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Wrap(spacing: 8, runSpacing: 8, children: [for (final c in d.choices) ActionChip(backgroundColor: T.priSoft, side: BorderSide.none, materialTapTargetSize: MaterialTapTargetSize.padded, label: Text(c, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: T.pri)), onPressed: () => d.choose(c))])),
      const MemoryConfirm(),
    ]);
    final collapse = SizedBox(width: 48, child: Align(alignment: Alignment.topCenter, child: IconButton(tooltip: 'Minimise Milo', onPressed: () => d.set(() => d.peeked.add(kind)), icon: const Icon(Icons.expand_more))));
    if (!horizontal) return Column(mainAxisSize: MainAxisSize.min, children: [const MiloBuddy(), texts, collapse]);
    return Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
      if (left) Expanded(child: texts),
      const MiloBuddy(),
      if (!left) Expanded(child: texts),
      collapse,
    ]);
  }
}

/// App scaffold (callers own Scaffold/SafeArea/nav): header + content + dock,
/// or content + side rail on medium/expanded/wide. No overlay positioning.
class MiloScaffold extends ConsumerWidget {
  const MiloScaffold({super.key, required this.title, required this.body, this.kind = '', this.onBack, this.actions});
  final String title;
  final Widget body;
  final String kind;
  final VoidCallback? onBack;
  final Widget? actions;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final d = ref.watch(directorProvider);
    final mq = MediaQuery.sizeOf(context);
    final rail = winClassOf(mq.width) != WinClass.compact || isWideLayout(mq);
    final side = d.presence == Presence.buddy;
    final left = d.leftHanded;
    final header = MiloHeader(title, onBack: onBack, actions: actions);
    if (!rail) return Column(children: [header, Expanded(child: body), if (side) CompanionDock(kind: kind)]);
    final railW = (mq.width * .32).clamp(280.0, 360.0).toDouble();
    return Row(children: [
      if (left && side) SizedBox(width: railW, child: CompanionRail(kind: kind)),
      Expanded(child: Column(children: [header, Expanded(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: body)))])),
      if (!left && side) SizedBox(width: railW, child: CompanionRail(kind: kind)),
    ]);
  }
}
