/// Non-negotiable N7: a subscription URL, an auth token or a controller secret
/// must never reach a user-visible string.
///
/// The failure this guards against is quiet. A snackbar that reads "could not
/// reach https://panel.example/sub/9f3a…" is a screenshot away from handing
/// someone else the user's whole account.
library;

import 'dart:convert';

import 'package:aikobox_subscription/aikobox_subscription.dart';
import 'package:test/test.dart';

void main() {
  group('redactUrl', () {
    test('keeps the recognisable parts and drops everything else', () {
      expect(
        redactUrl('https://user:pw@sub.example.net/abc123/clash?token=t#frag'),
        'https://sub.example.net/***?***',
      );
    });

    test('does not invent a path or a query that was not there', () {
      expect(redactUrl('https://sub.example.net'), 'https://sub.example.net/');
      expect(redactUrl('https://sub.example.net/'), 'https://sub.example.net/');
    });

    test('keeps a non-default port and drops a default one', () {
      expect(
        redactUrl('https://sub.example.net:8443/x'),
        'https://sub.example.net:8443/***',
      );
      expect(
        redactUrl('https://sub.example.net:443/x'),
        'https://sub.example.net/***',
      );
    });

    test('re-brackets an IPv6 host', () {
      expect(
        redactUrl('https://[2001:db8::1]:8443/sub?k=v'),
        'https://[2001:db8::1]:8443/***?***',
      );
    });

    test('fails closed on anything it cannot take apart', () {
      // An unparseable string is precisely the case where we do not know which
      // part is the secret, so none of it is echoed.
      for (final input in <String>[
        '',
        '   ',
        'not a url',
        'file:///C:/Users/me/secrets.yaml',
        'mailto:someone@example.com',
        'data:text/plain;base64,c2VjcmV0',
        'https://',
        'http://[::1',
      ]) {
        expect(
          redactUrl(input),
          kRedactedUrlPlaceholder,
          reason: 'input: "$input"',
        );
      }
    });

    test('never leaks the userinfo, path or query of a real subscription', () {
      const url =
          'https://alice:hunter2@panel.example.net/sub/9f3a-secret-token'
          '?token=abcdef&flag=1#anchor';
      final redacted = redactUrl(url);
      for (final secret in <String>[
        'alice',
        'hunter2',
        '9f3a-secret-token',
        'abcdef',
        'anchor',
      ]) {
        expect(redacted, isNot(contains(secret)));
      }
      expect(redacted, contains('panel.example.net'));
    });
  });

  group('redactSecrets', () {
    test('rewrites an embedded URL through redactUrl', () {
      final message = redactSecrets(
        'request failed at https://example.invalid/private-path-token/sub'
        '?token=secret',
      );
      expect(message, isNot(contains('token=secret')));
      expect(message, isNot(contains('private-path-token')));
      expect(message, contains('https://example.invalid/***?***'));
    });

    test('replaces an Authorization value without eating the header name', () {
      expect(
        redactSecrets('Authorization: Bearer eyJhbGciOi.J9-abc_123'),
        'Authorization: $kRedactedAuthorization',
      );
      expect(
        redactSecrets('sent Basic YWxpY2U6aHVudGVyMg=='),
        'sent $kRedactedAuthorization',
      );
    });

    test('keeps the key and drops the value of a secret assignment', () {
      expect(
        redactSecrets('token=abc123&mode=rule'),
        'token=[redacted]&mode=rule',
      );
      expect(redactSecrets('password: hunter2'), 'password: [redacted]');
      expect(redactSecrets('api-key = k-9f3a'), 'api-key = [redacted]');
      expect(redactSecrets('auth_token:zzz'), 'auth_token:[redacted]');
    });

    test('collapses newlines and caps the length', () {
      expect(redactSecrets('a\r\n\tb'), 'a b');
      final flood = redactSecrets('x' * 5000);
      expect(flood.length, kMaxRedactedMessageLength);
    });

    test('leaves an innocuous message alone', () {
      expect(
        redactSecrets('subscription server returned HTTP 503'),
        'subscription server returned HTTP 503',
      );
    });

    test('is stable when applied twice', () {
      const raw = 'GET https://p.example/sub?token=t failed: Bearer abc';
      expect(redactSecrets(redactSecrets(raw)), redactSecrets(raw));
    });
  });

  group('parser messages carry no payload', () {
    /// Each of these hides the marker somewhere a naive implementation would
    /// echo it: a decoded VMess blob, a Base64 body, a Shadowsocks credential,
    /// an unparseable Clash document.
    const marker = 'ZZTOPSECRETZZ';

    final hostilePayloads = <String, String>{
      'vmess json': 'vmess://${base64.encode(utf8.encode('$marker-not-json'))}',
      'random base64': base64.encode(utf8.encode('$marker plain text')),
      'html login page': '<html><body>$marker</body></html>',
      'unsupported scheme': 'ssr://$marker',
      'bad ss credentials':
          'ss://${base64.encode(utf8.encode(marker))}@ss.example:8388',
      'broken clash proxies': 'proxies: $marker\n',
      'empty clash': 'proxies: []\n# $marker\n',
      'bad percent escape': 'tuic://$marker%zz:pw@a.example:443',
    };

    for (final entry in hostilePayloads.entries) {
      test('a ${entry.key} failure never quotes the payload', () {
        Object? failure;
        try {
          normalizeSubscriptionPayload(entry.value);
        } catch (error) {
          failure = error;
        }
        expect(
          failure,
          isNotNull,
          reason: 'expected ${entry.key} to be refused',
        );
        expect(failure.toString(), isNot(contains(marker)));
      });
    }
  });
}
