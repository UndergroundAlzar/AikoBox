import 'package:aikobox_android/security/redaction.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('redacts URL credentials, query and fragment', () {
    final result = redactSensitive(
      'failed https://user:pass@example.com/private.json?token=abc#secret',
    );

    expect(result, contains('https://example.com/private.json'));
    expect(result, isNot(contains('user')));
    expect(result, isNot(contains('pass')));
    expect(result, isNot(contains('token')));
    expect(result, isNot(contains('secret')));
  });

  test('redacts UUIDs and named secrets', () {
    final result = redactSensitive(
      'uuid=550e8400-e29b-41d4-a716-446655440000 password=hunter2',
    );

    expect(result, isNot(contains('550e8400')));
    expect(result, isNot(contains('hunter2')));
    expect(result, contains('[REDACTED]'));
  });
}
