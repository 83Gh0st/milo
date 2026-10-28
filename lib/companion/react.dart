import 'package:flutter/widgets.dart';

/// UI-to-Milo reaction hub (spec 2D). Shared widgets are plain
/// StatelessWidgets with no provider access, so they notify through this
/// static hub and the Director subscribes. No imports of the Director here,
/// so theme.dart can use it without an import cycle.
enum ReactKind { pressDown, focus, typed, sent, scroll, stepDone, navigating }

class ReactEvent {
  final ReactKind kind;
  final Offset? at; // global position for gaze (press/focus/typing)
  final double data; // scroll velocity, navigation direction, or 0
  const ReactEvent(this.kind, {this.at, this.data = 0});
}

class MiloReact {
  MiloReact._();
  static void Function(ReactEvent)? handler;

  static void notify(ReactEvent e) {
    try { handler?.call(e); } catch (_) {}
  }

  static Offset? _center(BuildContext c) {
    final rb = c.findRenderObject();
    if (rb is RenderBox && rb.hasSize) return rb.localToGlobal(rb.size.center(Offset.zero));
    return null;
  }

  /// Pointer went down on a shared control: Milo glances at it.
  static void pressed(BuildContext c) => notify(ReactEvent(ReactKind.pressDown, at: _center(c)));

  /// A text field gained focus: Milo looks at it.
  static void focused(BuildContext c) => notify(ReactEvent(ReactKind.focus, at: _center(c)));

  /// Text changed in a field: Milo follows along (rate-limited in the Director).
  static void typed(BuildContext c) => notify(ReactEvent(ReactKind.typed, at: _center(c)));

  /// A message was sent: Milo nods.
  static void sent() => notify(const ReactEvent(ReactKind.sent));

  /// A scroll view moved with [velocity] (logical px/s, + = down).
  static void scrolled(double velocity) => notify(ReactEvent(ReactKind.scroll, data: velocity));

  /// A step finished or an answer was right: quiet pride, not a party.
  static void stepDone() => notify(const ReactEvent(ReactKind.stepDone));

  /// Navigation started toward a tab in [direction] (-1 left, +1 right).
  static void navigating(double direction) => notify(ReactEvent(ReactKind.navigating, data: direction));

  /// Wraps any subtree so pointer-downs and focus notify Milo. Used by
  /// screens for their text fields without per-field edits.
  static Widget watch({required Widget child}) => _ReactWatch(child: child);
}

class _ReactWatch extends StatelessWidget {
  final Widget child;
  const _ReactWatch({required this.child});
  @override
  Widget build(BuildContext context) => Listener(
        onPointerDown: (_) => MiloReact.pressed(context),
        child: FocusScope(
          onFocusChange: (has) { if (has) MiloReact.focused(context); },
          child: child,
        ),
      );
}
