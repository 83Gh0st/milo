import 'package:flutter/material.dart';

/// The primary Milo lockup: mascot mark + lowercase `milo` wordmark.
///
/// Used on brand surfaces (About). The animated companion ([MiloView]) stays
/// the hero everywhere else; this is the static product mark, matching the
/// launcher icon and splash art in `assets/branding/`.
class MiloBrand extends StatelessWidget {
  const MiloBrand({super.key, this.size = 96, this.wordmark = true});
  final double size;
  final bool wordmark;
  static const ink = Color(0xFF0A3F38); // deep teal ink, matches the splash wordmark
  @override
  Widget build(BuildContext context) => Semantics(
      label: 'Milo logo',
      image: true,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        ClipRRect(
            borderRadius: BorderRadius.circular(size * .24),
            child: Image.asset('assets/branding/mascot.png', width: size, height: size, fit: BoxFit.cover)),
        if (wordmark) ...[
          SizedBox(height: size * .08),
          Text('milo',
              style: TextStyle(fontFamily: 'Lexend', fontWeight: FontWeight.w600, fontSize: size * .34, letterSpacing: size * .02, color: ink, height: 1)),
        ],
      ]));
}
