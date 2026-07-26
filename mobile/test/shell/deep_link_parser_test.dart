import 'package:aikobox_mobile/features/shell/deep_link_parser.dart';
import 'package:flutter_test/flutter_test.dart';

/// Mirrors `src/main/deeplink.test.ts`. Where the desktop test asserts "the
/// confirm dialog was not shown", this asserts "the parse did not produce a
/// [DeepLinkSubscription]" — the confirmation is the next step and cannot
/// happen without one.
void main() {
  String link(String target, {String? name}) {
    final StringBuffer buffer = StringBuffer(
      'aikobox://install-config?url=${Uri.encodeComponent(target)}',
    );
    if (name != null) buffer.write('&name=${Uri.encodeComponent(name)}');
    return buffer.toString();
  }

  group('accepted links', () {
    test('a public HTTPS target parses into a confirmable request', () {
      const String target = 'https://airport.example/sub?token=secret';
      final DeepLinkResult result = parseAikoDeepLinkString(link(target));

      expect(result, isA<DeepLinkSubscription>());
      final DeepLinkSubscription request = result as DeepLinkSubscription;
      expect(request.url.toString(), target);
      expect(request.host, 'airport.example');
      expect(request.name, isNull);
    });

    for (final String scheme in <String>['clash', 'mihomo', 'aikobox']) {
      test('$scheme://install-config is accepted', () {
        const String target = 'https://airport.example/sub?token=secret';
        final DeepLinkResult result = parseAikoDeepLinkString(
          '$scheme://install-config?url=${Uri.encodeComponent(target)}',
        );
        expect(result, isA<DeepLinkSubscription>());
      });
    }

    test('the scheme is matched case-insensitively', () {
      final DeepLinkResult result = parseAikoDeepLinkString(
        'CLASH://install-config?url='
        '${Uri.encodeComponent('https://airport.example/sub')}',
      );
      expect(result, isA<DeepLinkSubscription>());
    });

    test('a name longer than 120 characters is truncated', () {
      final String longName = 'n' * 150;
      final DeepLinkResult result = parseAikoDeepLinkString(
        link('https://airport.example/sub', name: longName),
      );
      expect((result as DeepLinkSubscription).name, hasLength(120));
    });

    test('truncation never leaves a split surrogate pair behind', () {
      // 119 filler chars puts the emoji's high surrogate exactly on the
      // 120-unit boundary.
      final String name = '${'n' * 119}\u{1F600}tail';
      final String? truncated = truncateDeepLinkName(name);
      expect(truncated, hasLength(119));
      expect(truncated, isNot(contains('\uD83D')));
    });

    test('a blank name is dropped rather than passed through', () {
      final DeepLinkResult result = parseAikoDeepLinkString(
        link('https://airport.example/sub', name: '   '),
      );
      expect((result as DeepLinkSubscription).name, isNull);
    });
  });

  group('ignored links', () {
    test('another app\'s scheme is not ours', () {
      expect(
        parseAikoDeepLinkString('https://airport.example/sub'),
        isA<DeepLinkIgnored>(),
      );
    });

    test('an unknown host is a no-op, not an error', () {
      expect(
        parseAikoDeepLinkString(
          'aikobox://unknown-action?url='
          '${Uri.encodeComponent('https://airport.example/sub')}',
        ),
        isA<DeepLinkIgnored>(),
      );
    });
  });

  group('rejected links', () {
    test('a malformed link is reported, not thrown', () {
      expect(
        parseAikoDeepLinkString('clash://[not-a-host'),
        const DeepLinkRejected(DeepLinkRejection.malformed),
      );
    });

    test('install-config without a url parameter is rejected', () {
      expect(
        parseAikoDeepLinkString('aikobox://install-config?name=missing-url'),
        const DeepLinkRejected(DeepLinkRejection.missingUrl),
      );
    });

    const List<String> unsafe = <String>[
      'http://airport.example/sub?token=secret',
      'https://127.0.0.1/sub?token=secret',
      'https://10.0.0.5/sub?token=secret',
      'https://172.16.0.1/sub?token=secret',
      'https://172.31.255.254/sub?token=secret',
      'https://192.168.1.1/sub?token=secret',
      'https://169.254.1.1/sub?token=secret',
      'https://localhost/sub?token=secret',
      'https://api.localhost/sub?token=secret',
      'https://[::1]/sub?token=secret',
      'https://[fd00::1]/sub?token=secret',
      'https://[fe80::1]/sub?token=secret',
      'https://user:pass@airport.example/sub?token=secret',
    ];
    for (final String target in unsafe) {
      test('refuses $target', () {
        expect(
          parseAikoDeepLinkString(link(target)),
          const DeepLinkRejected(DeepLinkRejection.insecureTarget),
        );
      });
    }

    test('172.15 and 172.32 are public and stay allowed', () {
      expect(
        parseAikoDeepLinkString(link('https://172.15.0.1/sub')),
        isA<DeepLinkSubscription>(),
      );
      expect(
        parseAikoDeepLinkString(link('https://172.32.0.1/sub')),
        isA<DeepLinkSubscription>(),
      );
    });
  });

  group('secret hygiene (N7)', () {
    test('a rejection carries no part of the link', () {
      final DeepLinkResult result = parseAikoDeepLinkString(
        link('https://user:pass@airport.example/sub?token=secret'),
      );
      expect(result.toString(), isNot(contains('secret')));
      expect(result.toString(), isNot(contains('pass')));
    });

    test('an accepted request does not print its URL', () {
      final DeepLinkResult result = parseAikoDeepLinkString(
        link('https://airport.example/sub?token=secret'),
      );
      expect(result.toString(), contains('airport.example'));
      expect(result.toString(), isNot(contains('secret')));
    });
  });
}
