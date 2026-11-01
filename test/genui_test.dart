import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:milo/genui/panel.dart';
import 'package:milo/genui/spec.dart';

// JSON round-trip: every map is Map<String, dynamic> (like real wire data),
// so the tests can graft actions/children onto any node. Bare literals would
// reify all-String maps that reject List values at runtime.
Map<String, dynamic> validSpec() => jsonDecode(jsonEncode({
      'v': 1,
      'activity': 'school-prep',
      'intent': 'guide',
      'mode': 'activity',
      'companion': 'docked',
      'root': {
        'id': 'panel',
        'type': 'card',
        'title': 'Get ready',
        'children': [
          {'id': 't1', 'type': 'text', 'text': "Let's pack."},
          {
            'id': 'cl',
            'type': 'checklist',
            'items': [
              {'id': 'i1', 'text': 'Water'},
              {'id': 'i2', 'text': 'Lunch', 'done': true}
            ]
          },
          {'id': 'go', 'type': 'button', 'label': 'Explain', 'action': {'action': 'ask', 'prompt': 'Which step?'}},
        ]
      },
      'state': {'step': 1},
    })) as Map<String, dynamic>;

void main() {
  group('spec validator', () {
    test('valid checklist spec passes', () {
      final out = validateUiSpec(validSpec())!;
      expect(out['activity'], 'school-prep');
      expect((out['root'] as Map)['children'], hasLength(3));
      expect(out['state'], {'step': 1});
    });
    test('empty, wrong version and shapeless specs are dropped', () {
      expect(validateUiSpec({}), isNull);
      expect(validateUiSpec('junk'), isNull);
      expect(validateUiSpec({'v': 99, 'root': {'id': 'a', 'type': 'divider'}}), isNull);
      expect(validateUiSpec({'v': 1}), isNull);
      final bad = validSpec()..['intent'] = 'hypnotize';
      expect(validateUiSpec(bad), isNull);
    });
    test('unknown root kills spec, unknown child is dropped', () {
      final bad = validSpec();
      (bad['root'] as Map)['type'] = 'teleporter';
      expect(validateUiSpec(bad), isNull);
      final drop = validSpec();
      ((drop['root'] as Map)['children'] as List).add({'id': 'x', 'type': 'teleporter'});
      final out = validateUiSpec(drop)!;
      expect(((out['root'] as Map)['children'] as List).map((c) => (c as Map)['id']), ['t1', 'cl', 'go']);
    });
    test('bad actions dropped, bad button dropped, node survives', () {
      final spec = validSpec();
      ((spec['root'] as Map)['children'] as List)[0]['actions'] = [
        {'action': 'launch_missiles'},
        {'action': 'speak', 'target': 't1'}
      ];
      final out = validateUiSpec(spec)!;
      expect(((out['root'] as Map)['children'] as List)[0]['actions'], [
        {'action': 'speak', 'target': 't1'}
      ]);
      final spec2 = validSpec();
      ((spec2['root'] as Map)['children'] as List).add({'id': 'b', 'type': 'button', 'label': 'Go', 'action': {'action': 'open_screen', 'screen': 'narnia'}});
      final out2 = validateUiSpec(spec2)!;
      expect(((out2['root'] as Map)['children'] as List).map((c) => (c as Map)['id']), ['t1', 'cl', 'go']);
    });
    test('image concept must be known', () {
      final spec = validSpec();
      ((spec['root'] as Map)['children'] as List).add({'id': 'im', 'type': 'image', 'concept': 'backpack'});
      expect(validateUiSpec(spec), isNotNull);
      ((spec['root'] as Map)['children'] as List).last['concept'] = 'mystery box';
      final out = validateUiSpec(spec)!;
      expect(((out['root'] as Map)['children'] as List).map((c) => (c as Map)['id']), isNot(contains('im')));
    });
    test('genimage keeps prompt and alt, drops short prompts, fills missing alt', () {
      List kids(Map<String, dynamic> s) => ((validateUiSpec(s)!['root'] as Map)['children'] as List);
      final spec = validSpec();
      ((spec['root'] as Map)['children'] as List).add({'id': 'g1', 'type': 'genimage', 'prompt': 'a friendly dinosaur', 'alt': 'A green cartoon dinosaur smiling'});
      var out = kids(spec).last as Map;
      expect(out['prompt'], 'a friendly dinosaur');
      expect(out['alt'], 'A green cartoon dinosaur smiling');
      final noAlt = validSpec();
      ((noAlt['root'] as Map)['children'] as List).add({'id': 'g1', 'type': 'genimage', 'prompt': 'a butterfly'});
      out = kids(noAlt).last as Map;
      expect(out['alt'], contains('AI-made picture'));
      final short = validSpec();
      ((short['root'] as Map)['children'] as List).add({'id': 'g1', 'type': 'genimage', 'prompt': 'x'});
      expect(kids(short).map((c) => (c as Map)['id']), isNot(contains('g1')));
    });
    test('strings sanitized and capped', () {
      final spec = validSpec();
      ((spec['root'] as Map)['children'] as List)[0]['text'] = 'see https://evil.example/x ${'y' * 900}';
      final out = validateUiSpec(spec)!;
      final txt = ((out['root'] as Map)['children'] as List)[0]['text'] as String;
      expect(txt, isNot(contains('evil.example')));
      expect(txt.length, lessThanOrEqualTo(uiMaxText));
    });
    test('duplicate ids, depth and size caps', () {
      final dup = validSpec();
      ((dup['root'] as Map)['children'] as List).add({'id': 't1', 'type': 'text', 'text': 'clone'});
      final out = validateUiSpec(dup)!;
      expect(((out['root'] as Map)['children'] as List).map((c) => (c as Map)['id']), ['t1', 'cl', 'go']);
      final big = {'v': 1, 'root': {'id': 'p', 'type': 'card', 'children': [for (var i = 0; i < 60; i++) {'id': 'c$i', 'type': 'divider'}]}};
      expect(validateUiSpec(big), isNull);
    });
    test('ops validate strictly', () {
      final ops = {
        'v': 1,
        'activity': 'school-prep',
        'ops': [
          {'op': 'update', 'target': 'cl', 'props': {'label': 'see https://evil.example', 'n': 3}},
          {'op': 'state', 'patch': {'step': 2}},
          {'op': 'remove', 'target': 't1'},
        ]
      };
      final out = validateUiSpec(ops)!;
      expect((out['ops'] as List), hasLength(3));
      expect(((out['ops'] as List)[0] as Map)['props']['label'], isNot(contains('evil.example')));
      expect(validateUiSpec({'v': 1, 'ops': [{'op': 'teleport', 'target': 'x'}]}), isNull);
      expect(validateUiSpec({'v': 1, 'ops': [{'op': 'update', 'target': 'x', 'props': {'items': [1]}}]}), isNull);
    });
  });

  group('panel store', () {
    test('root builds panel, invalid spec ignored', () {
      final p = PanelNotifier();
      expect(p.state.active, isFalse);
      p.applySpec({'v': 99});
      expect(p.state.active, isFalse);
      p.applySpec(validSpec());
      expect(p.state.active, isTrue);
      expect(p.state.activity, 'school-prep');
    });
    test('ops patch the current panel atomically', () {
      final p = PanelNotifier()..applySpec(validSpec());
      p.applySpec({'v': 1, 'activity': 'school-prep', 'ops': [
        {'op': 'remove', 'target': 't1'},
        {'op': 'state', 'patch': {'step': 2}},
      ]});
      final kids = ((p.state.root!)['children'] as List).map((c) => (c as Map)['id']);
      expect(kids, ['cl', 'go']);
      expect(p.state.serverState['step'], 2);
      p.applySpec({'v': 1, 'activity': 'school-prep', 'ops': [
        {'op': 'remove', 'target': 'nope'},
      ]});
      expect(((p.state.root!)['children'] as List), hasLength(2)); // failed batch keeps old tree
    });
    test('delta updates keep unsent display values', () {
      final root = validSpec()
        ..['mode'] = 'celebration'
        ..['companion'] = 'featured';
      final p = PanelNotifier()..applySpec(root);
      expect(p.state.mode, 'celebration');
      p.applySpec({'v': 1, 'activity': 'school-prep', 'ops': [
        {'op': 'remove', 'target': 't1'},
      ]});
      expect(p.state.mode, 'celebration');
      expect(p.state.companion, 'featured');
      expect(((p.state.root!)['children'] as List), hasLength(2));
    });
    test('ops for another activity are ignored', () {
      final p = PanelNotifier()..applySpec(validSpec());
      p.applySpec({'v': 1, 'activity': 'other', 'ops': [
        {'op': 'remove', 'target': 't1'},
      ]});
      expect(((p.state.root!)['children'] as List), hasLength(3));
    });
    test('new activity root resets interactions', () {
      final p = PanelNotifier()..applySpec(validSpec());
      p.toggle('i1');
      expect(p.isDone('i1'), isTrue);
      final next = validSpec()..['activity'] = 'bedtime';
      p.applySpec(next);
      expect(p.state.activity, 'bedtime');
      expect(p.state.values, isEmpty);
    });
    test('same-activity root rebuild keeps answers (stable ids)', () {
      final p = PanelNotifier()..applySpec(validSpec());
      p.toggle('i1');
      p.applySpec(validSpec());
      expect(p.isDone('i1'), isTrue);
    });
    test('toggle and answer record last action', () {
      final p = PanelNotifier()..applySpec(validSpec());
      expect(p.isDone('i2'), isTrue); // tree default
      p.toggle('i2');
      expect(p.isDone('i2'), isFalse);
      expect(p.state.lastAction, 'check:i2');
      p.answer('cl', 'i1');
      expect(p.state.lastAction, 'answer:cl');
    });
    test('snapshot is flat, scalar and capped', () {
      final p = PanelNotifier()..applySpec(validSpec());
      p.toggle('i1');
      final snap = p.state.snapshot();
      expect(snap['activity'], 'school-prep');
      expect(snap['last_action'], 'check:i1');
      expect(snap['i1'], isTrue);
      expect(snap.length, lessThanOrEqualTo(uiMaxContext));
      for (final v in snap.values) {
        expect(v is String || v is num || v is bool, isTrue);
      }
      expect(const PanelState().snapshot(), isEmpty);
    });
    test('move/add/replace ops reshape the tree', () {
      final p = PanelNotifier()..applySpec(validSpec());
      p.applySpec({'v': 1, 'activity': 'school-prep', 'ops': [
        {'op': 'move', 'target': 'go', 'parent': 'panel', 'index': 0},
      ]});
      expect(((p.state.root!)['children'] as List).map((c) => (c as Map)['id']), ['go', 't1', 'cl']);
      p.applySpec({'v': 1, 'activity': 'school-prep', 'ops': [
        {'op': 'replace', 'target': 't1', 'with': {'id': 't9', 'type': 'text', 'text': 'new'}},
      ]});
      expect(((p.state.root!)['children'] as List).map((c) => (c as Map)['id']), ['go', 't9', 'cl']);
      p.applySpec({'v': 1, 'activity': 'school-prep', 'ops': [
        {'op': 'add', 'parent': 'panel', 'node': {'id': 't9', 'type': 'text', 'text': 'dup'}},
      ]});
      expect(((p.state.root!)['children'] as List), hasLength(3)); // duplicate id rejected
    });
  });
}
