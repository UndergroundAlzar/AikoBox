import 'package:aikobox_mobile/features/dashboard/dashboard.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  late AikoL10n l10n;

  setUp(() async {
    l10n = await primeEnglish();
  });

  tearDown(AikoL10n.resetForTests);

  group('formatBytes', () {
    test('matches the desktop calcTraffic ladder', () {
      expect(formatBytes(l10n, 0), '0.00 B');
      // "512.00" is six characters, so the desktop rule drops a decimal.
      expect(formatBytes(l10n, 512), '512.0 B');
      expect(formatBytes(l10n, 1024), '1.00 KB');
      expect(formatBytes(l10n, 1536), '1.50 KB');
      expect(formatBytes(l10n, 1024 * 1024), '1.00 MB');
      expect(formatBytes(l10n, 1024 * 1024 * 1024), '1.00 GB');
      expect(formatBytes(l10n, 1024 * 1024 * 1024 * 1024), '1.00 TB');
    });

    test(
      'narrows the precision as the number widens, like formatNumString',
      () {
        // 100.00 is 6 characters -> one decimal.
        expect(formatBytes(l10n, 100), '100.0 B');
        // 1000.00 is 7 -> rounded.
        expect(formatBytes(l10n, 1000), '1000 B');
      },
    );

    test('never renders a negative or non-finite reading', () {
      expect(formatBytes(l10n, -1), '0.00 B');
      expect(formatBytes(l10n, double.nan), '0.00 B');
      expect(formatBytes(l10n, double.infinity), '0.00 B');
    });
  });

  test('formatSpeed appends the localised per-second suffix', () {
    expect(formatSpeed(l10n, 1024), '1.00 KB/s');
  });

  test('formatDelay uses the ms unit key', () {
    expect(formatDelay(l10n, 142), '142 ms');
  });

  group('dates', () {
    test('formatDate is YYYY-MM-DD in local time', () {
      final DateTime when = DateTime(2026, 3, 7, 21, 5);
      expect(formatDate(when), '2026-03-07');
      expect(formatDateTime(when), '2026-03-07 21:05');
    });

    test('daysUntil floors at zero and ignores the past', () {
      final DateTime now = DateTime.now();
      expect(daysUntil(null), isNull);
      expect(daysUntil(now.subtract(const Duration(days: 3))), 0);
      expect(daysUntil(now.add(const Duration(days: 5, hours: 1))), 5);
    });
  });

  group('usagePercent', () {
    test('rounds and clamps', () {
      expect(usagePercent(used: 0, total: 100), 0);
      expect(usagePercent(used: 50, total: 100), 50);
      expect(usagePercent(used: 999, total: 100), 100);
      expect(usagePercent(used: 1, total: 3), 33);
    });

    test('an unlimited subscription is not 100 percent used', () {
      expect(usagePercent(used: 4096, total: 0), isNull);
      expect(usagePercent(used: 4096, total: -1), isNull);
    });
  });
}
