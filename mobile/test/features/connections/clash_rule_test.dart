import 'package:aikobox_mobile/features/connections/clash_rule.dart';
import 'package:flutter_test/flutter_test.dart';

/// Everything here is asserted against literal strings on purpose. These lines
/// get pasted into a user's `rules:` block, so the test has to fail if the
/// output drifts by so much as a `/32`.
void main() {
  group('clashDomainSuffixes', () {
    test('leaves a two-label name alone', () {
      expect(clashDomainSuffixes('example.com'), <String>['example.com']);
    });

    test('leaves a single label alone', () {
      expect(clashDomainSuffixes('localhost'), <String>['localhost']);
    });

    test('drops the bare TLD', () {
      expect(clashDomainSuffixes('a.b.example.com'), <String>[
        'a.b.example.com',
        'b.example.com',
        'example.com',
      ]);
    });

    test('handles a three-label name', () {
      expect(clashDomainSuffixes('cdn.example.com'), <String>[
        'cdn.example.com',
        'example.com',
      ]);
    });
  });

  group('clashRuleTextsFor', () {
    test('pins an IPv4 address to /32', () {
      expect(clashRuleTextsFor(ClashRulePrefix.ipCidr, '1.2.3.4'), <String>[
        'IP-CIDR,1.2.3.4/32',
      ]);
    });

    test('pins an IPv6 address to /128', () {
      expect(
        clashRuleTextsFor(ClashRulePrefix.srcIpCidr, '2001:db8::1'),
        <String>['SRC-IP-CIDR,2001:db8::1/128'],
      );
    });

    test('keeps only the number of an ASN', () {
      expect(
        clashRuleTextsFor(ClashRulePrefix.ipAsn, '13335 CLOUDFLARENET'),
        <String>['IP-ASN,13335'],
      );
      expect(
        clashRuleTextsFor(ClashRulePrefix.srcIpAsn, '4134 CHINANET'),
        <String>['SRC-IP-ASN,4134'],
      );
    });

    test('expands DOMAIN-SUFFIX into every usable suffix', () {
      expect(
        clashRuleTextsFor(ClashRulePrefix.domainSuffix, 'a.b.example.com'),
        <String>[
          'DOMAIN-SUFFIX,a.b.example.com',
          'DOMAIN-SUFFIX,b.example.com',
          'DOMAIN-SUFFIX,example.com',
        ],
      );
    });

    test('passes everything else straight through', () {
      expect(
        clashRuleTextsFor(ClashRulePrefix.processName, 'com.example.app'),
        <String>['PROCESS-NAME,com.example.app'],
      );
      expect(clashRuleTextsFor(ClashRulePrefix.dstPort, '443'), <String>[
        'DST-PORT,443',
      ]);
      expect(clashRuleTextsFor(ClashRulePrefix.network, 'udp'), <String>[
        'NETWORK,udp',
      ]);
    });

    test('produces nothing for an empty prefix or value', () {
      expect(clashRuleTextsFor('', '1.2.3.4'), isEmpty);
      expect(clashRuleTextsFor(ClashRulePrefix.domain, ''), isEmpty);
    });
  });

  group('clashRuleCandidates', () {
    test('puts the displayed value first, marked raw', () {
      final List<ClashRuleCandidate> candidates = clashRuleCandidates(
        displayValue: 'Tun(TCP)',
        targets: const <ClashRuleTarget>[
          ClashRuleTarget(ClashRulePrefix.inType, 'Tun'),
          ClashRuleTarget(ClashRulePrefix.network, 'tcp'),
        ],
      );
      expect(candidates.first.text, 'Tun(TCP)');
      expect(candidates.first.isRaw, isTrue);
      expect(
        candidates.skip(1).map((ClashRuleCandidate c) => c.text).toList(),
        <String>['IN-TYPE,Tun', 'NETWORK,tcp'],
      );
      expect(
        candidates.skip(1).every((ClashRuleCandidate c) => !c.isRaw),
        isTrue,
      );
    });

    test('pairs DOMAIN and DOMAIN-SUFFIX the way the host row does', () {
      final List<ClashRuleCandidate> candidates = clashRuleCandidates(
        displayValue: 'cdn.example.com',
        targets: const <ClashRuleTarget>[
          ClashRuleTarget(ClashRulePrefix.domain, 'cdn.example.com'),
          ClashRuleTarget(ClashRulePrefix.domainSuffix, 'cdn.example.com'),
        ],
      );
      expect(
        candidates.map((ClashRuleCandidate c) => c.text).toList(),
        <String>[
          'cdn.example.com',
          'DOMAIN,cdn.example.com',
          'DOMAIN-SUFFIX,cdn.example.com',
          'DOMAIN-SUFFIX,example.com',
        ],
      );
    });

    test('drops exact duplicates so the menu never repeats a line', () {
      final List<ClashRuleCandidate> candidates = clashRuleCandidates(
        displayValue: 'DOMAIN,example.com',
        targets: const <ClashRuleTarget>[
          ClashRuleTarget(ClashRulePrefix.domain, 'example.com'),
        ],
      );
      expect(candidates.length, 1);
      expect(candidates.single.isRaw, isTrue);
    });

    test('is empty when there is nothing to show or copy', () {
      expect(clashRuleCandidates(displayValue: ''), isEmpty);
    });
  });

  test('isIpv6Literal uses the desktop test', () {
    expect(isIpv6Literal('::1'), isTrue);
    expect(isIpv6Literal('1.2.3.4'), isFalse);
  });
}
