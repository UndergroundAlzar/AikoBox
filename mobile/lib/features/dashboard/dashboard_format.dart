/// Number and date formatting for the dashboard cards.
///
/// [formatBytes] is a direct port of the desktop's `calcTraffic`
/// (`src/renderer/src/utils/calc.ts`), down to its odd-looking but deliberate
/// precision rule: two decimals, dropped to one and then to zero as the number
/// gets wider, so a card's traffic readout never changes width enough to make
/// the layout jump.
///
/// Dates are formatted as `YYYY-MM-DD`, which is what the desktop's
/// `dayjs(...).format('YYYY-MM-DD')` produces and is unambiguous in all five
/// shipped locales. Nothing here calls `intl`'s `DateFormat`: that needs locale
/// symbol data initialised for every shipped locale, and a dashboard is not
/// worth that dependency.
library;

import '../../l10n/aiko_l10n.dart';

const List<String> _byteUnitKeys = <String>[
  'unit.b',
  'unit.kb',
  'unit.mb',
  'unit.gb',
  'unit.tb',
];

/// Port of `formatNumString`: two decimals, narrowed as the value widens.
String _significant(double value) {
  var text = value.toStringAsFixed(2);
  if (text.length <= 5) return text;
  if (text.length == 6) return value.toStringAsFixed(1);
  return value.round().toString();
}

/// `1536` -> `1.50 KB`. Unit symbols come from l10n so a locale can localise
/// them; the numeral itself is left in Western digits, matching the desktop.
String formatBytes(AikoL10n l10n, num bytes) {
  var value = bytes.toDouble();
  if (!value.isFinite || value < 0) value = 0;
  var index = 0;
  while (value >= 1024 && index < _byteUnitKeys.length - 1) {
    value /= 1024;
    index++;
  }
  return '${_significant(value)} ${l10n.t(_byteUnitKeys[index])}';
}

/// Bytes per second, e.g. `1.50 KB/s`.
String formatSpeed(AikoL10n l10n, num bytesPerSecond) =>
    '${formatBytes(l10n, bytesPerSecond)}${l10n.t('unit.speedSuffix')}';

/// A latency reading, e.g. `142 ms`.
String formatDelay(AikoL10n l10n, int milliseconds) =>
    '$milliseconds ${l10n.t('unit.ms')}';

String _pad2(int value) => value.toString().padLeft(2, '0');

/// `YYYY-MM-DD` in the device's local time zone.
String formatDate(DateTime time) {
  final local = time.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${_pad2(local.month)}-${_pad2(local.day)}';
}

/// `YYYY-MM-DD HH:MM` in the device's local time zone.
String formatDateTime(DateTime time) {
  final local = time.toLocal();
  return '${formatDate(local)} ${_pad2(local.hour)}:${_pad2(local.minute)}';
}

/// Whole days from now until [time], floored at zero. `null` when [time] is
/// null.
int? daysUntil(DateTime? time) {
  if (time == null) return null;
  final remaining = time.difference(DateTime.now());
  if (remaining.isNegative) return 0;
  return remaining.inDays;
}

/// Port of `calcPercent`: `0`–`100`, and `null` when there is no quota to
/// measure against (an unlimited subscription is not "100 % used").
int? usagePercent({required int used, required int total}) {
  if (total <= 0) return null;
  final percent = (used / total * 100).round();
  return percent.clamp(0, 100);
}
