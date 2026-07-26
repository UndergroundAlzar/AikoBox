import 'package:aikobox_mobile/features/connections/format.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('formatTrafficMagnitude', () {
    // Port fidelity with src/renderer/src/utils/calc.ts: two decimals while
    // they fit in five characters, one at six, none beyond.
    test('keeps two decimals for short numbers', () {
      expect(formatTrafficMagnitude(0), '0.00');
      expect(formatTrafficMagnitude(1.5), '1.50');
      expect(formatTrafficMagnitude(99.99), '99.99');
    });

    test('drops to one decimal at six characters', () {
      expect(formatTrafficMagnitude(100), '100.0');
      expect(formatTrafficMagnitude(999.94), '999.9');
    });

    test('rounds to a whole number beyond that', () {
      expect(formatTrafficMagnitude(1000), '1000');
      expect(formatTrafficMagnitude(1023.7), '1024');
    });
  });

  group('splitTraffic', () {
    test('stays in bytes below 1 KiB', () {
      expect(splitTraffic(0), (value: '0.00', unitKey: 'unit.b'));
      expect(splitTraffic(1023), (value: '1023', unitKey: 'unit.b'));
    });

    test('steps up a unit at each 1024', () {
      expect(splitTraffic(1024), (value: '1.00', unitKey: 'unit.kb'));
      expect(splitTraffic(1024 * 1024), (value: '1.00', unitKey: 'unit.mb'));
      expect(splitTraffic(1024 * 1024 * 1024), (
        value: '1.00',
        unitKey: 'unit.gb',
      ));
    });

    test('stops climbing at TB', () {
      const int tb = 1024 * 1024 * 1024 * 1024;
      expect(splitTraffic(tb * 4096), (value: '4096', unitKey: 'unit.tb'));
    });

    test('clamps a negative counter to zero rather than showing -3.00 MB', () {
      expect(splitTraffic(-1), (value: '0.00', unitKey: 'unit.b'));
    });
  });

  group('formatElapsedClock', () {
    test('is MM:SS under an hour', () {
      expect(formatElapsedClock(Duration.zero), '00:00');
      expect(formatElapsedClock(const Duration(seconds: 9)), '00:09');
      expect(
        formatElapsedClock(const Duration(minutes: 12, seconds: 4)),
        '12:04',
      );
    });

    test('grows an hours field and does not wrap at 24', () {
      expect(formatElapsedClock(const Duration(hours: 1)), '1:00:00');
      expect(
        formatElapsedClock(const Duration(hours: 49, minutes: 3, seconds: 11)),
        '49:03:11',
      );
    });

    test('treats a negative duration as zero', () {
      expect(formatElapsedClock(const Duration(seconds: -30)), '00:00');
    });
  });

  group('timestamps', () {
    test('formatClockTime zero-pads every field', () {
      final DateTime time = DateTime(2026, 7, 26, 4, 3, 9);
      expect(formatClockTime(time), '04:03:09');
    });

    test('formatTimestamp is a sortable local date and time', () {
      final DateTime time = DateTime(2026, 1, 2, 23, 59, 59);
      expect(formatTimestamp(time), '2026-01-02 23:59:59');
    });
  });
}
