import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'spec.dart';

/// The live activity panel: one validated tree per activity, plus the
/// server's state patch and the person's local interactions (checked items,
/// answers). The tree is replaced only by a new root; ops patch it in place
/// so answers survive across turns. Nothing here touches the network.
class PanelState {
  const PanelState({this.activity = '', this.intent = 'none', this.mode = 'chat', this.companion = 'docked', this.speak, this.root, this.serverState = const {}, this.values = const {}, this.lastAction});
  final String activity, intent, mode, companion;
  final String? speak, lastAction;
  final Map<String, dynamic>? root;
  final Map<String, dynamic> serverState, values;
  bool get active => root != null;

  /// Flat scalar-only snapshot for the next brain request (ui_context): the
  /// activity id, what the person did since the last turn, and merged state.
  /// Capped at [uiMaxContext] keys; never the tree.
  Map<String, dynamic> snapshot() {
    if (!active) return const {};
    final out = <String, dynamic>{'activity': activity};
    if (lastAction != null) out['last_action'] = lastAction;
    for (final e in [...serverState.entries, ...values.entries]) {
      if (out.length >= uiMaxContext) break;
      if (e.key == 'activity' || e.key == 'last_action') continue;
      final v = e.value;
      if (v is String || v is num || v is bool) out[e.key] = v;
    }
    return out;
  }

  PanelState copyWith({String? activity, String? intent, String? mode, String? companion, String? Function()? speak, Map<String, dynamic>? root, Map<String, dynamic>? serverState, Map<String, dynamic>? values, String? Function()? lastAction}) =>
      PanelState(activity: activity ?? this.activity, intent: intent ?? this.intent, mode: mode ?? this.mode, companion: companion ?? this.companion,
          speak: speak == null ? this.speak : speak(), root: root ?? this.root, serverState: serverState ?? this.serverState, values: values ?? this.values,
          lastAction: lastAction == null ? this.lastAction : lastAction());
}

Map<String, dynamic> _clone(Map<String, dynamic> m) => jsonDecode(jsonEncode(m)) as Map<String, dynamic>;

Map<String, dynamic>? _find(Map<String, dynamic> n, String id) {
  if (n['id'] == id) return n;
  if (n['children'] is List) {
    for (final c in n['children'] as List) {
      final hit = _find(c as Map<String, dynamic>, id);
      if (hit != null) return hit;
    }
  }
  return null;
}

/// Applies one validated op to the cloned tree; null when the op cannot apply
/// (unknown target, non-card parent). The batch then fails atomically: the
/// panel keeps its previous tree.
bool _applyOp(Map<String, dynamic> root, Map<String, dynamic> o) {
  final name = o['op'] as String;
  if (name == 'state') return true; // merged by the notifier, not the tree
  Map<String, dynamic>? parentOf(Map<String, dynamic> n, String id) {
    if (n['children'] is List) {
      for (final c in (n['children'] as List).cast<Map<String, dynamic>>()) {
        if (c['id'] == id) return n;
        final hit = parentOf(c, id);
        if (hit != null) return hit;
      }
    }
    return null;
  }

  List<Map<String, dynamic>>? kidsOf(String id) {
    final p = _find(root, id);
    if (p == null || p['type'] != 'card' || p['children'] is! List) return null;
    return (p['children'] as List).cast<Map<String, dynamic>>();
  }

  if (name == 'remove') {
    final p = parentOf(root, o['target'] as String);
    if (p == null) return false;
    (p['children'] as List).removeWhere((c) => (c as Map)['id'] == o['target']);
    return true;
  }
  if (name == 'update') {
    final t = _find(root, o['target'] as String);
    if (t == null) return false;
    for (final e in (o['props'] as Map).entries) {
      final v = e.value;
      if (v is String || v is num || v is bool) t[e.key as String] = v; else { return false; }
    }
    return true;
  }
  if (name == 'replace') {
    if (root['id'] == o['target']) return false; // root is rebuilt, never replaced
    final p = parentOf(root, o['target'] as String);
    if (p == null) return false;
    final kids = (p['children'] as List).cast<Map<String, dynamic>>();
    final i = kids.indexWhere((c) => c['id'] == o['target']);
    if (i < 0) return false;
    kids[i] = _clone(o['with'] as Map<String, dynamic>);
    return true;
  }
  if (name == 'add') {
    final kids = kidsOf(o['parent'] as String);
    if (kids == null) return false;
    final node = _clone(o['node'] as Map<String, dynamic>);
    if (_find(root, node['id'] as String) != null) return false; // ids stay unique
    final ix = o['index'] as int?;
    kids.insert(ix == null || ix > kids.length ? kids.length : ix, node);
    return true;
  }
  if (name == 'move') {
    final target = o['target'] as String;
    if (root['id'] == target) return false;
    final from = parentOf(root, target);
    final kids = kidsOf(o['parent'] as String);
    if (from == null || kids == null) return false;
    final i = (from['children'] as List).indexWhere((c) => (c as Map)['id'] == target);
    if (i < 0) return false;
    final node = (from['children'] as List).removeAt(i) as Map<String, dynamic>;
    final ix = o['index'] as int?;
    kids.insert(ix == null || ix > kids.length ? kids.length : ix, node);
    return true;
  }
  return false;
}

final panelProvider = StateNotifierProvider<PanelNotifier, PanelState>((_) => PanelNotifier());

class PanelNotifier extends StateNotifier<PanelState> {
  PanelNotifier() : super(const PanelState());

  /// A validated spec from a brain turn. Invalid specs and ops for another
  /// activity are ignored: the panel keeps showing what it has.
  void applySpec(Map<String, dynamic> raw) {
    final spec = validateUiSpec(raw);
    if (spec == null) return;
    final activity = spec['activity'] as String;
    if (spec['root'] != null) {
      final server = {...state.serverState, ...Map<String, dynamic>.from(spec['state'] as Map? ?? {})};
      state = PanelState(activity: activity, intent: (spec['intent'] as String?) ?? 'none', mode: (spec['mode'] as String?) ?? 'chat', companion: (spec['companion'] as String?) ?? 'docked',
          speak: spec['speak'] as String?, root: _clone(spec['root'] as Map<String, dynamic>),
          serverState: activity == state.activity ? server : Map<String, dynamic>.from(spec['state'] as Map? ?? {}),
          values: activity == state.activity ? state.values : const {}, lastAction: null);
      return;
    }
    if (!state.active || (activity.isNotEmpty && activity != state.activity)) return; // ops only patch the current panel
    var next = _clone(state.root!);
    for (final o in (spec['ops'] as List?) ?? []) {
      if (!_applyOp(next, (o as Map).cast<String, dynamic>())) return; // atomic: any failure keeps the old tree
    }
    final server = {...state.serverState, ...Map<String, dynamic>.from(spec['state'] as Map? ?? {})};
    for (final o in (spec['ops'] as List?) ?? []) {
      if ((o as Map)['op'] == 'state') server.addAll(Map<String, dynamic>.from(o['patch'] as Map));
    }
    state = state.copyWith(serverState: server, root: (spec['ops'] as List?)?.isNotEmpty == true ? next : null,
        intent: spec['intent'] as String?,
        mode: spec['mode'] as String?,
        companion: spec['companion'] as String?,
        speak: spec.containsKey('speak') ? () => spec['speak'] as String? : null);
  }

  String? _treeDefault(String itemId) {
    Map<String, dynamic>? walk(Map<String, dynamic> n) {
      for (final key in ['items', 'options', 'steps']) {
        if (n[key] is List) {
          for (final it in n[key] as List) {
            if ((it as Map)['id'] == itemId) return it as Map<String, dynamic>;
          }
        }
      }
      if (n['children'] is List) {
        for (final c in n['children'] as List) {
          final hit = walk(c as Map<String, dynamic>);
          if (hit != null) return hit;
        }
      }
      return null;
    }

    final root = state.root;
    if (root == null) return null;
    final it = walk(root);
    if (it == null) return null;
    if (it['done'] is bool) return (it['done'] as bool).toString();
    return null;
  }

  /// Checklist done-ness: the person's tap wins, else the tree's flag.
  bool isDone(String itemId) {
    final v = state.values[itemId];
    if (v is bool) return v;
    return _treeDefault(itemId) == 'true';
  }

  /// Selected choice option: the person's tap wins, else the tree's answer.
  String? answerOf(String nodeId) {
    final v = state.values[nodeId];
    if (v is String) return v;
    final root = state.root;
    if (root == null) return null;
    final n = _find(root, nodeId);
    return n?['answer'] as String?;
  }

  void toggle(String itemId) {
    state = state.copyWith(values: {...state.values, itemId: !isDone(itemId)}, lastAction: () => 'check:$itemId');
  }

  void answer(String nodeId, String optionId) {
    state = state.copyWith(values: {...state.values, nodeId: optionId}, lastAction: () => 'answer:$nodeId');
  }

  void recordAction(String name) => state = state.copyWith(lastAction: () => name);

  void clear() => state = const PanelState();
}
