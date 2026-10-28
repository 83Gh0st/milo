import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/contracts/brain_contract.dart';
import 'package:milo/contracts/events.dart';

void main() {
  group('validateTurn tools', () {
    test('accepts the three closed tools with clean args', () {
      final t = validateTurn({
        'say': ['Here you go.'],
        'ui': [
          {'action': 'read_aloud', 'span': 'w14'},
          {'action': 'break_into_steps', 'steps': ['Open the book', 'Read one page']},
          {'action': 'lookup_word', 'word': 'photosynthesis'},
        ]
      });
      expect(t.readAloud, 'w14');
      expect(t.steps, ['Open the book', 'Read one page']);
      expect(t.lookupWord, 'photosynthesis');
    });

    test('drops invented tools and malformed args', () {
      final t = validateTurn({
        'ui': [
          {'action': 'send_sms', 'to': '123'},
          {'action': 'read_aloud', 'span': 'paragraph 2'},
          {'action': 'read_aloud', 'span': 'w99999'},
          {'action': 'lookup_word', 'word': 'two words'},
          {'action': 'lookup_word', 'word': 'x'},
          {'action': 'break_into_steps', 'steps': 'not a list'},
        ]
      });
      expect(t.readAloud, isNull);
      expect(t.steps, isEmpty);
      expect(t.lookupWord, 'x'); // single letter is a word; the two-word attempt died
    });

    test('steps are cleaned, truncated, and capped', () {
      final t = validateTurn({
        'ui': [
          {
            'action': 'break_into_steps',
            'steps': ['Go to https://evil.test now', 'Call +1 555 123 4567', 'x' * 200, '', 'ok', 42, 'a', 'b', 'c', 'd', 'e', 'f']
          }
        ]
      });
      expect(t.steps.length, 8);
      expect(t.steps[0], 'Go to now');
      expect(t.steps[1], 'Call');
      expect(t.steps[2].length, 140);
      expect(t.steps[3], 'ok');
    });

    test('kActions mirrors the contract file', () {
      expect(kActions, ['highlight', 'offer_choices', 'show_image', 'open_screen', 'set_timer', 'read_aloud', 'break_into_steps', 'lookup_word']);
    });
  });

  group('director tool callbacks', () {
    test('batch turn fires read_aloud, steps, lookup', () async {
      final d = Director();
      String? aloud, lookup;
      List<String>? steps;
      d.onReadAloud = (s) => aloud = s;
      d.onSteps = (s) => steps = s;
      d.onLookupWord = (w) => lookup = w;
      await d.perform(const BrainTurn(say: ['hi'], readAloud: 'w2', steps: ['a', 'b'], lookupWord: 'sun'));
      expect(aloud, 'w2');
      expect(steps, ['a', 'b']);
      expect(lookup, 'sun');
      d.dispose();
    });

    test('streamed ui events fire the same callbacks', () async {
      final d = Director();
      String? aloud, lookup;
      List<String>? steps;
      d.onReadAloud = (s) => aloud = s;
      d.onSteps = (s) => steps = s;
      d.onLookupWord = (w) => lookup = w;
      Stream<BrainEvent> events() async* {
        yield const BrainEvent('ui', {'action': 'read_aloud', 'span': 'w3'});
        yield const BrainEvent('ui', {'action': 'break_into_steps', 'steps': ['x']});
        yield const BrainEvent('ui', {'action': 'lookup_word', 'word': 'moon'});
        yield const BrainEvent('done', {'followup': 'none'});
      }

      await d.performStream(events());
      expect(aloud, 'w3');
      expect(steps, ['x']);
      expect(lookup, 'moon');
      d.dispose();
    });
  });
}
