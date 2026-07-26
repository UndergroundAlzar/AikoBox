/// Replays the desktop's offline compatibility corpus against the Dart port.
///
/// `test/fixtures/subscription-uri-corpus.json` is a byte-for-byte copy of
/// `src/main/config/fixtures/subscription-uri-corpus.json`, so the two
/// implementations are held to the same 8 accepted and 6 refused cases. If the
/// desktop corpus grows, re-copy the file and this suite covers the new cases
/// automatically.
///
/// Mirrors `src/main/config/subscriptionCorpus.test.ts`.
library;

import 'dart:convert';
import 'dart:io';

import 'package:aikobox_subscription/aikobox_subscription.dart';
import 'package:test/test.dart';

Map<String, dynamic> _loadCorpus() {
  final file = File('test/fixtures/subscription-uri-corpus.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// The exact Clash proxy each corpus entry must normalise to.
///
/// Written out in full rather than spot-checked: the converter's zero-warning
/// contract depends on every one of these fields being present and named the
/// way Clash names it, and a missing `servername` or a `tls` that silently
/// became absent is exactly the kind of drift a `toMatchObject`-style
/// assertion lets through.
const List<Map<String, dynamic>> _expectedProxies = <Map<String, dynamic>>[
  <String, dynamic>{
    'name': 'Shared',
    'type': 'ss',
    'server': 'ss.example',
    'port': 8388,
    'cipher': 'aes-128-gcm',
    'password': 'secret',
    'udp': true,
  },
  <String, dynamic>{
    'name': 'SS2022',
    'type': 'ss',
    'server': 'ss2022.example',
    'port': 443,
    'cipher': '2022-blake3-aes-128-gcm',
    'password': 'MTIzNDU2Nzg5MDEyMzQ1Ng==',
    'udp': true,
  },
  <String, dynamic>{
    'name': 'Shared 2',
    'type': 'trojan',
    'server': 'trojan.example',
    'port': 443,
    'udp': true,
    'password': 'secret',
    'network': 'ws',
    'ws-opts': <String, dynamic>{
      'path': '/socket',
      'headers': <String, dynamic>{'Host': 'cdn.example'},
    },
    'tls': true,
    'servername': 'trojan.example',
  },
  <String, dynamic>{
    'name': 'Shared 3',
    'type': 'vmess',
    'server': 'vmess.example',
    'port': 443,
    'uuid': '11111111-1111-1111-1111-111111111111',
    'alterId': 0,
    'cipher': 'auto',
    'udp': true,
    'network': 'ws',
    'ws-opts': <String, dynamic>{
      'path': '/ws',
      'headers': <String, dynamic>{'Host': 'cdn.example'},
    },
    'tls': true,
    'servername': 'vmess.example',
  },
  <String, dynamic>{
    'name': 'VLESS',
    'type': 'vless',
    'server': 'vless.example',
    'port': 443,
    'udp': true,
    'uuid': '22222222-2222-2222-2222-222222222222',
    'network': 'grpc',
    'grpc-opts': <String, dynamic>{'grpc-service-name': 'edge'},
    'tls': true,
    'servername': 'www.example.com',
    'client-fingerprint': 'chrome',
    'reality-opts': <String, dynamic>{
      'public-key': 'public-key',
      'short-id': 'abcd',
    },
  },
  <String, dynamic>{
    'name': 'Hysteria2',
    'type': 'hysteria2',
    'server': 'hy2.example',
    'port': 443,
    'udp': true,
    'password': 'secret',
    'obfs': 'salamander',
    'obfs-password': 'cover',
    'tls': true,
    'servername': 'hy2.example',
  },
  <String, dynamic>{
    'name': 'TUIC',
    'type': 'tuic',
    'server': 'tuic.example',
    'port': 443,
    'udp': true,
    'uuid': '33333333-3333-3333-3333-333333333333',
    'password': 'secret',
    'congestion-controller': 'bbr',
    'udp-relay-mode': 'native',
    'tls': true,
    'servername': 'tuic.example',
  },
  <String, dynamic>{
    'name': 'ShadowTLS',
    'type': 'shadowtls',
    'server': 'shadowtls.example',
    'port': 443,
    'udp': true,
    'password': 'secret',
    'version': 3,
    'tls': true,
    'servername': 'www.example.com',
  },
];

void main() {
  final corpus = _loadCorpus();
  final valid = (corpus['valid'] as List).cast<Map<String, dynamic>>().toList(
    growable: false,
  );
  final invalid = (corpus['invalid'] as List)
      .cast<Map<String, dynamic>>()
      .toList(growable: false);

  group('offline subscription compatibility corpus', () {
    test(
      'normalizes every representative URI protocol without dropping a node',
      () {
        final payload = <String>[
          '# offline compatibility corpus',
          '',
          ...valid.map((item) => item['uri'] as String),
        ].join('\n');

        final first = normalizeSubscription(payload);
        final proxies = (first.config['proxies'] as List)
            .cast<Map<String, dynamic>>();

        expect(first.format, SubscriptionFormat.uriList);
        expect(first.proxyCount, valid.length);
        expect(
          proxies.map((proxy) => proxy['type']),
          valid.map((item) => item['type']),
        );
        expect(proxies, hasLength(_expectedProxies.length));
        for (var index = 0; index < proxies.length; index += 1) {
          expect(
            proxies[index],
            equals(_expectedProxies[index]),
            reason: 'corpus entry ${valid[index]['id']}',
          );
        }
      },
    );

    test('de-duplicates display names without renaming the first winner', () {
      final payload = valid.map((item) => item['uri'] as String).join('\n');
      final proxies = (normalizeSubscriptionPayload(payload)['proxies'] as List)
          .cast<Map<String, dynamic>>();
      final names = proxies.map((proxy) => proxy['name'] as String).toList();

      expect(names.toSet(), hasLength(names.length));
      expect(names.where((name) => name == 'Shared'), hasLength(1));
      expect(names, containsAll(<String>['Shared', 'Shared 2', 'Shared 3']));
    });

    test('synthesises a group and a terminal rule over the parsed nodes', () {
      final payload = valid.map((item) => item['uri'] as String).join('\n');
      final config = normalizeSubscriptionPayload(payload);
      final groups = (config['proxy-groups'] as List)
          .cast<Map<String, dynamic>>();
      final proxies = (config['proxies'] as List).cast<Map<String, dynamic>>();

      expect(groups, hasLength(1));
      expect(groups.single['name'], 'Proxy');
      expect(groups.single['type'], 'select');
      expect(
        groups.single['proxies'],
        proxies.map((proxy) => proxy['name']).toList(),
      );
      // Without this rule every packet would fall through to direct, which is
      // N4's silent degradation reached by omission.
      expect(config['rules'], <String>['MATCH,Proxy']);
    });

    test('re-normalising its own output is a no-op', () {
      final payload = valid.map((item) => item['uri'] as String).join('\n');
      final first = normalizeSubscription(payload);
      // JSON is a subset of YAML, so encoding the config is a faithful way to
      // hand it back to the parser without depending on a YAML writer.
      final second = normalizeSubscription(jsonEncode(first.config));

      expect(second.format, SubscriptionFormat.clashYaml);
      expect(second.config, equals(first.config));
    });

    test(
      'accepts standard and URL-safe Base64 wrappers, comments included',
      () {
        final decoded = <String>[
          '# provider comment',
          valid[0]['uri'] as String,
          '',
          valid[4]['uri'] as String,
        ].join('\n');
        final bytes = utf8.encode(decoded);
        final wrappers = <String>[
          base64.encode(bytes),
          base64Url.encode(bytes).replaceAll(RegExp(r'=+$'), ''),
        ];

        for (final encoded in wrappers) {
          final normalized = normalizeSubscription(encoded);
          expect(normalized.format, SubscriptionFormat.base64UriList);
          expect(normalized.proxyCount, 2);
          expect(
            (normalized.config['proxies'] as List)
                .cast<Map<String, dynamic>>()
                .map((proxy) => proxy['type']),
            <String>['ss', 'vless'],
          );
        }
      },
    );

    for (final item in invalid) {
      test('rejects malformed corpus case ${item['id']}', () {
        expect(
          () => normalizeSubscriptionPayload(item['payload'] as String),
          throwsA(
            predicate<Object>(
              (error) =>
                  error is SubscriptionFormatException &&
                  error.message.contains(item['error'] as String),
              'a SubscriptionFormatException mentioning "${item['error']}"',
            ),
          ),
        );
      });
    }

    test('leaves a provider-based Clash subscription structurally intact', () {
      final payload = File(
        'test/fixtures/subscription-clash-provider.yaml',
      ).readAsStringSync();
      final normalized = normalizeSubscription(payload);
      final config = normalized.config;
      final proxies = (config['proxies'] as List).cast<Map<String, dynamic>>();
      final groups = (config['proxy-groups'] as List)
          .cast<Map<String, dynamic>>();
      final providers = config['proxy-providers'] as Map<String, dynamic>;

      expect(normalized.format, SubscriptionFormat.clashYaml);
      expect(normalized.proxyCount, isNull);
      expect(proxies.map((proxy) => proxy['name']), <String>[
        'Shared',
        'Direct SS2022',
      ]);
      // The declared groups and rules are the author's; nothing is synthesised
      // over the top of them.
      expect(groups.map((group) => group['name']), <String>['Auto', 'Proxy']);
      expect(groups.first['use'], <String>['regional']);
      expect(config['rules'], <String>['MATCH,Proxy']);
      expect(providers.keys, <String>['regional']);
      expect(((providers['regional'] as Map)['payload'] as List), hasLength(3));
      // WireGuard keys and the SS2022 password survive untouched: the
      // converter needs them verbatim to emit a working outbound.
      expect(proxies.first['private-key'], 'private-key');
      expect(proxies.first['reserved'], <int>[1, 2, 3]);
      expect(proxies[1]['cipher'], '2022-blake3-aes-128-gcm');
      expect(proxies[1]['password'], 'MTIzNDU2Nzg5MDEyMzQ1Ng==');
    });

    test(
      'enforces node, group, rule and port boundaries deterministically',
      () {
        final validPorts =
            normalizeSubscriptionPayload(
                  <String>[
                    'trojan://secret@one.example:1#Min',
                    'trojan://secret@two.example:65535#Max',
                  ].join('\n'),
                )['proxies']
                as List;
        expect(
          validPorts.cast<Map<String, dynamic>>().map((proxy) => proxy['port']),
          <int>[1, 65535],
        );

        final uri = valid[0]['uri'] as String;
        expect(
          () => normalizeSubscriptionPayload(
            List<String>.filled(kMaxSubscriptionProxies + 1, uri).join('\n'),
          ),
          throwsA(
            isA<SubscriptionBoundsException>().having(
              (error) => error.message,
              'message',
              contains('10000 proxy nodes'),
            ),
          ),
        );

        expect(
          () => normalizeSubscriptionPayload(
            jsonEncode(<String, dynamic>{
              'proxies': <dynamic>[
                <String, dynamic>{'name': 'One', 'type': 'ss'},
              ],
              'proxy-groups': <dynamic>[
                for (
                  var index = 0;
                  index < kMaxSubscriptionGroups + 1;
                  index += 1
                )
                  <String, dynamic>{
                    'name': 'G$index',
                    'type': 'select',
                    'proxies': <String>['One'],
                  },
              ],
            }),
          ),
          throwsA(
            isA<SubscriptionBoundsException>().having(
              (error) => error.message,
              'message',
              contains('512 proxy groups'),
            ),
          ),
        );

        expect(
          () => normalizeSubscriptionPayload(
            jsonEncode(<String, dynamic>{
              'proxies': <dynamic>[
                <String, dynamic>{'name': 'One', 'type': 'ss'},
              ],
              'rules': List<String>.filled(
                kMaxSubscriptionRules + 1,
                'MATCH,One',
              ),
            }),
          ),
          throwsA(
            isA<SubscriptionBoundsException>().having(
              (error) => error.message,
              'message',
              contains('50000 rules'),
            ),
          ),
        );
      },
    );
  });
}
