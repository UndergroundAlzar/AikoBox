/// Numeric formatting for the connections screens.
///
/// Two rules govern everything in this file:
///
/// * **Byte counts are a number plus an l10n key**, never a finished string.
///   [splitTraffic] returns the magnitude and the key of its unit; the widget
///   resolves the key. That keeps `unit.kb` translatable without this layer
///   knowing about `BuildContext`.
/// * **Times and durations are digit-only.** `14:03:57`, `2026-07-26 14:03:57`
///   and `01:12:04` read the same in all five shipped locales, need no date
///   symbols loaded into `intl`, and are what you actually want on a screen
///   whose job is debugging a tunnel.
///
/// The magnitude formatting is a direct port of the desktop's
/// `src/renderer/src/utils/calc.ts`, digit for digit, so a value shown on the
/// phone matches the same value shown on the desktop.
library;

import '../../l10n/aiko_l10n.dart';

/// l10n keys of the byte units, smallest first.
///
/// The ladder stops at TB on purpose: no key exists past it, and inventing an
/// untranslated `"PB"` in a widget would break the no-hardcoded-strings rule
/// for a magnitude no phone will ever report.
const List<String> kTrafficUnitKeys = <String>[
  'unit.b',
  'unit.kb',
  'unit.mb',
  'unit.gb',
  'unit.tb',
];

/// A byte count split into a rendered magnitude and the l10n key of its unit.
typedef TrafficAmount = ({String value, String unitKey});

/// Port of the desktop's `formatNumString`.
///
/// Two decimals, dropping precision rather than width as the number grows, so
/// the column never jitters: `9.99`, `99.99`, `999.9`, `1024`.
String formatTrafficMagnitude(double value) {
  final String twoPlaces = value.toStringAsFixed(2);
  if (twoPlaces.length <= 5) return twoPlaces;
  if (twoPlaces.length == 6) return value.toStringAsFixed(1);
  return value.round().toString();
}

/// Splits [bytes] into a magnitude and the l10n key of the unit it is in.
///
/// Negative counts are clamped to zero: the core occasionally reports a
/// decreasing cumulative counter across a reconnect, and `-3.00 MB` on screen
/// is worse than `0.00 B`.
TrafficAmount splitTraffic(int bytes) {
  double value = bytes <= 0 ? 0 : bytes.toDouble();
  int unit = 0;
  while (value >= 1024 && unit < kTrafficUnitKeys.length - 1) {
    value /= 1024;
    unit++;
  }
  return (value: formatTrafficMagnitude(value), unitKey: kTrafficUnitKeys[unit]);
}

/// `"1.20 MB"` — [splitTraffic] with its unit key resolved.
String formatTrafficText(AikoL10n l10n, int bytes) {
  final TrafficAmount amount = splitTraffic(bytes);
  return '${amount.value} ${l10n.t(amount.unitKey)}';
}

/// `"1.20 MB/s"`. The suffix is its own key because it is glued to the unit
/// without a space in English and is a separate word in some locales.
String formatSpeedText(AikoL10n l10n, int bytesPerSecond) =>
    '${formatTrafficText(l10n, bytesPerSecond)}${l10n.t('unit.speedSuffix')}';

String _two(int value) => value.toString().padLeft(2, '0');

/// `MM:SS`, or `H:MM:SS` once the duration passes an hour.
///
/// Hours are not wrapped at 24 — a connection open for two days shows `49:03:11`
/// rather than silently restarting.
String formatElapsedClock(Duration duration) {
  final int seconds = duration.isNegative ? 0 : duration.inSeconds;
  final int hours = seconds ~/ 3600;
  final int minutes = (seconds % 3600) ~/ 60;
  final int rest = seconds % 60;
  if (hours > 0) return '$hours:${_two(minutes)}:${_two(rest)}';
  return '${_two(minutes)}:${_two(rest)}';
}

/// `HH:MM:SS` in the device's local time zone.
String formatClockTime(DateTime time) {
  final DateTime local = time.toLocal();
  return '${_two(local.hour)}:${_two(local.minute)}:${_two(local.second)}';
}

/// `YYYY-MM-DD HH:MM:SS` in the device's local time zone.
String formatTimestamp(DateTime time) {
  final DateTime local = time.toLocal();
  return '${local.year.toString().padLeft(4, '0')}-${_two(local.month)}-'
      '${_two(local.day)} ${formatClockTime(local)}';
}
