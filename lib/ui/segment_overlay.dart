import 'dart:typed_data';
import 'package:flutter/material.dart';

/// One validated segmentation region in NORMALIZED image coordinates (0..1
/// on each axis). Produced from SAM 3.1 probe/route output; never trusted raw.
class SegRegion {
  const SegRegion({required this.id, required this.label, required this.box, this.objectId});
  final String id;
  final String label;
  final Rect box; // normalized left/top/width/height
  final String? objectId;
}

/// Validates raw region maps (probe JSON or a future /v1/segment response):
/// clamps to 0..1, drops degenerate/empty boxes, caps count. Pure: unit-tested.
List<SegRegion> validateRegions(Object? raw, {int max = 20}) {
  if (raw is! List) return const [];
  final out = <SegRegion>[];
  for (final e in raw) {
    if (e is! Map || out.length >= max) continue;
    final id = e['id']?.toString() ?? '', label = (e['label'] ?? e['concept'] ?? '').toString().trim();
    final b = e['box'];
    if (id.isEmpty || label.isEmpty || b is! List || b.length != 4) continue;
    final nums = [for (final v in b) v is num ? v.toDouble() : double.nan];
    if (nums.any((v) => v.isNaN)) continue;
    final l = nums[0].clamp(0.0, 1.0), t = nums[1].clamp(0.0, 1.0);
    final r = nums[2].clamp(0.0, 1.0), bo = nums[3].clamp(0.0, 1.0);
    if (r - l < .02 || bo - t < .02) continue; // degenerate: under 2% of the image
    out.add(SegRegion(id: id.length > 40 ? id.substring(0, 40) : id,
        label: label.length > 60 ? label.substring(0, 60) : label,
        box: Rect.fromLTRB(l, t, r, bo), objectId: e['object_id']?.toString()));
  }
  return out;
}

/// Photo with tappable segmentation boxes overlaid. Coordinates are linear
/// because the image fills an [AspectRatio] box matching the photo - no
/// letterboxing, no painter math to drift. Tapping a box selects it (thick
/// border + label chip) and reports the region id for explain-this flows.
class SegmentOverlay extends StatelessWidget {
  const SegmentOverlay({super.key, required this.imageBytes, required this.imageAspect, required this.regions, this.selectedId, this.onRegionTap, this.semanticLabel});
  final Uint8List imageBytes;
  final double imageAspect;
  final List<SegRegion> regions;
  final String? selectedId;
  final void Function(String regionId)? onRegionTap;
  final String? semanticLabel;
  @override
  Widget build(BuildContext context) => Semantics(
      container: true,
      label: semanticLabel ?? 'Photo with ${regions.length} outlined objects',
      image: true,
      child: AspectRatio(
          aspectRatio: imageAspect,
          child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(fit: StackFit.expand, children: [
                Image.memory(imageBytes, fit: BoxFit.fill, excludeFromSemantics: true,
                    errorBuilder: (_, __, ___) => Container(color: const Color(0xFFFEF4E5), child: const Center(child: Icon(Icons.broken_image_outlined, color: Color(0xFF8A8FA3), size: 40)))),
                for (final r in regions)
                  Positioned(
                      left: 0, top: 0, right: 0, bottom: 0,
                      child: Align(
                          alignment: Alignment(r.box.left * 2 + r.box.width - 1, r.box.top * 2 + r.box.height - 1),
                          child: FractionallySizedBox(
                              widthFactor: r.box.width,
                              heightFactor: r.box.height,
                              child: GestureDetector(
                                  onTap: onRegionTap == null ? null : () => onRegionTap!(r.id),
                                  behavior: HitTestBehavior.opaque,
                                  child: Semantics(
                                      container: true, // explicit node: without this the label merges upward and is neither findable nor focusable
                                      button: true,
                                      label: 'Explain ${r.label}',
                                      child: Container(
                                          decoration: BoxDecoration(
                                              border: Border.all(color: r.id == selectedId ? const Color(0xFF149E87) : Colors.white, width: r.id == selectedId ? 3 : 2),
                                              borderRadius: BorderRadius.circular(6)),
                                          child: Align(
                                              alignment: Alignment.topLeft,
                                              child: Container(
                                                  margin: const EdgeInsets.all(3),
                                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                                  decoration: BoxDecoration(color: Colors.black.withAlpha(160), borderRadius: BorderRadius.circular(6)),
                                                  child: Text(r.label, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis))))))))),
              ]))));
}
