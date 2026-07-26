/// The auto-update schedule a profile carries.
///
/// The desktop lets `IProfileItem.interval` be either a plain number of minutes
/// or a five-field cron expression, and pairs it with an `allowFixedInterval`
/// flag (`edit-info-modal.tsx`, validated with the `cron-validator` package).
/// `ProfileItem.interval` in the Dart core is an `int?`, so the minutes half
/// lives there and the cron half lives in the profile's overlay document
/// alongside the other per-profile settings the core model has no field for.
///
/// The cron validator is a port of `cron-validator`'s `isValidCron(expr,
/// {seconds: false})`: five space-separated fields, each a list of ranges with
/// optional steps, plus month and weekday names.
library;

/// What the user typed into the interval field.
sealed class UpdateSchedule {
  const UpdateSchedule();

  /// Classifies [text] the way the desktop's interval field does.
  factory UpdateSchedule.parse(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return const UpdateScheduleNone();
    if (RegExp(r'^\d+$').hasMatch(trimmed)) {
      final minutes = int.tryParse(trimmed);
      if (minutes == null) return UpdateScheduleInvalid(trimmed);
      return UpdateScheduleMinutes(minutes);
    }
    if (isValidCronExpression(trimmed)) return UpdateScheduleCron(trimmed);
    return UpdateScheduleInvalid(trimmed);
  }

  bool get isValid => this is! UpdateScheduleInvalid;
}

/// Nothing entered.
class UpdateScheduleNone extends UpdateSchedule {
  const UpdateScheduleNone();
}

/// A fixed period in minutes.
class UpdateScheduleMinutes extends UpdateSchedule {
  const UpdateScheduleMinutes(this.minutes);

  final int minutes;

  @override
  bool operator ==(Object other) =>
      other is UpdateScheduleMinutes && other.minutes == minutes;

  @override
  int get hashCode => minutes.hashCode;
}

/// A five-field cron expression.
class UpdateScheduleCron extends UpdateSchedule {
  const UpdateScheduleCron(this.expression);

  final String expression;

  @override
  bool operator ==(Object other) =>
      other is UpdateScheduleCron && other.expression == expression;

  @override
  int get hashCode => expression.hashCode;
}

/// Neither a number nor a valid cron expression.
class UpdateScheduleInvalid extends UpdateSchedule {
  const UpdateScheduleInvalid(this.text);

  final String text;

  @override
  bool operator ==(Object other) =>
      other is UpdateScheduleInvalid && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

/// The characters the desktop's interval field lets through while typing.
final RegExp kIntervalInputPattern = RegExp(r'^[\d\s*\-,/]*$');

/// True when [expression] is a valid five-field cron expression.
bool isValidCronExpression(String expression) {
  final fields = expression.trim().split(RegExp(r'\s+'));
  if (fields.length != 5) return false;
  return _validField(fields[0], 0, 59) &&
      _validField(fields[1], 0, 23) &&
      _validField(fields[2], 1, 31, allowQuestionMark: true) &&
      _validField(fields[3], 1, 12, names: _months) &&
      _validField(fields[4], 0, 7, names: _weekdays, allowQuestionMark: true);
}

const List<String> _months = <String>[
  'jan',
  'feb',
  'mar',
  'apr',
  'may',
  'jun',
  'jul',
  'aug',
  'sep',
  'oct',
  'nov',
  'dec',
];

const List<String> _weekdays = <String>[
  'sun',
  'mon',
  'tue',
  'wed',
  'thu',
  'fri',
  'sat',
];

bool _validField(
  String field,
  int min,
  int max, {
  List<String> names = const <String>[],
  bool allowQuestionMark = false,
}) {
  if (field.isEmpty) return false;
  if (allowQuestionMark && field == '?') return true;
  for (final part in field.split(',')) {
    if (!_validPart(part, min, max, names)) return false;
  }
  return true;
}

bool _validPart(String part, int min, int max, List<String> names) {
  if (part.isEmpty) return false;

  var range = part;
  final slash = part.indexOf('/');
  if (slash != -1) {
    range = part.substring(0, slash);
    final step = part.substring(slash + 1);
    if (step.isEmpty || !RegExp(r'^\d+$').hasMatch(step)) return false;
    if (int.parse(step) < 1) return false;
    if (range.isEmpty) return false;
  }

  if (range == '*') return true;

  final dash = range.indexOf('-');
  if (dash > 0) {
    final from = _value(range.substring(0, dash), names);
    final to = _value(range.substring(dash + 1), names);
    if (from == null || to == null) return false;
    if (from < min || from > max || to < min || to > max) return false;
    return from <= to;
  }

  final value = _value(range, names);
  if (value == null) return false;
  return value >= min && value <= max;
}

int? _value(String token, List<String> names) {
  if (token.isEmpty) return null;
  if (RegExp(r'^\d+$').hasMatch(token)) return int.parse(token);
  if (names.isEmpty) return null;
  final index = names.indexOf(token.toLowerCase());
  if (index == -1) return null;
  // Month names are 1-based, weekday names 0-based — the same offset the two
  // fields' ranges already carry.
  return names == _months ? index + 1 : index;
}
