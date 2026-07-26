import 'package:aikobox_mobile/features/profiles/data/update_schedule.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('UpdateSchedule.parse', () {
    test('an empty field is nothing', () {
      expect(UpdateSchedule.parse(''), isA<UpdateScheduleNone>());
      expect(UpdateSchedule.parse('   '), isA<UpdateScheduleNone>());
    });

    test('digits are minutes', () {
      expect(UpdateSchedule.parse('30'), const UpdateScheduleMinutes(30));
      expect(UpdateSchedule.parse(' 1440 '), const UpdateScheduleMinutes(1440));
    });

    test('a valid five-field expression is a cron', () {
      expect(
        UpdateSchedule.parse('0 * * * *'),
        const UpdateScheduleCron('0 * * * *'),
      );
    });

    test('anything else is invalid', () {
      final parsed = UpdateSchedule.parse('every tuesday');
      expect(parsed, isA<UpdateScheduleInvalid>());
      expect(parsed.isValid, isFalse);
    });
  });

  group('isValidCronExpression', () {
    test('accepts the common forms', () {
      expect(isValidCronExpression('* * * * *'), isTrue);
      expect(isValidCronExpression('0 * * * *'), isTrue);
      expect(isValidCronExpression('*/15 * * * *'), isTrue);
      expect(isValidCronExpression('0 0 * * 0'), isTrue);
      expect(isValidCronExpression('30 2 1 1 *'), isTrue);
      expect(isValidCronExpression('0,30 8-18 * * 1-5'), isTrue);
      expect(isValidCronExpression('0 0-23/2 * * *'), isTrue);
      expect(isValidCronExpression('  0   *  *  *  *  '), isTrue);
    });

    test('accepts month and weekday names', () {
      expect(isValidCronExpression('0 0 1 JAN *'), isTrue);
      expect(isValidCronExpression('0 0 * * MON-FRI'), isTrue);
      expect(isValidCronExpression('0 0 * dec sun'), isTrue);
    });

    test('accepts ? in the day fields', () {
      expect(isValidCronExpression('0 0 ? * MON'), isTrue);
      expect(isValidCronExpression('0 0 1 * ?'), isTrue);
    });

    test('rejects the wrong number of fields', () {
      expect(isValidCronExpression('* * * *'), isFalse);
      expect(isValidCronExpression('* * * * * *'), isFalse);
      expect(isValidCronExpression(''), isFalse);
    });

    test('rejects out-of-range values', () {
      expect(isValidCronExpression('60 * * * *'), isFalse);
      expect(isValidCronExpression('* 24 * * *'), isFalse);
      expect(isValidCronExpression('* * 0 * *'), isFalse);
      expect(isValidCronExpression('* * 32 * *'), isFalse);
      expect(isValidCronExpression('* * * 13 *'), isFalse);
      expect(isValidCronExpression('* * * * 8'), isFalse);
    });

    test('accepts 7 as Sunday', () {
      expect(isValidCronExpression('0 0 * * 7'), isTrue);
    });

    test('rejects malformed ranges and steps', () {
      expect(isValidCronExpression('5-1 * * * *'), isFalse);
      expect(isValidCronExpression('*/0 * * * *'), isFalse);
      expect(isValidCronExpression('*/ * * * *'), isFalse);
      expect(isValidCronExpression('/5 * * * *'), isFalse);
      expect(isValidCronExpression('1,,2 * * * *'), isFalse);
      expect(isValidCronExpression('1- * * * *'), isFalse);
    });

    test('rejects an unknown name', () {
      expect(isValidCronExpression('0 0 * FOO *'), isFalse);
      expect(isValidCronExpression('0 0 * * FUNDAY'), isFalse);
    });
  });

  group('kIntervalInputPattern', () {
    test('lets through what a number or a cron can contain', () {
      expect(kIntervalInputPattern.hasMatch('30'), isTrue);
      expect(kIntervalInputPattern.hasMatch('*/15 * * * *'), isTrue);
      expect(kIntervalInputPattern.hasMatch('0,30 8-18 * * 1-5'), isTrue);
      expect(kIntervalInputPattern.hasMatch(''), isTrue);
      expect(kIntervalInputPattern.hasMatch('abc'), isFalse);
    });
  });
}
