/// Number and date formatting for the profiles screens.
///
/// Ports the desktop's `calcTraffic` / `calcPercent`
/// (`src/renderer/src/utils/calc.ts`), including its precision rule: two
/// decimals, narrowed to one and then to none as the number widens, so a card's
/// traffic readout keeps a stable width and the layout never jumps.
///
/// Unit symbols come from `l10n` (`unit.b`, `unit.kb`, …) so the whole app
/// spells them the same way. Dates are `YYYY-MM-DD`, which is what the
/// desktop's `dayjs().format('YYYY-MM-DD')` produces and reads unambiguously in
/// all five shipped locales — `intl`'s `DateFormat` would need locale symbol
/// data initialised for each of them, which is not worth it for one line of
/// text on a card.
library;

import 'package:aikobox_mobile/l10n/aiko_l10n.dart';

const List<String> _byteUnitKeys = <String>[
  'unit.b',
  'unit.kb',
  'unit.mb',
  'unit.gb',
  'unit.tb',
];

String _significant(double value) {
  final text = value.toStringAsFixed(2);
  if (text.length <= 5) return text;
  if (text.length == 6) return value.toStringAsFixed(1);
  return value.round().toString();
}

/// `1536` -> `1.50 KB`.
String formatTraffic(AikoL10n l10n, num bytes) {
  var value = bytes.toDouble();
  if (!value.isFinite || value < 0) value = 0;
  var index = 0;
  while (value >= 1024 && index < _byteUnitKeys.length - 1) {
    value /= 1024;
    index++;
  }
  return '${_significant(value)} ${l10n.t(_byteUnitKeys[index])}';
}

String _pad2(int value) => value.toString().padLeft(2, '0');

/// `YYYY-MM-DD` in the device's local time zone.
String formatDay(DateTime time) {
  final local = time.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-'
      '${_pad2(local.month)}-${_pad2(local.day)}';
}

/// `YYYY-MM-DD HH:MM` in the device's local time zone.
String formatMinute(DateTime time) {
  final local = time.toLocal();
  return '${formatDay(local)} ${_pad2(local.hour)}:${_pad2(local.minute)}';
}

/// Whole days from now until [time], floored at zero; `null` when [time] is.
int? daysUntil(DateTime? time) {
  if (time == null) return null;
  final remaining = time.difference(DateTime.now());
  return remaining.isNegative ? 0 : remaining.inDays;
}

/// Port of `calcPercent`: `0`–`100`, or `null` when there is no quota to
/// measure against — an unlimited subscription is not "100 % used".
int? usagePercent({required int used, required int total}) {
  if (total <= 0) return null;
  return (used / total * 100).round().clamp(0, 100);
}
