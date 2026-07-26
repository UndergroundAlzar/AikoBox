import 'package:aikobox_mobile/features/profiles/data/rule_syntax.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ClashRule.parse', () {
    test('reads a three-field rule', () {
      final rule = ClashRule.parse('DOMAIN-SUFFIX,example.com,PROXY');
      expect(rule.type, 'DOMAIN-SUFFIX');
      expect(rule.payload, 'example.com');
      expect(rule.proxy, 'PROXY');
      expect(rule.params, isEmpty);
      expect(rule.offset, isNull);
    });

    test('keeps extra parameters in order', () {
      final rule = ClashRule.parse('GEOIP,CN,DIRECT,no-resolve,src');
      expect(rule.params, <String>['no-resolve', 'src']);
      expect(rule.format(), 'GEOIP,CN,DIRECT,no-resolve,src');
    });

    test('MATCH carries an outbound and no payload', () {
      final rule = ClashRule.parse('MATCH,PROXY');
      expect(rule.isMatch, isTrue);
      expect(rule.payload, isEmpty);
      expect(rule.proxy, 'PROXY');
      expect(rule.format(), 'MATCH,PROXY');
    });

    test('a leading number is an offset only with three fields after it', () {
      final withOffset = ClashRule.parse('5,DOMAIN,a.com,DIRECT');
      expect(withOffset.offset, 5);
      expect(withOffset.type, 'DOMAIN');
      expect(withOffset.format(), '5,DOMAIN,a.com,DIRECT');
      expect(withOffset.formatWithoutOffset(), 'DOMAIN,a.com,DIRECT');

      // Only two fields follow, so `1234` is the rule type, odd as that is.
      final withoutOffset = ClashRule.parse('1234,DIRECT');
      expect(withoutOffset.offset, isNull);
      expect(withoutOffset.type, '1234');
    });

    test('offset zero is not an offset', () {
      expect(ClashRule.parse('0,DOMAIN,a.com,DIRECT').offset, isNull);
    });

    test('drops blank trailing parameters', () {
      expect(ClashRule.parse('GEOIP,CN,DIRECT, ,').params, isEmpty);
    });
  });

  group('canAddRule', () {
    test('needs a payload, a type and an outbound', () {
      expect(
        canAddRule(
          const ClashRule(type: 'DOMAIN', payload: 'a.com', proxy: 'DIRECT'),
        ),
        isTrue,
      );
      expect(
        canAddRule(const ClashRule(type: 'DOMAIN', proxy: 'DIRECT')),
        isFalse,
      );
      expect(
        canAddRule(const ClashRule(type: 'DOMAIN', payload: 'a.com')),
        isFalse,
      );
    });

    test('MATCH needs no payload', () {
      expect(canAddRule(const ClashRule(type: 'MATCH', proxy: 'PROXY')), isTrue);
    });

    test('refuses a payload the type rejects', () {
      expect(
        canAddRule(
          const ClashRule(
            type: 'IP-CIDR',
            payload: 'not-an-address',
            proxy: 'DIRECT',
          ),
        ),
        isFalse,
      );
    });
  });

  group('the rule table', () {
    test('MATCH is last and every type has a definition', () {
      expect(kRuleTypes.last, kMatchRuleType);
      for (final type in kRuleTypes) {
        expect(ruleDefinition(type), isNotNull, reason: type);
      }
    });

    test('only the types the desktop marks accept no-resolve and src', () {
      expect(ruleSupportsNoResolve('GEOIP'), isTrue);
      expect(ruleSupportsSrc('GEOIP'), isTrue);
      expect(ruleSupportsNoResolve('IP-CIDR'), isTrue);
      expect(ruleSupportsNoResolve('RULE-SET'), isTrue);
      expect(ruleSupportsNoResolve('DOMAIN'), isFalse);
      expect(ruleSupportsSrc('SRC-GEOIP'), isFalse);
    });

    test('every example passes its own validator', () {
      for (final type in kRuleTypes) {
        final definition = kRuleDefinitions[type]!;
        if (definition.example.isEmpty) continue;
        expect(
          validateRulePayload(type, definition.example),
          isTrue,
          reason: '$type example "${definition.example}" fails its validator',
        );
      }
    });

    test('an unknown type accepts anything', () {
      expect(validateRulePayload('NOT-A-RULE', 'whatever'), isTrue);
    });
  });

  group('validators', () {
    test('domains', () {
      expect(isValidDomain('example.com'), isTrue);
      expect(isValidDomain('sub.example.co.uk'), isTrue);
      expect(isValidDomain('localhost'), isTrue);
      expect(isValidDomain('example'), isFalse);
      expect(isValidDomain('-bad.com'), isFalse);
      expect(isValidDomain('a'), isFalse);
      expect(isValidDomain('under_score.com'), isFalse);
    });

    test('domain suffixes allow a leading wildcard', () {
      expect(isValidDomainSuffix('*.example.com'), isTrue);
      expect(isValidDomainSuffix('example.com'), isTrue);
      expect(isValidDomainSuffix('*'), isFalse);
    });

    test('domain keywords reject commas and spaces', () {
      expect(isValidDomainKeyword('google'), isTrue);
      expect(isValidDomainKeyword('a,b'), isFalse);
      expect(isValidDomainKeyword('a b'), isFalse);
      expect(isValidDomainKeyword(''), isFalse);
    });

    test('domain wildcards need a dot and only * and ?', () {
      expect(isValidDomainWildcard('*.google.com'), isTrue);
      expect(isValidDomainWildcard('goo?le.com'), isTrue);
      expect(isValidDomainWildcard('google'), isFalse);
      expect(isValidDomainWildcard('goo gle.com'), isFalse);
    });

    test('IPv4', () {
      expect(isValidIpv4('127.0.0.1'), isTrue);
      expect(isValidIpv4('255.255.255.255'), isTrue);
      expect(isValidIpv4('256.0.0.1'), isFalse);
      expect(isValidIpv4('01.0.0.1'), isFalse);
      expect(isValidIpv4('1.2.3'), isFalse);
    });

    test('IPv6', () {
      expect(isValidIpv6('2001:0db8:0000:0000:0000:ff00:0042:8329'), isTrue);
      expect(isValidIpv6('2620:0:2d0:200::7'), isTrue);
      expect(isValidIpv6('::1'), isTrue);
      expect(isValidIpv6('::ffff:192.0.2.1'), isTrue);
      expect(isValidIpv6('2001::db8::1'), isFalse);
      expect(isValidIpv6('12345::'), isFalse);
      expect(isValidIpv6('127.0.0.1'), isFalse);
    });

    test('CIDR blocks bound the prefix to the family', () {
      expect(isValidIpCidr('127.0.0.0/8'), isTrue);
      expect(isValidIpCidr('127.0.0.0/33'), isFalse);
      expect(isValidIpCidr('2620:0:2d0:200::7/32'), isTrue);
      expect(isValidIpCidr('2620:0:2d0:200::7/129'), isFalse);
      expect(isValidIpCidr('127.0.0.0'), isFalse);
    });

    test('port ranges', () {
      expect(isValidPortRange('80'), isTrue);
      expect(isValidPortRange('8000-9000'), isTrue);
      expect(isValidPortRange('9000-8000'), isFalse);
      expect(isValidPortRange('70000'), isFalse);
      expect(isValidPortRange('80-'), isFalse);
    });

    test('numeric ranges', () {
      expect(isValidAsn('13335'), isTrue);
      expect(isValidAsn('0'), isFalse);
      expect(isValidUid('65535'), isTrue);
      expect(isValidUid('65536'), isFalse);
      expect(isValidDscp('63'), isTrue);
      expect(isValidDscp('64'), isFalse);
    });

    test('country codes are exactly two letters', () {
      expect(isValidCountryCode('CN'), isTrue);
      expect(isValidCountryCode('cn'), isTrue);
      expect(isValidCountryCode('CHN'), isFalse);
      expect(isValidCountryCode('C1'), isFalse);
    });

    test('logic rules need balanced, wrapping parentheses', () {
      expect(isValidLogicRule('((DOMAIN,a.com),(NETWORK,UDP))'), isTrue);
      expect(isValidLogicRule('(DOMAIN,a.com'), isFalse);
      expect(isValidLogicRule('DOMAIN,a.com'), isFalse);
      expect(isValidLogicRule(')('), isFalse);
    });

    test('sub-rules are a logic expression or a provider name', () {
      expect(isValidSubRule('(NETWORK,tcp)'), isTrue);
      expect(isValidSubRule('my_provider'), isTrue);
      expect(isValidSubRule('(unbalanced'), isFalse);
    });

    test('process names accept Android package names', () {
      expect(isValidProcessName('com.android.chrome'), isTrue);
      expect(isValidProcessName('curl'), isTrue);
      expect(isValidProcessName('two words'), isFalse);
      expect(isValidProcessNameWildcard('*telegram*'), isTrue);
    });

    test('process paths accept unix, windows and package forms', () {
      expect(isValidProcessPath('/system/bin/ping'), isTrue);
      expect(isValidProcessPath(r'C:\app\x.exe'), isTrue);
      expect(isValidProcessPath('com.android.chrome'), isTrue);
      expect(isValidProcessPath('ping'), isFalse);
      expect(isValidProcessPathWildcard('/data/*/lib/*'), isTrue);
    });

    test('inbound types and users', () {
      expect(isValidInboundType('SOCKS/HTTP'), isTrue);
      expect(isValidInboundType('mixed'), isTrue);
      expect(isValidInboundType('carrier-pigeon'), isFalse);
      expect(isValidInboundUser('mihomo/alice.b'), isTrue);
      expect(isValidInboundUser('a//b'), isFalse);
    });

    test('a bad regex is rejected rather than thrown', () {
      expect(isValidRegex('.*telegram.*'), isTrue);
      expect(isValidRegex('([unclosed'), isFalse);
    });
  });
}
