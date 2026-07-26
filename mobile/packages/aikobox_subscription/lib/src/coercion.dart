/// The handful of JavaScript coercions the desktop parser leans on.
///
/// The TypeScript original is written in idiomatic JS: `a || b || ''`,
/// `String(x)`, `Number(x)`, `!value`. Reproducing those rules explicitly here
/// is what keeps the Dart port behaviourally identical instead of
/// approximately identical.
library;

import 'dart:convert';

import 'exceptions.dart';

/// JavaScript truthiness for the scalar types a decoded payload can hold.
///
/// Falsy: `null`, `false`, `0`, `0.0`, `NaN`, `''`. Everything else — including
/// an empty list or map, and the string `'0'` — is truthy.
bool jsTruthy(Object? value) {
  if (value == null || value == false) return false;
  if (value is num) return value != 0 && !value.isNaN;
  if (value is String) return value.isNotEmpty;
  return true;
}

/// `String(value)` when [value] is truthy, `''` otherwise.
///
/// Models the `String(a || b || '')` shape used throughout the original.
String jsStringOrEmpty(Object? value) =>
    jsTruthy(value) ? jsToString(value) : '';

/// `String(value)` for the JSON scalar types.
String jsToString(Object? value) {
  if (value == null) return 'null';
  if (value is double && value == value.roundToDouble() && value.isFinite) {
    return value.toInt().toString();
  }
  return value.toString();
}

/// `Number(value)`, returning null where JavaScript would produce `NaN`.
///
/// Deliberately narrower than JS in one place: hex literals (`'0x1f'`) are not
/// accepted. No real config writes a port in hex, and rejecting is the safe
/// direction.
double? jsNumber(Object? value) {
  if (value == null) return 0;
  if (value is bool) return value ? 1 : 0;
  if (value is num) return value.toDouble();
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return 0;
    return num.tryParse(trimmed)?.toDouble();
  }
  return null;
}

/// Validates a port the way the desktop's `numberPort` does.
///
/// Accepts 1..65535 inclusive; everything else — a fraction, a missing port,
/// text, out of range — is `invalid server port`.
int numberPort(Object? value) {
  final number = jsNumber(value);
  if (number == null ||
      number.isNaN ||
      number.isInfinite ||
      number != number.roundToDouble() ||
      number < 1 ||
      number > 65535) {
    throw const SubscriptionFormatException('invalid server port');
  }
  return number.toInt();
}

/// `decodeURIComponent`, with a malformed escape turned into a refusal.
///
/// Used for every field that ends up in a connection: credentials, ciphers,
/// hostnames. Display names use the forgiving path in `share_links.dart`
/// instead, because a broken label must not throw away a usable node.
String strictDecodeUriComponent(String value) {
  if (value.isEmpty) return value;
  try {
    return Uri.decodeComponent(value);
  } catch (_) {
    throw const SubscriptionFormatException('invalid percent-encoding');
  }
}

/// The Unicode replacement character Node substitutes for invalid UTF-8.
const String _replacementChar = '\u{FFFD}';

/// A NUL byte in a decoded payload means the bytes were never text.
const String _nul = '\u{0000}';

/// Decodes standard or URL-safe Base64 with the desktop's canonicity checks.
///
/// Rejects anything a permissive decoder would silently accept: a length that
/// cannot be a Base64 body, characters outside the alphabet, interior padding,
/// non-zero bits in the final partial group (`ZE==`), and byte sequences that
/// are not valid UTF-8 (`/w==`). Those are the cases where a permissive
/// decoder hands back plausible-looking garbage instead of an error.
String decodeSubscriptionBase64(String value) {
  final compact = value
      .replaceAll(RegExp(r'\s+'), '')
      .replaceAll('-', '+')
      .replaceAll('_', '/');
  if (compact.isEmpty ||
      compact.length % 4 == 1 ||
      !_base64Alphabet.hasMatch(compact) ||
      compact
          .substring(0, compact.length < 2 ? 0 : compact.length - 2)
          .contains('=')) {
    throw const SubscriptionFormatException('invalid Base64 data');
  }

  final padded = compact.padRight(((compact.length + 3) ~/ 4) * 4, '=');
  final List<int> bytes;
  try {
    bytes = base64.decode(padded);
  } on FormatException {
    // Dart's decoder rejects non-zero padding bits outright; Node's does not,
    // which is why the canonical re-encode below also exists.
    throw const SubscriptionFormatException('invalid Base64 data');
  }
  final canonical = base64.encode(bytes).replaceAll(_trailingPadding, '');
  if (canonical != compact.replaceAll(_trailingPadding, '')) {
    throw const SubscriptionFormatException('invalid Base64 data');
  }

  // Decoding leniently and then looking for U+FFFD mirrors Node's
  // `Buffer#toString('utf8')`, which substitutes rather than throwing.
  final result = utf8.decode(bytes, allowMalformed: true);
  if (result.isEmpty ||
      result.contains(_replacementChar) ||
      result.contains(_nul)) {
    throw const SubscriptionFormatException('invalid UTF-8 Base64 data');
  }
  return result;
}

final RegExp _base64Alphabet = RegExp(r'^[A-Za-z0-9+/]*={0,2}$');
final RegExp _trailingPadding = RegExp(r'=+$');
