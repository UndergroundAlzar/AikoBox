import 'package:aikobox_mobile/features/connections/clash_rule.dart';
import 'package:aikobox_mobile/features/connections/connection_fields.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

void main() {
  group('splitHostPort', () {
    test('splits a name and port', () {
      expect(
        splitHostPort('example.com:443'),
        const HostPort(host: 'example.com', port: '443'),
      );
    });

    test('splits an IPv4 address and port', () {
      expect(
        splitHostPort('1.2.3.4:8080'),
        const HostPort(host: '1.2.3.4', port: '8080'),
      );
    });

    test('leaves a value with no port alone', () {
      expect(
        splitHostPort('example.com'),
        const HostPort(host: 'example.com', port: ''),
      );
    });

    test('uses the known destination to split an IPv6 address', () {
      expect(
        splitHostPort('2001:db8::1:443', knownHost: '2001:db8::1'),
        const HostPort(host: '2001:db8::1', port: '443'),
      );
    });

    test('does not truncate a bare IPv6 address it cannot verify', () {
      // '2001:db8::1' ends in digits after a colon and is indistinguishable
      // from host:port by inspection. Keeping it whole loses the port at worst;
      // splitting it would corrupt the address.
      expect(
        splitHostPort('2001:db8::1'),
        const HostPort(host: '2001:db8::1', port: ''),
      );
    });

    test('recognises a known IPv6 host with no port', () {
      expect(
        splitHostPort('2001:db8::1', knownHost: '2001:db8::1'),
        const HostPort(host: '2001:db8::1', port: ''),
      );
    });

    test('splits a bracketed IPv6 literal and strips the brackets', () {
      expect(
        splitHostPort('[2001:db8::1]:443'),
        const HostPort(host: '2001:db8::1', port: '443'),
      );
    });

    test('keeps a value whose tail is not a port whole', () {
      // Not a port, so not a split: truncating here would silently discard part
      // of whatever the core actually reported.
      expect(
        splitHostPort('example.com:https'),
        const HostPort(host: 'example.com:https', port: ''),
      );
      expect(
        splitHostPort('example.com:123456'),
        const HostPort(host: 'example.com:123456', port: ''),
      );
    });

    test('handles an empty value', () {
      expect(splitHostPort(''), const HostPort(host: '', port: ''));
    });
  });

  group('connectionFieldsOf', () {
    test('separates a sniffed name from its port', () {
      final ConnectionFields fields = connectionFieldsOf(
        makeConnection(
          id: '1',
          host: 'cdn.example.com:443',
          destinationIp: '93.184.216.34',
        ),
      );
      expect(fields.hostname, 'cdn.example.com');
      expect(fields.port, '443');
      expect(fields.hostIsAddress, isFalse);
      expect(fields.destinationLabel, 'cdn.example.com:443');
    });

    test('marks a host that is only the destination address', () {
      final ConnectionFields fields = connectionFieldsOf(
        makeConnection(
          id: '1',
          host: '93.184.216.34:443',
          destinationIp: '93.184.216.34',
        ),
      );
      expect(fields.hostname, '93.184.216.34');
      expect(fields.hostIsAddress, isTrue);
      // No DOMAIN rule is offered for a bare address, which is what the
      // desktop does by only attaching those prefixes to metadata.host.
      expect(fields.hostTargets, isEmpty);
    });

    test('offers DOMAIN and DOMAIN-SUFFIX for a real name', () {
      final ConnectionFields fields = connectionFieldsOf(
        makeConnection(id: '1', host: 'example.com:443'),
      );
      expect(fields.hostTargets, const <ClashRuleTarget>[
        ClashRuleTarget(ClashRulePrefix.domain, 'example.com'),
        ClashRuleTarget(ClashRulePrefix.domainSuffix, 'example.com'),
      ]);
    });

    test('reverses the chain the way the desktop shows it', () {
      final ConnectionFields fields = connectionFieldsOf(
        makeConnection(
          id: '1',
          chains: const <String>['HK-01', 'Streaming', 'PROXY'],
        ),
      );
      expect(fields.chain, 'PROXY>>Streaming>>HK-01');
    });

    test('folds the rule payload into the rule label', () {
      expect(
        connectionFieldsOf(
          makeConnection(
            id: '1',
            rule: 'DomainSuffix',
            rulePayload: 'example.com',
          ),
        ).rule,
        'DomainSuffix(example.com)',
      );
      expect(
        connectionFieldsOf(
          makeConnection(id: '1', rule: 'Match', rulePayload: ''),
        ).rule,
        'Match',
      );
    });

    test('prefers the process over the source address for the origin', () {
      expect(
        connectionFieldsOf(
          makeConnection(id: '1', process: 'com.example.app'),
        ).originLabel,
        'com.example.app',
      );
      expect(
        connectionFieldsOf(
          makeConnection(id: '1', process: '', sourceIp: '10.0.0.2'),
        ).originLabel,
        '10.0.0.2',
      );
    });

    test('builds the type label the way the detail modal does', () {
      expect(
        connectionFieldsOf(
          makeConnection(id: '1', type: 'Tun', network: 'udp'),
        ).typeLabel,
        'Tun(UDP)',
      );
      expect(
        connectionFieldsOf(
          makeConnection(id: '1', type: '', network: 'tcp'),
        ).typeLabel,
        'TCP',
      );
    });
  });

  group('connectionHaystack', () {
    test('covers every searchable field, lower-cased', () {
      final String haystack = connectionHaystack(
        makeConnection(
          id: 'abc',
          host: 'CDN.Example.COM:443',
          process: 'com.Example.App',
          chains: const <String>['HK-01'],
          upload: 4096,
        ),
      );
      expect(haystack, contains('cdn.example.com:443'));
      expect(haystack, contains('com.example.app'));
      expect(haystack, contains('hk-01'));
      expect(haystack, contains('93.184.216.34'));
      expect(haystack, contains('4096'));
      expect(haystack, haystack.toLowerCase());
    });
  });
}
