import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:milo/net/api.dart';
import 'package:milo/ui/chat_screen.dart';

void main() {
  group('image bytes honesty (Explore red-box regression)', () {
    test('PNG and JPEG pass; text/HTML/empty never render as pictures', () {
      expect(isPngOrJpeg(Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1])), isTrue);
      expect(isPngOrJpeg(Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xE0, 1])), isTrue);
      expect(isPngOrJpeg(Uint8List.fromList('<html>error</html>'.codeUnits)), isFalse);
      expect(isPngOrJpeg(Uint8List(0)), isFalse);
      expect(() => checkedImageBytes('not an image'.codeUnits), throwsA(isA<ApiError>()));
      expect(checkedImageBytes([0xFF, 0xD8, 9, 9]).length, 4);
    });
  });

  group('demo failure words', () {
    test('quota, busy and disabled each say their thing', () {
      expect(demoErrorWords('demo_quota_exceeded'), contains('Demo limit reached'));
      expect(demoErrorWords('demo_busy'), contains('busy'));
      expect(demoErrorWords('demo_disabled'), contains('turned off'));
      expect(demoErrorWords('offline'), isEmpty); // not a demo failure
    });

    test('picture failures never pretend success', () {
      expect(genImageErrorWords(ApiError('demo_quota_exceeded')), contains('Demo picture limit'));
      expect(genImageErrorWords(ApiError('bad_image_response')), contains('did not come back'));
      expect(genImageErrorWords(ApiError('offline')), contains('internet'));
    });

    test('voice failures keep typing available', () {
      expect(voiceErrorWords('mic_denied'), contains('microphone is off'));
      expect(voiceErrorWords('too_short'), contains('did not hear'));
      expect(voiceErrorWords('demo_quota_exceeded'), contains('still type'));
      for (final c in ['mic_denied', 'too_short', 'offline', 'asr_error']) {
        expect(voiceErrorWords(c), contains('type'), reason: c);
      }
    });
  });

  group('capability status lines', () {
    test('available, unverified and disabled are distinct', () {
      expect(capabilityLine('Pictures', {'status': 'available', 'route': 'demo'}), contains('ready via hosted demo'));
      expect(capabilityLine('Pictures', {'status': 'unverified', 'route': 'demo'}), contains('not yet proven'));
      expect(capabilityLine('Pictures', {'status': 'disabled', 'route': 'demo'}), contains('turned off'));
      expect(capabilityLine('Pictures', {'status': 'available', 'route': 'byok'}), contains('your key'));
      expect(capabilityLine('Pictures', {'status': 'available', 'route': 'open-weight'}), contains('open model'));
      expect(capabilityLine('Pictures', null), contains('not reported'));
    });
  });
}
