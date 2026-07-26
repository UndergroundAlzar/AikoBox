/// The Android platform branch — the one part of the converter that has no
/// counterpart in the desktop implementation.
///
/// `redir-port` and `tproxy-port` need root plus iptables rules that a
/// `VpnService`-hosted core cannot install, so they are skipped outright rather
/// than emitted and left to fail at startup. `auto_redirect` is gated on the
/// app's own setting.
library;

import 'package:test/test.dart';

import 'support.dart';

void main() {
  const ConvertOptions android = ConvertOptions(platform: 'android');
  const ConvertOptions androidRedirect =
      ConvertOptions(platform: 'android', autoRedirect: true);

  group('android inbounds', () {
    test('skips redir-port with a warning', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{'redir-port': 1234}),
        options: android,
      );
      expect(
        findWhere(inboundsOf(result.config), (Dict i) => i['type'] == 'redirect'),
        isNull,
      );
      expect(
        result.warnings,
        contains('redir-port is not supported on Android, skipped'),
      );
    });

    test('skips tproxy-port with a warning', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{'tproxy-port': 1235}),
        options: android,
      );
      expect(
        findWhere(inboundsOf(result.config), (Dict i) => i['type'] == 'tproxy'),
        isNull,
      );
      expect(
        result.warnings,
        contains('tproxy-port is not supported on Android, skipped'),
      );
    });

    test('a zero or absent redir/tproxy port produces no warning at all', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{'redir-port': 0, 'tproxy-port': 0}),
        options: android,
      );
      expect(joined(result.warnings), isNot(matches(RegExp('redir-port'))));
      expect(joined(result.warnings), isNot(matches(RegExp('tproxy-port'))));
    });

    test('mixed/socks/http listeners are untouched', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'mixed-port': 7890,
          'socks-port': 7891,
          'port': 7892,
        }),
        options: android,
      );
      expect(inboundsOf(result.config).length, 3);
    });
  });

  group('android auto_redirect gate', () {
    Dict tunProfile() => base(<String, dynamic>{
          'tun': <String, dynamic>{'enable': true, 'auto-redirect': true},
        });

    test('is emitted when the app allows it', () {
      final ConvertResult result =
          convertClashToSingbox(tunProfile(), options: androidRedirect);
      final Dict tun = findWhere(
        inboundsOf(result.config),
        (Dict i) => i['type'] == 'tun',
      )!;
      expect(tun['auto_redirect'], isTrue);
      expect(joined(result.warnings), isNot(matches(RegExp('auto-redirect'))));
    });

    test('is withheld with a warning when the app disallows it', () {
      final ConvertResult result =
          convertClashToSingbox(tunProfile(), options: android);
      final Dict tun = findWhere(
        inboundsOf(result.config),
        (Dict i) => i['type'] == 'tun',
      )!;
      expect(tun.containsKey('auto_redirect'), isFalse);
      // N5: a requested feature that is not delivered is never silent.
      expect(
        result.warnings,
        contains(
          'tun auto-redirect was requested but the app has it disabled, '
          'skipped',
        ),
      );
    });

    test('the app setting alone does not enable it', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'tun': <String, dynamic>{'enable': true},
        }),
        options: androidRedirect,
      );
      final Dict tun = findWhere(
        inboundsOf(result.config),
        (Dict i) => i['type'] == 'tun',
      )!;
      expect(tun.containsKey('auto_redirect'), isFalse);
    });

    test('linux still gets it from the profile alone', () {
      final ConvertResult result = convertClashToSingbox(
        tunProfile(),
        options: const ConvertOptions(platform: 'linux'),
      );
      final Dict tun = findWhere(
        inboundsOf(result.config),
        (Dict i) => i['type'] == 'tun',
      )!;
      expect(tun['auto_redirect'], isTrue);
    });

    test('win32 and darwin never get it', () {
      for (final String platform in <String>['win32', 'darwin', '']) {
        final ConvertResult result = convertClashToSingbox(
          tunProfile(),
          options: ConvertOptions(platform: platform),
        );
        final Dict tun = findWhere(
          inboundsOf(result.config),
          (Dict i) => i['type'] == 'tun',
        )!;
        expect(tun.containsKey('auto_redirect'), isFalse, reason: platform);
      }
    });
  });

  group('android route defaults', () {
    test('routing-mark is not emitted, because the tun is a VpnService fd', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{'routing-mark': 1234}),
        options: android,
      );
      expect(
        (result.config['route'] as Dict).containsKey('default_mark'),
        isFalse,
      );
    });

    test('linux and an unspecified platform still emit it', () {
      for (final String platform in <String>['linux', '']) {
        final ConvertResult result = convertClashToSingbox(
          base(<String, dynamic>{'routing-mark': 1234}),
          options: ConvertOptions(platform: platform),
        );
        expect(
          (result.config['route'] as Dict)['default_mark'],
          1234,
          reason: platform,
        );
      }
    });
  });

  group('the default ConvertOptions targets Android', () {
    test('platform defaults to android and autoRedirect to false', () {
      const ConvertOptions defaults = ConvertOptions();
      expect(defaults.platform, 'android');
      expect(defaults.autoRedirect, isFalse);
      expect(defaults.controllerSecret, isNull);
      expect(defaults.platformUnspecified, isFalse);
    });

    test('an empty platform reproduces the "not supplied" desktop branch', () {
      const ConvertOptions unspecified = ConvertOptions(platform: '');
      expect(unspecified.platformUnspecified, isTrue);
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{'tproxy-port': 1235}),
        options: unspecified,
      );
      expect(
        findWhere(inboundsOf(result.config), (Dict i) => i['type'] == 'tproxy'),
        isNotNull,
      );
    });
  });
}
