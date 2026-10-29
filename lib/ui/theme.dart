import 'package:flutter/material.dart';
import '../companion/director.dart';
import '../companion/react.dart';

/// Design tokens taken from the wireframes (periwinkle primary, pastel tiles, ink text).
class T {
  static const bg = Color(0xFFF4F5FF), line = Color(0xFFE5E8FF), pri = Color(0xFF5B6CFF), priSoft = Color(0xFFE2E6FF), mint = Color(0xFF34C38F), mintSoft = Color(0xFFD9F5EA);
  static const coral = Color(0xFFFF7A7A), coralSoft = Color(0xFFFFE0E0), amber = Color(0xFFFFC857), amberSoft = Color(0xFFFFF0CC), ink = Color(0xFF1F2340), mute = Color(0xFF7A7F9E);
  static const soft = [priSoft, coralSoft, amberSoft, mintSoft];
  static const strong = [pri, coral, Color(0xFFF2A900), mint];
}

ThemeData miloTheme(Director d) {
  final hc = d.highContrast;
  return ThemeData(
    useMaterial3: true, fontFamily: d.font, scaffoldBackgroundColor: T.bg, brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(seedColor: T.pri, brightness: Brightness.light, surface: Colors.white).copyWith(primary: T.pri, onSurface: hc ? Colors.black : T.ink),
    textTheme: ThemeData.light().textTheme.apply(bodyColor: hc ? Colors.black : T.ink, displayColor: hc ? Colors.black : T.ink, fontFamily: d.font),
    filledButtonTheme: FilledButtonThemeData(style: FilledButton.styleFrom(minimumSize: const Size(64, 56), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)), textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600))),
    outlinedButtonTheme: OutlinedButtonThemeData(style: OutlinedButton.styleFrom(minimumSize: const Size(64, 56), side: const BorderSide(color: T.line), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)))),
    cardTheme: CardThemeData(color: Colors.white, elevation: 0, margin: const EdgeInsets.symmetric(vertical: 5), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18), side: const BorderSide(color: T.line))),
    navigationBarTheme: NavigationBarThemeData(backgroundColor: Colors.white, indicatorColor: T.priSoft, labelTextStyle: WidgetStateProperty.all(const TextStyle(fontSize: 12, fontWeight: FontWeight.w600))),
    inputDecorationTheme: InputDecorationTheme(filled: true, fillColor: T.priSoft, border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none), contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14)),
  );
}

/// LOCAL / CLOUD tags from the wireframes, shown to the person as "Works offline" / "Needs internet".
class Tag extends StatelessWidget {
  const Tag(this.text, {super.key, this.cloud = false});
  final String text;
  final bool cloud;
  @override
  Widget build(BuildContext context) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: cloud ? T.amberSoft : T.mintSoft, borderRadius: BorderRadius.circular(10)),
      child: Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: cloud ? const Color(0xFF9A6B00) : const Color(0xFF1B8A63))));
}

class RowCard extends StatelessWidget {
  const RowCard({super.key, required this.icon, required this.title, this.subtitle, this.color = 0, this.onTap, this.tag, this.dim = false, this.trailing});
  final IconData icon;
  final String title;
  final String? subtitle;
  final int color;
  final VoidCallback? onTap;
  final Widget? tag, trailing;
  final bool dim;
  @override
  Widget build(BuildContext context) => Opacity(opacity: dim ? .5 : 1, child: Card(child: InkWell(borderRadius: BorderRadius.circular(18), onTap: onTap == null ? null : () { MiloReact.pressed(context); onTap!(); }, child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
        Container(width: 44, height: 44, decoration: BoxDecoration(color: T.soft[color % 4], borderRadius: BorderRadius.circular(14)), child: Icon(icon, color: T.strong[color % 4])),
        const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)), if (subtitle != null) Text(subtitle!, style: const TextStyle(fontSize: 13, color: T.mute)),
          if (tag != null) Padding(padding: const EdgeInsets.only(top: 4), child: tag)])),
        trailing ?? const Icon(Icons.chevron_right, color: T.mute),
      ])))));
}

/// Pastel square tile (communication board, onboarding choices).
class PastelTile extends StatelessWidget {
  const PastelTile({super.key, required this.icon, required this.label, this.color = 0, this.onTap, this.selected = false, this.speaker = false, this.emoji});
  final IconData? icon;
  final String? emoji;
  final String label;
  final int color;
  final bool selected, speaker;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Semantics(button: true, label: label, child: Material(color: T.soft[color % 4], borderRadius: BorderRadius.circular(20), child: InkWell(borderRadius: BorderRadius.circular(20), onTap: onTap == null ? null : () { MiloReact.pressed(context); onTap!(); }, child: Container(
      decoration: selected ? BoxDecoration(borderRadius: BorderRadius.circular(20), border: Border.all(color: T.pri, width: 2.5)) : null,
      child: Stack(children: [
        if (speaker) const Positioned(right: 10, top: 8, child: Icon(Icons.volume_up, size: 16, color: T.mute)),
        Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (emoji != null) Text(emoji!, style: const TextStyle(fontSize: 34)) else Icon(icon, size: 30, color: T.strong[color % 4]),
          const SizedBox(height: 6), Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
        ])),
      ])))));
}

class PillTabs extends StatelessWidget {
  const PillTabs(this.labels, this.index, this.onChanged, {super.key});
  final List<String> labels;
  final int index;
  final void Function(int) onChanged;
  @override
  Widget build(BuildContext context) => Row(children: [for (var i = 0; i < labels.length; i++) Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 3), child: InkWell(
      borderRadius: BorderRadius.circular(20), onTap: () { MiloReact.pressed(context); onChanged(i); }, child: Container(height: 44, alignment: Alignment.center,
      decoration: BoxDecoration(color: i == index ? T.pri : T.priSoft, borderRadius: BorderRadius.circular(20)),
      child: Text(labels[i], style: TextStyle(fontWeight: FontWeight.w700, color: i == index ? Colors.white : T.pri))))))]);
}

enum BK { primary, soft, outline, coral, mint }
class BigButton extends StatelessWidget {
  const BigButton(this.label, this.onPressed, {super.key, this.kind = BK.primary, this.icon});
  final String label;
  final VoidCallback? onPressed;
  final BK kind;
  final IconData? icon;
  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (kind) { BK.primary => (T.pri, Colors.white), BK.soft => (T.priSoft, T.pri), BK.coral => (T.coral, Colors.white), BK.mint => (T.mint, Colors.white), BK.outline => (Colors.white, T.ink) };
    // Long labels wrap to two lines instead of overflowing (38 px seen on
    // 'Remove this connection'); the button grows, never clips the label.
    return SizedBox(width: double.infinity, child: ConstrainedBox(constraints: const BoxConstraints(minHeight: 58), child: FilledButton(onPressed: onPressed == null ? null : () { MiloReact.pressed(context); onPressed!(); }, style: FilledButton.styleFrom(backgroundColor: bg, foregroundColor: fg, disabledBackgroundColor: T.priSoft, side: kind == BK.outline ? const BorderSide(color: T.line) : null),
        child: Row(mainAxisAlignment: MainAxisAlignment.center, mainAxisSize: MainAxisSize.min, children: [if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)], Flexible(child: Text(label, textAlign: TextAlign.center))]))));
  }
}

class Section extends StatelessWidget {
  const Section(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.fromLTRB(4, 14, 4, 6), child: Text(text.toUpperCase(), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800, color: T.mute, letterSpacing: .6)));
}

/// Speech bubble with the periwinkle outline used in the wireframes.
class Speech extends StatelessWidget {
  const Speech(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Container(padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10), decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(16), border: Border.all(color: T.pri)),
      child: Text(text, style: const TextStyle(fontSize: 16, height: 1.3)));
}
