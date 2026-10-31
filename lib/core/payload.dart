import '../contracts/brain_contract.dart';

/// A context chip. What the chips show is EXACTLY what is sent (doc 7.7); removing a chip removes it from the next request.
class ChipItem {
  final String kind, label, text;
  const ChipItem(this.kind, this.label, [this.text = '']);
  Map<String, String> toJson() => {'kind': kind, 'label': label, 'text': text.length > 3000 ? text.substring(0, 3000) : text};
}

const kLangNames = {'en': 'English', 'hi': 'Hindi', 'ml': 'Malayalam', 'ta': 'Tamil', 'te': 'Telugu', 'kn': 'Kannada', 'bn': 'Bengali', 'mr': 'Marathi'};

Map<String, dynamic> buildBrainBody({
  required String text, required String activity, required String presentation, required String lang,
  required Map<String, String> support, required List<ChipItem> chips, required List<Map<String, String>> memories,
  String? name, List<Map<String, String>> recent = const [], Map<String, dynamic> uiContext = const {},
}) =>
    {
      'presentation': presentation,
      'support': support,
      'lang': kLangNames[lang] ?? 'English',
      if (name != null && name.isNotEmpty) 'name': name, // only when the person allowed names
      'activity': activity,
      'chips': [for (final c in chips) c.toJson()],
      'memories': memories,
      'recent': recent.length > 6 ? recent.sublist(recent.length - 6) : recent,
      'text': text.length > 800 ? text.substring(0, 800) : text,
      if (uiContext.isNotEmpty) 'ui_context': uiContext, // flat panel snapshot (ids + scalars), never the tree
    };

String summarizeBody(Map<String, dynamic> b) {
  final p = <String>[];
  if (b['text'] is String && (b['text'] as String).isNotEmpty) p.add('your message (${(b['text'] as String).length} characters)');
  final chips = (b['chips'] as List?) ?? [];
  if (chips.isNotEmpty) p.add('context: ${chips.map((c) => c['label']).join(', ')}');
  if (b['content_text'] != null) p.add('text to explain (${(b['content_text'] as String).length} characters)');
  if (b['image_b64'] != null) p.add('one photo (resized, location data removed)');
  final mem = (b['memories'] as List?) ?? [];
  if (mem.isNotEmpty) p.add('${mem.length} approved memories');
  if (b['ui_context'] is Map && (b['ui_context'] as Map).isNotEmpty) p.add('activity panel state (${(b['ui_context'] as Map).length} items)');
  if (b['goal'] != null) p.add('your task goal');
  if (b['strip'] != null) p.add('the words you picked');
  if (b['concept'] != null) p.add('one picture word');
  p.add(b['name'] != null ? 'your first name' : 'no name');
  return p.join('; ');
}

List<String> memKeysFor(String activity) => kMemKeys[activity] ?? kMemKeys['chat']!;
