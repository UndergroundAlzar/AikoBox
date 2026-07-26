/// Port of `src/main/core/singbox/safeRegex.ts`.
///
/// Clash proxy-group `filter` / `exclude-filter` patterns come straight out of
/// a subscription, i.e. out of a remote server the user does not control. A
/// pattern like `^(a+)+$` run against a few thousand node names is a denial of
/// service against the app's own UI thread, so patterns are scanned for the
/// constructs that make backtracking blow up and rejected before they are ever
/// compiled.
library;

const int _maxPatternLength = 256;

/// Raised when a user-supplied filter pattern is refused.
///
/// The public [compileSafeClashRegex] swallows this and returns `null`, per the
/// build contract; the converter uses [compileSafeClashRegexOrThrow] so it can
/// put the reason in the error it reports to the user.
class ClashRegexException implements Exception {
  const ClashRegexException(this.message);

  final String message;

  @override
  String toString() => 'ClashRegexException: $message';
}

/// Compiles a Clash node filter, returning `null` when the pattern is rejected.
RegExp? compileSafeClashRegex(String pattern) {
  try {
    return compileSafeClashRegexOrThrow(pattern);
  } on ClashRegexException {
    return null;
  } on FormatException {
    return null;
  }
}

/// Compiles a Clash node filter, throwing [ClashRegexException] (or
/// [FormatException] from the engine) when the pattern is rejected.
RegExp compileSafeClashRegexOrThrow(String pattern) {
  String source = pattern;
  bool caseSensitive = true;
  if (source.startsWith('(?i)')) {
    source = source.substring(4);
    caseSensitive = false;
  }
  if (source.isEmpty || source.length > _maxPatternLength) {
    throw const ClashRegexException(
      'filter regex must contain 1-$_maxPatternLength characters',
    );
  }
  if (RegExp(r'\\(?:[1-9]|k<)').hasMatch(source)) {
    throw const ClashRegexException(
      'filter regex backreferences are not supported',
    );
  }

  final List<_Group> groups = <_Group>[];
  bool inCharacterClass = false;
  bool previousTokenWasQuantifier = false;
  bool closedGroupContainedQuantifier = false;

  for (int index = 0; index < source.length; index += 1) {
    final String character = source[index];
    if (character == r'\') {
      index += 1;
      previousTokenWasQuantifier = false;
      closedGroupContainedQuantifier = false;
      continue;
    }
    if (character == '[') {
      inCharacterClass = true;
      previousTokenWasQuantifier = false;
      closedGroupContainedQuantifier = false;
      continue;
    }
    if (character == ']' && inCharacterClass) {
      inCharacterClass = false;
      previousTokenWasQuantifier = false;
      closedGroupContainedQuantifier = false;
      continue;
    }
    if (inCharacterClass) continue;

    if (character == '(') {
      final String next = _charAt(source, index + 1);
      final String afterNext = _charAt(source, index + 2);
      if (next == '?' && afterNext != ':') {
        throw const ClashRegexException(
          'filter regex lookarounds and special groups are not supported',
        );
      }
      if (next == '?' && afterNext == ':') index += 2;
      groups.add(_Group());
      previousTokenWasQuantifier = false;
      closedGroupContainedQuantifier = false;
      continue;
    }
    if (character == ')') {
      if (groups.isEmpty) {
        throw const ClashRegexException(
          'filter regex has unbalanced parentheses',
        );
      }
      final _Group group = groups.removeLast();
      closedGroupContainedQuantifier = group.containsQuantifier;
      if (group.containsQuantifier && groups.isNotEmpty) {
        groups.last.containsQuantifier = true;
      }
      previousTokenWasQuantifier = false;
      continue;
    }

    bool isQuantifier =
        character == '*' || character == '+' || character == '?';
    if (character == '{') {
      final Match? match = _braceQuantifier.matchAsPrefix(source, index);
      if (match != null) {
        isQuantifier = true;
        index += match.group(0)!.length - 1;
      }
    }
    if (isQuantifier) {
      if (previousTokenWasQuantifier || closedGroupContainedQuantifier) {
        throw const ClashRegexException(
          'filter regex contains nested or repeated quantifiers',
        );
      }
      if (groups.isNotEmpty) groups.last.containsQuantifier = true;
      previousTokenWasQuantifier = true;
      closedGroupContainedQuantifier = false;
      continue;
    }

    previousTokenWasQuantifier = false;
    closedGroupContainedQuantifier = false;
  }

  if (inCharacterClass || groups.isNotEmpty) {
    throw const ClashRegexException('filter regex has unbalanced delimiters');
  }
  return RegExp(source, caseSensitive: caseSensitive);
}

final RegExp _braceQuantifier = RegExp(r'\{\d+(?:,\d*)?\}');

String _charAt(String source, int index) =>
    index >= 0 && index < source.length ? source[index] : '';

class _Group {
  bool containsQuantifier = false;
}
