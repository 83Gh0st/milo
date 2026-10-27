import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:milo/companion/director.dart';
import 'package:milo/contracts/brain_contract.dart';
import 'package:milo/contracts/events.dart';
import 'package:milo/core/pocket_brain.dart';
import 'package:milo/core/providers.dart';
import 'package:milo/net/api.dart';
import 'package:milo/net/voice.dart';
import 'package:milo/ui/learn_screen.dart';

void main() {
  test('contract keeps highlight/show_image/set_timer and drops bad ones', () {
    final t = validateTurn({'ui': [
      {'action': 'highlight', 'span': 'w14'},
      {'action': 'show_image', 'concept': 'Moon'},
      {'action': 'set_timer', 'seconds': 300},
      {'action': 'highlight', 'span': 'xx'},
      {'action': 'show_image', 'concept': 'gun'},
      {'action': 'show_image'},
      {'action': 'set_timer', 'seconds': 2},
      {'action': 'set_timer', 'seconds': 99999},
      {'action': 'set_timer', 'seconds': 'lots'},
    ]});
    expect(t.highlight, 'w14');
    expect(t.showImage, 'moon'); // allow-listed, normalised to lowercase
    expect(t.timerSeconds, 300); // gateway range is 5..3600 on both ends
    const d = BrainTurn();
    expect(d.highlight, isNull); expect(d.showImage, isNull); expect(d.timerSeconds, isNull);
    expect(const StreamError('timeout').code, 'timeout');
  });

  test('offline preference and a11y toggles round-trip through settings', () {
    final d = Director();
    d.set(() { d.offlineForced = true; d.ignoreTaps = true; d.leftHanded = true; });
    expect(d.toSettings()['offline.forced'], '1'); // the key the ladder and ledger read
    final back = Director()..loadSettings(d.toSettings());
    expect(back.offlineForced, isTrue);
    expect(back.ignoreTaps, isTrue);
    expect(back.leftHanded, isTrue);
  });

  test('pocket brain timeout message exists and memory is not "coming next"', () {
    final t = validateTurn(pocketBrain('hello there xyzzy', 'friendly', cloud: 'timeout'));
    expect(t.say.join(' '), contains('too long'));
    final m = validateTurn(pocketBrain('remember my birthday', 'friendly'));
    expect(m.say.join(' '), isNot(contains('coming next')));
  });

  test('sync banner mapping never leaks content', () {
    expect(syncBannerFor(CloudDisabled()), isNull); // ladder banner already covers offline
    expect(syncBannerFor(ApiError('offline')), 'Couldn’t sync just now.');
    expect(syncBannerFor(ApiError('http_500')), 'Couldn’t sync just now.');
    expect(syncBannerFor(Exception('vault secret hunter2')), 'Couldn’t sync just now.');
  });

  test('mic amplitude is 0 for silence and rises with signal', () {
    expect(micRms(Uint8List(480)), 0);
    expect(micRms(Uint8List(0)), 0);
    final loud = Uint8List(480);
    for (var i = 0; i < loud.length; i += 2) { loud[i] = 0x00; loud[i + 1] = 0x40; } // 0x4000 = quarter scale
    final v = micRms(loud);
    expect(v, greaterThan(0.5)); expect(v, lessThanOrEqualTo(1.0));
  });

  test('learn-words JSON validation keeps good entries and drops the rest', () {
    expect(parseLearnWords('{"words": [{"word": "Sun", "emoji": "🌤️"}, {"word": "x", "emoji": "e"}, {"word": "bad word!", "emoji": "e"}, {"nope": 1}]}'), [('sun', '🌤️')]);
    expect(parseLearnWords('[{"word": "dog", "emoji": "🐶"}]'), [('dog', '🐶')]);
    expect(parseLearnWords('not json'), isEmpty);
    expect(parseLearnWords('[]'), isEmpty);
    expect(parseLearnWords('{"words": "nope"}'), isEmpty);
  });
}
