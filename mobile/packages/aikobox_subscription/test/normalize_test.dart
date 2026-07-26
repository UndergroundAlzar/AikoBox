/// Port of `src/main/config/subscriptionPayload.test.ts`.
///
/// Every case here exists because a real subscription server does the thing
/// being tested: captive portals answer with HTML, panels hand out Base64
/// blobs, and half the share links in circulation are hand-edited.
library;

import 'dart:convert';

import 'package:aikobox_subscription/aikobox_subscription.dart';
import 'package:test/test.dart';

String b64(String value) =>
    base64.encode(utf8.encode(value)).replaceAll(RegExp(r'=+$'), '');

String b64Url(String value) =>
    base64Url.encode(utf8.encode(value)).replaceAll(RegExp(r'=+$'), '');

List<Map<String, dynamic>> proxiesOf(Map<String, dynamic> config) =>
    (config['proxies'] as List).cast<Map<String, dynamic>>();

Matcher throwsFormat(String fragment) => throwsA(
  isA<SubscriptionFormatException>().having(
    (error) => error.message,
    'message',
    contains(fragment),
  ),
);

Matcher throwsBounds(String fragment) => throwsA(
  isA<SubscriptionBoundsException>().having(
    (error) => error.message,
    'message',
    contains(fragment),
  ),
);

void main() {
  group('subscription payload normalization', () {
    test('gives a group-less Clash YAML something to select and to match', () {
      const yaml =
          'proxies:\n'
          '  - { name: One, type: ss, server: 192.0.2.1, port: 443, '
          'cipher: aes-128-gcm, password: x }\n';
      final normalized = normalizeSubscription(yaml);
      final config = normalized.config;

      expect(normalized.format, SubscriptionFormat.clashYaml);
      expect(config['rules'], <String>['MATCH,Proxy']);
      final group = (config['proxy-groups'] as List).first as Map;
      expect(group['name'], 'Proxy');
      expect(group['type'], 'select');
      expect(group['proxies'], <String>['One']);
      // The node itself is passed through untouched — normalisation adds, it
      // never rewrites what the provider sent.
      expect(proxiesOf(config).single, <String, dynamic>{
        'name': 'One',
        'type': 'ss',
        'server': '192.0.2.1',
        'port': 443,
        'cipher': 'aes-128-gcm',
        'password': 'x',
      });
    });

    test('leaves an unsupported proxy type for the converter to refuse', () {
      // Normalisation is not the layer that knows what sing-box supports, so a
      // legacy SSR node must survive to where the refusal can be explained.
      final config = normalizeSubscriptionPayload(
        'proxies:\n  - { name: Legacy, type: ssr, server: 192.0.2.1, port: 443 }\n',
      );
      expect(proxiesOf(config).single['type'], 'ssr');
      expect(config['rules'], <String>['MATCH,Proxy']);
    });

    test('converts a Base64 URI list to Clash YAML with a usable group', () {
      final vmess =
          'vmess://${b64(jsonEncode(<String, dynamic>{'v': '2', 'ps': 'VMess HK', 'add': 'vmess.example', 'port': '443', 'id': '11111111-1111-1111-1111-111111111111', 'aid': '0', 'net': 'ws', 'host': 'cdn.example', 'path': '/ws', 'tls': 'tls', 'sni': 'vmess.example'}))}';
      final ss = 'ss://${b64('aes-128-gcm:secret')}@ss.example:8388#SS%20HK';
      const vless =
          'vless://22222222-2222-2222-2222-222222222222@vless.example:443'
          '?security=reality&sni=www.example.com&fp=chrome&pbk=public&sid=abcd'
          '&type=grpc&serviceName=svc#VLESS%20HK';

      final result = normalizeSubscription(
        b64(<String>[vmess, ss, vless].join('\n')),
      );
      final proxies = proxiesOf(result.config);

      expect(result.format, SubscriptionFormat.base64UriList);
      expect(result.proxyCount, 3);
      expect(proxies.map((proxy) => proxy['type']), <String>[
        'vmess',
        'ss',
        'vless',
      ]);
      expect((proxies[0]['ws-opts'] as Map)['path'], '/ws');
      expect(proxies[2]['reality-opts'], <String, dynamic>{
        'public-key': 'public',
        'short-id': 'abcd',
      });
      expect(
        ((result.config['proxy-groups'] as List).first as Map)['proxies'],
        <String>['VMess HK', 'SS HK', 'VLESS HK'],
      );
    });

    test(
      'rejects HTML, arbitrary Base64, unsupported schemes and empty configs',
      () {
        // A captive portal answering 200 with a login page is the single most
        // common way a subscription import goes wrong.
        expect(
          () => normalizeSubscriptionPayload('<html>login</html>'),
          throwsFormat('neither Clash'),
        );
        expect(
          () => normalizeSubscriptionPayload(b64('hello world')),
          throwsFormat('neither Clash'),
        );
        expect(
          () => normalizeSubscriptionPayload(b64('ssr://abc')),
          throwsFormat('not supported'),
        );
        expect(
          () => normalizeSubscriptionPayload('proxies: []\n'),
          throwsFormat('no proxy nodes'),
        );
        expect(
          () => normalizeSubscriptionPayload('proxies: invalid\n'),
          throwsFormat('must be a list'),
        );
      },
    );

    test('reports the source line number of a malformed URI field', () {
      expect(
        () => normalizeSubscriptionPayload(
          '# generated subscription\n\n'
          'vless://22222222-2222-2222-2222-222222222222@example.com:443'
          '?allowInsecure=maybe#Bad',
        ),
        throwsFormat('URI line 3: invalid boolean value'),
      );
      expect(
        () => normalizeSubscriptionPayload(
          'tuic://bad%name:password@example.com:443#TUIC',
        ),
        throwsFormat('URI line 1: invalid percent-encoding'),
      );
    });

    test('keeps a node whose display name is the only broken part', () {
      final config = normalizeSubscriptionPayload(
        'trojan://secret@example.com:443#broken%name',
      );
      expect(proxiesOf(config).single['name'], 'broken%name');
      expect(proxiesOf(config).single['password'], 'secret');
    });

    test('validates every declared Clash root field before accepting any', () {
      expect(
        () => normalizeSubscriptionPayload(
          'proxies: invalid\n'
          'proxy-providers:\n'
          '  remote:\n'
          '    type: http\n'
          '    url: https://example.invalid/sub\n',
        ),
        throwsFormat('"proxies" must be a list'),
      );
      expect(
        () => normalizeSubscriptionPayload(
          'proxies:\n  - { name: One, type: ss }\nproxy-providers: []\n',
        ),
        throwsFormat('"proxy-providers" must be a map'),
      );
    });

    test('does not expose decoded VMess payload fragments in parse errors', () {
      const secret = 'private-subscription-token';
      Object? failure;
      try {
        normalizeSubscriptionPayload('vmess://${b64('$secret-not-json')}');
      } catch (error) {
        failure = error;
      }

      expect(failure, isA<SubscriptionFormatException>());
      final message = (failure! as SubscriptionFormatException).message;
      expect(message, contains('VMess URI contains invalid JSON'));
      expect(message, isNot(contains(secret.substring(0, 10))));
    });

    test('accepts VMess fragments, boolean TLS flags and VLESS aliases', () {
      final vmess =
          'vmess://${b64(jsonEncode(<String, dynamic>{'add': 'vmess.example', 'port': 443, 'id': '11111111-1111-1111-1111-111111111111', 'net': 'ws', 'path': '/ws', 'tls': true, 'allowInsecure': true}))}#VMess%20Fragment';
      const vless =
          'vless://22222222-2222-2222-2222-222222222222@vless.example:443'
          '?packet-encoding=xudp#VLESS';

      final proxies = proxiesOf(normalizeSubscriptionPayload('$vmess\n$vless'));
      expect(proxies[0]['name'], 'VMess Fragment');
      expect(proxies[0]['tls'], isTrue);
      expect(proxies[0]['skip-cert-verify'], isTrue);
      expect(proxies[1]['packet-encoding'], 'xudp');
    });

    test('rejects non-canonical Base64 instead of decoding permissively', () {
      // "ZE==" has non-zero bits in its final group. A permissive decoder
      // returns "d" and the user gets a config built from noise.
      expect(
        () => normalizeSubscriptionPayload('ZE=='),
        throwsFormat('neither Clash'),
      );
    });

    test('bounds providers and URI expansion', () {
      expect(
        () => normalizeSubscriptionPayload(
          jsonEncode(<String, dynamic>{
            'proxies': <dynamic>[
              <String, dynamic>{'name': 'One', 'type': 'ss'},
            ],
            'proxy-providers': <String, dynamic>{
              for (
                var index = 0;
                index < kMaxSubscriptionProviders + 1;
                index += 1
              )
                'p$index': <String, dynamic>{
                  'type': 'inline',
                  'payload': <dynamic>[],
                },
            },
          }),
        ),
        throwsBounds('64 proxy providers'),
      );
      expect(
        () => normalizeSubscriptionPayload(
          'ss://${b64Url('aes-128-gcm:secret')}@example.com:443'
          '#${'x' * (kMaxSubscriptionLineLength + 1)}',
        ),
        throwsBounds('16384 characters'),
      );
    });

    test('recognises every sing-box-compatible URI scheme', () {
      final config = normalizeSubscriptionPayload(
        <String>[
          'trojan://secret@trojan.example:443?sni=trojan.example#Trojan',
          'hy2://secret@hy2.example:443?sni=hy2.example#Hy2',
          'hysteria://hy.example:443?auth=secret&upmbps=10&downmbps=50'
              '&peer=hy.example#Hy1',
          'tuic://11111111-1111-1111-1111-111111111111:secret@tuic.example:443'
              '?sni=tuic.example#TUIC',
          'anytls://secret@anytls.example:443?sni=anytls.example#AnyTLS',
          'shadowtls://secret@shadowtls.example:443?version=3'
              '&sni=shadowtls.example#ShadowTLS',
          'http://user:pass@http.example:8080#HTTP',
          'socks5://user:pass@socks.example:1080#SOCKS',
        ].join('\n'),
      );

      expect(proxiesOf(config).map((proxy) => proxy['type']), <String>[
        'trojan',
        'hysteria2',
        'hysteria',
        'tuic',
        'anytls',
        'shadowtls',
        'http',
        'socks5',
      ]);
    });

    test('treats a comment-only or blank body as having no nodes', () {
      expect(
        () => normalizeSubscriptionPayload('# nothing here\n\n# still nothing'),
        throwsFormat('neither Clash'),
      );
      expect(
        () => normalizeSubscriptionPayload('   \n\n'),
        throwsFormat('neither Clash'),
      );
    });
  });
}
