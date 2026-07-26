/// The YAML reading rules a Clash subscription depends on.
///
/// Exercised through the public entry point, because that is the only way the
/// app ever reaches them.
library;

import 'package:aikobox_subscription/aikobox_subscription.dart';
import 'package:test/test.dart';

List<Map<String, dynamic>> proxiesOf(Map<String, dynamic> config) =>
    (config['proxies'] as List).cast<Map<String, dynamic>>();

void main() {
  group('short-id quoting', () {
    test('keeps a numeric-looking Reality short id a string', () {
      // Unquoted, YAML reads 0123 as the integer 123 and 12e4 as 120000.0.
      // Either one silently breaks the Reality handshake with no error the
      // user could act on.
      final config = normalizeSubscriptionPayload(
        'proxies:\n'
        '  - name: A\n'
        '    type: vless\n'
        '    server: a.example\n'
        '    port: 443\n'
        '    reality-opts:\n'
        '      public-key: pk\n'
        '      short-id: 0123\n'
        '  - name: B\n'
        '    type: vless\n'
        '    server: b.example\n'
        '    port: 443\n'
        '    reality-opts: { public-key: pk, short-id: 12e4 }\n',
      );
      final proxies = proxiesOf(config);
      expect((proxies[0]['reality-opts'] as Map)['short-id'], '0123');
      expect((proxies[1]['reality-opts'] as Map)['short-id'], '12e4');
    });

    test('leaves an explicitly quoted or null short id alone', () {
      final config = normalizeSubscriptionPayload(
        'proxies:\n'
        '  - name: A\n'
        '    type: vless\n'
        '    server: a.example\n'
        '    port: 443\n'
        "    reality-opts: { public-key: pk, short-id: 'ab12' }\n"
        '  - name: B\n'
        '    type: vless\n'
        '    server: b.example\n'
        '    port: 443\n'
        '    reality-opts: { public-key: pk, short-id: null }\n',
      );
      final proxies = proxiesOf(config);
      expect((proxies[0]['reality-opts'] as Map)['short-id'], 'ab12');
      expect((proxies[1]['reality-opts'] as Map)['short-id'], isNull);
    });
  });

  group('anchors and merge keys', () {
    test('resolves a merge key the way YAML specifies', () {
      // Real subscriptions lean on anchors to avoid repeating a node template.
      // package:yaml leaves "<<" as an ordinary key, so it is resolved here.
      final config = normalizeSubscriptionPayload(
        'defaults: &defaults\n'
        '  type: ss\n'
        '  cipher: aes-128-gcm\n'
        '  password: shared\n'
        '  udp: true\n'
        'proxies:\n'
        '  - <<: *defaults\n'
        '    name: One\n'
        '    server: one.example\n'
        '    port: 443\n'
        '  - <<: *defaults\n'
        '    name: Two\n'
        '    server: two.example\n'
        '    port: 8388\n'
        '    password: overridden\n',
      );
      final proxies = proxiesOf(config);

      expect(proxies[0], <String, dynamic>{
        'name': 'One',
        'server': 'one.example',
        'port': 443,
        'type': 'ss',
        'cipher': 'aes-128-gcm',
        'password': 'shared',
        'udp': true,
      });
      // A key written in the map wins over the merged one.
      expect(proxies[1]['password'], 'overridden');
      expect(proxies[1]['cipher'], 'aes-128-gcm');
      expect(proxies.any((proxy) => proxy.containsKey('<<')), isFalse);
    });

    test('merges a list of sources with the earlier one winning', () {
      final config = normalizeSubscriptionPayload(
        'first: &first\n'
        '  cipher: aes-128-gcm\n'
        '  udp: true\n'
        'second: &second\n'
        '  cipher: chacha20-ietf-poly1305\n'
        '  password: fallback\n'
        'proxies:\n'
        '  - <<: [*first, *second]\n'
        '    name: One\n'
        '    type: ss\n'
        '    server: one.example\n'
        '    port: 443\n',
      );
      final proxy = proxiesOf(config).single;
      expect(proxy['cipher'], 'aes-128-gcm');
      expect(proxy['password'], 'fallback');
      expect(proxy['udp'], isTrue);
    });

    test('refuses a document whose anchors expand without bound', () {
      // A few hundred bytes on the wire, millions of nodes once expanded. The
      // document below is the classic billion-laughs shape.
      final buffer = StringBuffer('l0: &l0 [x, x, x, x, x, x, x, x, x, x]\n');
      for (var level = 1; level <= 5; level += 1) {
        final previous = List<String>.filled(10, '*l${level - 1}').join(', ');
        buffer.writeln('l$level: &l$level [$previous]');
      }
      buffer.writeln('boom: [*l5, *l5, *l5]');
      buffer.writeln('proxies:');
      buffer.writeln(
        '  - { name: One, type: ss, server: a.example, port: 443 }',
      );

      expect(
        () => normalizeSubscriptionPayload(buffer.toString()),
        throwsA(
          isA<SubscriptionBoundsException>().having(
            (error) => error.message,
            'message',
            contains('too large'),
          ),
        ),
      );
    });
  });

  group('structural passthrough', () {
    test('preserves unrelated Clash sections untouched', () {
      final config = normalizeSubscriptionPayload(
        'port: 7890\n'
        'mode: rule\n'
        'dns:\n'
        '  enable: true\n'
        '  nameserver: [1.1.1.1, 8.8.8.8]\n'
        'proxies:\n'
        '  - { name: One, type: ss, server: a.example, port: 443, '
        'cipher: aes-128-gcm, password: x }\n',
      );
      expect(config['port'], 7890);
      expect(config['mode'], 'rule');
      expect((config['dns'] as Map)['nameserver'], <String>[
        '1.1.1.1',
        '8.8.8.8',
      ]);
    });
  });
}
