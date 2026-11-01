import '../contracts/brain_contract.dart';

/// Client-side validation for generative UI specs (contracts/ui_contract.json
/// v1). The gateway already validated the spec; this re-checks shape, closed
/// vocabularies and caps before anything renders, so a confused model or a
/// tampered wire degrades to plain chat instead of breaking the panel.
/// Returns the sanitized spec, or null when there is nothing usable.
const uiVersion = 1;
const uiComponents = {'text', 'card', 'button', 'choices', 'checklist', 'progress', 'steps', 'list', 'image', 'genimage', 'divider'};
const uiSpecActions = {'check', 'answer', 'next', 'ask', 'speak', 'open_screen'};
const uiOps = {'add', 'update', 'replace', 'move', 'remove', 'state'};
const uiLayouts = {'column', 'row', 'card'};
const uiIntents = {'guide', 'explain', 'quiz', 'celebrate', 'choice', 'none'};
const uiModes = {'chat', 'activity', 'celebration'};
const uiCompanions = {'featured', 'docked', 'hidden'};
const uiMaxComponents = 40, uiMaxDepth = 4, uiMaxText = 600, uiMaxTitle = 120, uiMaxItems = 12;
const uiMaxActionsPerNode = 4, uiMaxOps = 12, uiMaxStateKeys = 12, uiMaxStateValue = 120, uiMaxId = 32;
const uiMaxContext = 12; // ui_context keys per brain request (flat, scalar-only)

final _idRe = RegExp(r'^[A-Za-z0-9_-]{1,32}$');
final _unsafe = RegExp(r'(https?://\S+|www\.\S+|\+?\d[\d\s\-]{6,}\d)');

bool okId(Object? v) => v is String && v.length <= uiMaxId && _idRe.hasMatch(v);
String uiText(Object? v, int cap) {
  if (v is! String) return '';
  final t = v.replaceAll(_unsafe, '').trim();
  return t.length > cap ? t.substring(0, cap) : t;
}

Map<String, dynamic>? _action(Object? a) {
  if (a is! Map) return null;
  final name = a['action'];
  if (!uiSpecActions.contains(name)) return null;
  if (name == 'check') return okId(a['target']) ? {'action': name, 'target': a['target']} : null;
  if (name == 'answer') {
    if (!okId(a['target'])) return null;
    final out = {'action': name, 'target': a['target']};
    if (a['option'] != null) {
      if (!okId(a['option'])) return null;
      out['option'] = a['option'];
    }
    return out;
  }
  if (name == 'next') return {'action': name};
  if (name == 'ask') {
    final p = uiText(a['prompt'], uiMaxText);
    return p.isEmpty ? null : {'action': name, 'prompt': p};
  }
  if (name == 'speak') {
    final out = {'action': name};
    if (a['target'] != null) {
      if (!okId(a['target'])) return null;
      out['target'] = a['target'];
    }
    return out;
  }
  return kScreens.contains(a['screen']) ? {'action': name, 'screen': a['screen']} : null; // open_screen
}

List<Map<String, dynamic>>? _items(Object? raw, {required bool done, required bool detail}) {
  if (raw is! List) return null;
  final out = <Map<String, dynamic>>[];
  for (final it in raw.take(uiMaxItems)) {
    if (it is! Map || !okId(it['id'])) continue;
    final text = uiText(it['text'], uiMaxText);
    if (text.isEmpty) continue;
    final row = {'id': it['id'], 'text': text};
    if (done && it['done'] is bool) row['done'] = it['done'];
    if (detail) {
      final d = uiText(it['detail'], uiMaxText);
      if (d.isNotEmpty) row['detail'] = d;
    }
    out.add(row);
  }
  return out.isEmpty ? null : out;
}

List<Map<String, dynamic>>? _actions(Object? raw) {
  if (raw == null) return const [];
  if (raw is! List) return null;
  final out = <Map<String, dynamic>>[];
  for (final a in raw.take(uiMaxActionsPerNode)) {
    final s = _action(a);
    if (s != null) out.add(s);
  }
  return out;
}

Map<String, dynamic>? validateNode(Object? n, Set<String> seen, int depth) {
  if (n is! Map || depth > uiMaxDepth) return null;
  final t = n['type'];
  if (!uiComponents.contains(t) || !okId(n['id']) || seen.contains(n['id'])) return null;
  final out = <String, dynamic>{'id': n['id'], 'type': t};
  if (t == 'text') {
    out['text'] = uiText(n['text'], uiMaxText);
    if ((out['text'] as String).isEmpty) return null;
  } else if (t == 'card') {
    final title = uiText(n['title'], uiMaxTitle);
    if (title.isNotEmpty) out['title'] = title;
    if (!uiLayouts.contains(n['layout'] ?? 'column')) return null;
    out['layout'] = n['layout'] ?? 'column';
    final kids = <Map<String, dynamic>>[];
    if (n['children'] is List) {
      for (final k in n['children'] as List) {
        final s = validateNode(k, seen, depth + 1);
        if (s != null) kids.add(s);
      }
    }
    if (kids.isEmpty) return null;
    out['children'] = kids;
  } else if (t == 'button') {
    out['label'] = uiText(n['label'], uiMaxTitle);
    final act = _action(n['action']);
    if ((out['label'] as String).isEmpty || act == null) return null;
    out['action'] = act;
  } else if (t == 'choices') {
    final opts = _items(n['options'], done: false, detail: false);
    if (opts == null) return null;
    out['options'] = [for (final o in opts) {'id': o['id'], 'label': o['text']}];
    if (n['answer'] != null) {
      if (!okId(n['answer']) || !(out['options'] as List).any((o) => o['id'] == n['answer'])) return null;
      out['answer'] = n['answer'];
    }
  } else if (t == 'checklist') {
    final items = _items(n['items'], done: true, detail: false);
    if (items == null) return null;
    out['items'] = items;
  } else if (t == 'progress') {
    final v = n['value'];
    if (v is bool || v is! num) return null;
    out['value'] = (v.toDouble()).clamp(0.0, 1.0);
    final label = uiText(n['label'], uiMaxTitle);
    if (label.isNotEmpty) out['label'] = label;
  } else if (t == 'steps') {
    final steps = _items(n['steps'], done: false, detail: true);
    if (steps == null) return null;
    out['steps'] = steps;
    if (n['current'] != null) {
      if (!okId(n['current']) || !steps.any((s) => s['id'] == n['current'])) return null;
      out['current'] = n['current'];
    }
  } else if (t == 'list') {
    final items = _items(n['items'], done: false, detail: false);
    if (items == null) return null;
    out['items'] = items;
  } else if (t == 'image') {
    final c = n['concept'];
    if (c is! String || !kVisualConcepts.contains(c.trim().toLowerCase())) return null;
    out['concept'] = c.trim().toLowerCase();
  } else if (t == 'genimage') {
    final p = uiText(n['prompt'], 140), a = uiText(n['alt'], 200);
    if (p.length < 2) return null;
    out['prompt'] = p;
    out['alt'] = a.length < 2 ? 'AI-made picture: $p' : a; // alt text always present for screen readers
  }
  final acts = _actions(n['actions']);
  if (acts == null) return null;
  if (acts.isNotEmpty) out['actions'] = acts;
  seen.add(n['id'] as String);
  return out;
}

int _count(Map<String, dynamic> n) => 1 + (n['children'] is List ? (n['children'] as List).fold<int>(0, (a, c) => a + _count(c as Map<String, dynamic>)) : 0);

Map<String, dynamic>? _statePatch(Object? raw) {
  if (raw is! Map || raw.length > uiMaxStateKeys) return null;
  final out = <String, dynamic>{};
  for (final e in raw.entries) {
    if (!okId(e.key)) return null;
    final v = e.value;
    if (v is String) {
      out[e.key as String] = uiText(v, uiMaxStateValue);
    } else if (v is num || v is bool) {
      out[e.key as String] = v;
    } else {
      return null;
    }
  }
  return out;
}

Map<String, dynamic>? _op(Object? o, Set<String> seen) {
  if (o is! Map || !uiOps.contains(o['op'])) return null;
  final name = o['op'] as String;
  if (name == 'add') {
    if (!okId(o['parent'])) return null;
    final node = validateNode(o['node'], Set.of(seen), 1);
    if (node == null) return null;
    final out = <String, dynamic>{'op': name, 'parent': o['parent'], 'node': node};
    if (o['index'] != null) {
      if (o['index'] is bool || o['index'] is! int || (o['index'] as int) < 0) return null;
      out['index'] = o['index'];
    }
    return out;
  }
  if (name == 'state') {
    final patch = _statePatch(o['patch']);
    return patch == null ? null : {'op': name, 'patch': patch};
  }
  if (!okId(o['target'])) return null;
  if (name == 'update') {
    final props = o['props'];
    if (props is! Map || props.isEmpty) return null;
    final safe = <String, dynamic>{};
    for (final e in props.entries) {
      if (!okId(e.key)) return null;
      final v = e.value;
      if (v is String) {
        safe[e.key as String] = uiText(v, uiMaxText);
      } else if (v is num || v is bool) {
        safe[e.key as String] = v;
      } else {
        return null; // structured values need replace, not update
      }
    }
    return {'op': name, 'target': o['target'], 'props': safe};
  }
  if (name == 'replace') {
    final node = validateNode(o['with'], Set.of(seen), 1);
    return node == null ? null : {'op': name, 'target': o['target'], 'with': node};
  }
  if (name == 'move') {
    if (!okId(o['parent'])) return null;
    final out = <String, dynamic>{'op': name, 'target': o['target'], 'parent': o['parent']};
    if (o['index'] != null) {
      if (o['index'] is bool || o['index'] is! int || (o['index'] as int) < 0) return null;
      out['index'] = o['index'];
    }
    return out;
  }
  return {'op': name, 'target': o['target']}; // remove
}

Map<String, dynamic>? validateUiSpec(Object? obj) {
  if (obj is! Map || obj.isEmpty || obj['v'] != uiVersion) return null;
  final activity = obj['activity'] ?? '';
  if (activity is! String || (activity.isNotEmpty && !okId(activity))) return null;
  final out = <String, dynamic>{'v': uiVersion, 'activity': activity};
  for (final entry in {'intent': uiIntents, 'mode': uiModes, 'companion': uiCompanions}.entries) {
    if (obj.containsKey(entry.key)) {
      // delta specs omit these: the panel keeps its current values
      if (!entry.value.contains(obj[entry.key])) return null;
      out[entry.key] = obj[entry.key];
    }
  }
  if (obj['speak'] != null) {
    if (!okId(obj['speak'])) return null;
    out['speak'] = obj['speak'];
  }
  if (obj['state'] != null) {
    final patch = _statePatch(obj['state']);
    if (patch == null) return null;
    out['state'] = patch;
  }
  final seen = <String>{};
  if (obj['root'] != null) {
    final root = validateNode(obj['root'], seen, 1);
    if (root == null || _count(root) > uiMaxComponents) return null;
    out['root'] = root;
  }
  if (obj['ops'] != null) {
    final raw = obj['ops'];
    if (raw is! List || raw.length > uiMaxOps) return null;
    final ops = <Map<String, dynamic>>[];
    for (final o in raw) {
      final s = _op(o, seen);
      if (s == null) return null;
      ops.add(s);
    }
    if (ops.isNotEmpty) out['ops'] = ops;
  }
  if (!out.containsKey('root') && !out.containsKey('ops') && !out.containsKey('state')) return null;
  return out;
}
