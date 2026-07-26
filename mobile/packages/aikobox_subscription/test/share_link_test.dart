/// Per-scheme coverage for `parseShareLink`.
///
/// The corpus suite proves the eight representative links round-trip; this one
/// covers the field-level rules underneath them — the ones a hand-edited or
/// hostile link exercises.
library;

import 'dart:convert';

import 'package:aikobox_subscription/aikobox_subscription.dart';
import 'package:test/test.dart';

String b64(String value) =>
    base64.encode(utf8.encode(value)).replaceAll(RegExp(r'=+$'), '');

Matcher throwsFormat(String fragment) => throwsA(
  isA<SubscriptionFormatException>().having(
    (error) => error.message,
    'message',
    contains(fragment),
  ),
);

void main() {
  group('parseShareLink contract', () {
    test(
      'returns null rather than throwing for a scheme we cannot convert',
      () {
        // Null is the caller's cue to skip; throwing here would make it
        // impossible to feed mixed clipboard content through this function.
        expect(parseShareLink('ssr://whatever'), isNull);
        expect(parseShareLink('https://example.com/sub'), isNull);
        expect(parseShareLink('not a uri at all'), isNull);
        expect(parseShareLink(''), isNull);
      },
    );

    test(
      'still throws when the scheme is supported but the link is broken',
      () {
        expect(
          () => parseShareLink('trojan://secret@example.com:0#Zero'),
          throwsFormat('invalid server port'),
        );
      },
    );

    test('tolerates surrounding whitespace', () {
      final proxy = parseShareLink(
        '  trojan://secret@example.com:443#Padded \n',
      );
      expect(proxy!['name'], 'Padded');
      expect(proxy['server'], 'example.com');
    });

    test('names an unnamed node after its scheme and position', () {
      expect(
        parseShareLink('trojan://secret@example.com:443')!['name'],
        'TROJAN-1',
      );
      expect(parseShareLink('socks5://example.com:1080#')!['name'], 'SOCKS5-1');
    });

    test('every advertised scheme is actually parseable', () {
      // Guards against the set and the switch drifting apart.
      const samples = <String, String>{
        'ss': 'ss://YWVzLTEyOC1nY206c2VjcmV0@a.example:8388',
        'vmess': 'vmess://eyJhZGQiOiJhLmV4YW1wbGUiLCJwb3J0Ijo0NDMsImlkIjoidSJ9',
        'vless': 'vless://uuid@a.example:443',
        'trojan': 'trojan://secret@a.example:443',
        'hysteria': 'hysteria://a.example:443?auth=secret',
        'hy': 'hy://a.example:443?auth=secret',
        'hysteria2': 'hysteria2://secret@a.example:443',
        'hy2': 'hy2://secret@a.example:443',
        'tuic': 'tuic://uuid:secret@a.example:443',
        'anytls': 'anytls://secret@a.example:443',
        'shadowtls': 'shadowtls://secret@a.example:443',
        'http': 'http://a.example:8080',
        'socks': 'socks://a.example:1080',
        'socks5': 'socks5://a.example:1080',
      };
      expect(samples.keys.toSet(), kSupportedShareLinkSchemes);
      for (final entry in samples.entries) {
        expect(
          parseShareLink(entry.value),
          isA<Map<String, dynamic>>(),
          reason: 'scheme ${entry.key}',
        );
      }
    });
  });

  group('shadowsocks', () {
    test('accepts the legacy fully-Base64 authority form', () {
      final proxy = parseShareLink(
        'ss://${b64('aes-128-gcm:secret@ss.example:8388')}#Legacy',
      )!;
      expect(proxy, <String, dynamic>{
        'name': 'Legacy',
        'type': 'ss',
        'server': 'ss.example',
        'port': 8388,
        'cipher': 'aes-128-gcm',
        'password': 'secret',
        'udp': true,
      });
    });

    test('accepts percent-encoded credentials', () {
      final proxy = parseShareLink(
        'ss://aes-128-gcm:p%40ss%3Aword@ss.example:8388#Pct',
      )!;
      expect(proxy['cipher'], 'aes-128-gcm');
      expect(proxy['password'], r'p@ss:word');
    });

    test('keeps a password containing an @ by splitting on the last one', () {
      final proxy = parseShareLink(
        'ss://${b64('aes-128-gcm:se@cret')}@ss.example:8388#At',
      )!;
      expect(proxy['password'], 'se@cret');
      expect(proxy['server'], 'ss.example');
    });

    test('translates the obfs plugin into Clash plugin-opts', () {
      final proxy = parseShareLink(
        'ss://${b64('aes-128-gcm:secret')}@ss.example:8388'
        '?plugin=obfs-local%3Bobfs%3Dhttp%3Bobfs-host%3Dcdn.example#Obfs',
      )!;
      expect(proxy['plugin'], 'obfs');
      expect(proxy['plugin-opts'], <String, dynamic>{
        'mode': 'http',
        'obfs-host': 'cdn.example',
      });
    });

    test('reads a bare plugin flag as true', () {
      final proxy = parseShareLink(
        'ss://${b64('aes-128-gcm:secret')}@ss.example:8388'
        '?plugin=v2ray-plugin%3Btls%3Bmode%3Dwebsocket#V2ray',
      )!;
      expect(proxy['plugin'], 'v2ray-plugin');
      expect(proxy['plugin-opts'], <String, dynamic>{
        'tls': true,
        'mode': 'websocket',
      });
    });

    test('refuses credentials with no cipher/password separator', () {
      expect(
        () => parseShareLink('ss://${b64('justapassword')}@ss.example:8388'),
        throwsFormat('invalid Shadowsocks credentials'),
      );
    });

    test('refuses an endpoint with no host', () {
      expect(
        () => parseShareLink('ss://${b64('aes-128-gcm:secret')}@:8388'),
        throwsFormat('Invalid URL'),
      );
    });
  });

  group('vmess', () {
    test('reads alterId, cipher and the h2 transport out of the payload', () {
      final proxy = parseShareLink(
        'vmess://${b64(jsonEncode(<String, dynamic>{'add': 'vmess.example', 'port': '443', 'id': 'the-uuid', 'aid': '4', 'scy': 'zero', 'net': 'h2', 'host': 'cdn.example', 'path': '/h2', 'tls': 'tls'}))}#H2',
      )!;
      expect(proxy['alterId'], 4);
      expect(proxy['cipher'], 'zero');
      expect(proxy['network'], 'h2');
      expect(proxy['h2-opts'], <String, dynamic>{
        'path': '/h2',
        'host': <String>['cdn.example'],
      });
      expect(proxy['tls'], isTrue);
    });

    test('refuses a payload with no server or no id', () {
      expect(
        () => parseShareLink('vmess://${b64('{"port":443,"id":"u"}')}'),
        throwsFormat('missing server or UUID'),
      );
      expect(
        () =>
            parseShareLink('vmess://${b64('{"add":"a.example","port":443}')}'),
        throwsFormat('missing server or UUID'),
      );
    });

    test('refuses an unsupported transport rather than dropping it', () {
      // Silently downgrading kcp to tcp would produce a node that cannot
      // connect and no explanation of why.
      expect(
        () => parseShareLink(
          'vmess://${b64('{"add":"a.example","port":443,"id":"u","net":"kcp"}')}',
        ),
        throwsFormat('transport "kcp" is not supported'),
      );
    });

    test('maps net:none to plain tcp', () {
      final proxy = parseShareLink(
        'vmess://${b64('{"add":"a.example","port":443,"id":"u","net":"none"}')}',
      )!;
      expect(proxy.containsKey('network'), isFalse);
    });
  });

  group('vless', () {
    test('refuses a Reality link with no public key', () {
      expect(
        () => parseShareLink(
          'vless://uuid@a.example:443?security=reality&sni=www.example.com',
        ),
        throwsFormat('missing its public key'),
      );
    });

    test('refuses a link with no UUID', () {
      expect(
        () => parseShareLink('vless://a.example:443'),
        throwsFormat('VLESS URI is missing a UUID'),
      );
    });

    test('carries flow and both packet-encoding spellings', () {
      expect(
        parseShareLink(
          'vless://uuid@a.example:443?flow=xtls-rprx-vision&packetEncoding=packetaddr',
        )!,
        containsPair('flow', 'xtls-rprx-vision'),
      );
      expect(
        parseShareLink('vless://uuid@a.example:443?packet-encoding=xudp')!,
        containsPair('packet-encoding', 'xudp'),
      );
    });
  });

  group('tls and transport options', () {
    test('splits alpn and normalises skip-cert-verify', () {
      final proxy = parseShareLink(
        'trojan://secret@a.example:443?alpn=h2%2Chttp%2F1.1&allowInsecure=1',
      )!;
      expect(proxy['alpn'], <String>['h2', 'http/1.1']);
      expect(proxy['skip-cert-verify'], isTrue);
    });

    test('accepts the insecure alias and the false spellings', () {
      expect(
        parseShareLink('trojan://secret@a.example:443?insecure=no')!,
        containsPair('skip-cert-verify', false),
      );
      expect(
        parseShareLink('trojan://secret@a.example:443?allowInsecure=false')!,
        containsPair('skip-cert-verify', false),
      );
    });

    test('refuses a boolean it cannot read', () {
      expect(
        () =>
            parseShareLink('trojan://secret@a.example:443?allowInsecure=maybe'),
        throwsFormat('invalid boolean value "maybe"'),
      );
    });

    test('defaults a ws path and omits empty headers', () {
      final proxy = parseShareLink('trojan://secret@a.example:443?type=ws')!;
      expect(proxy['ws-opts'], <String, dynamic>{'path': '/'});
    });

    test('accepts both grpc service-name spellings', () {
      expect(
        parseShareLink(
          'vless://u@a.example:443?type=grpc&service-name=svc',
        )!['grpc-opts'],
        <String, dynamic>{'grpc-service-name': 'svc'},
      );
    });

    test('wraps the http transport path in a list', () {
      final proxy = parseShareLink(
        'vless://u@a.example:443?type=http&path=/api&host=cdn.example',
      )!;
      expect(proxy['http-opts'], <String, dynamic>{
        'path': <String>['/api'],
        'host': <String>['cdn.example'],
      });
    });
  });

  group('hosts and ports', () {
    test('unwraps a bracketed IPv6 literal', () {
      final proxy = parseShareLink('trojan://secret@[2001:db8::1]:443#V6')!;
      expect(proxy['server'], '2001:db8::1');
      expect(proxy['port'], 443);
    });

    test('accepts the first and last legal port', () {
      expect(parseShareLink('trojan://s@a.example:1')!['port'], 1);
      expect(parseShareLink('trojan://s@a.example:65535')!['port'], 65535);
    });

    test('refuses a missing, zero, oversized or non-numeric port', () {
      expect(
        () => parseShareLink('trojan://s@a.example'),
        throwsFormat('invalid server port'),
      );
      expect(
        () => parseShareLink('trojan://s@a.example:0'),
        throwsFormat('invalid server port'),
      );
      expect(
        () => parseShareLink('trojan://s@a.example:65536'),
        throwsFormat('Invalid URL'),
      );
      expect(
        () => parseShareLink('trojan://s@a.example:https'),
        throwsFormat('Invalid URL'),
      );
    });

    test('refuses a link with no host', () {
      expect(
        () => parseShareLink('trojan://secret@:443'),
        throwsFormat('trojan URI is missing a server'),
      );
    });

    test('keeps a node listening on a default port', () {
      // Node's URL normalisation erases ":80" on an http link, which makes the
      // desktop reject it as a missing port. Keeping it is a deliberate fix.
      expect(parseShareLink('http://user:pass@a.example:80#Cdn')!['port'], 80);
      expect(
        parseShareLink('ss://YWVzLTEyOC1nY206cw==@a.example:80')!['port'],
        80,
      );
    });

    test('lower-cases the host so the same node is one node', () {
      expect(
        parseShareLink('trojan://s@A.Example:443')!['server'],
        'a.example',
      );
    });
  });

  group('shadowtls', () {
    test('defaults to version 3', () {
      expect(parseShareLink('shadowtls://secret@a.example:443')!['version'], 3);
    });

    test('allows version 1 with no password', () {
      final proxy = parseShareLink('shadowtls://a.example:443?version=1')!;
      expect(proxy['version'], 1);
      expect(proxy['password'], '');
    });

    test('refuses version 2 or 3 with no password', () {
      expect(
        () => parseShareLink('shadowtls://a.example:443?version=2'),
        throwsFormat('ShadowTLS URI is missing a password'),
      );
    });

    test('refuses an unknown version', () {
      expect(
        () => parseShareLink('shadowtls://secret@a.example:443?version=9'),
        throwsFormat('invalid version'),
      );
      expect(
        () => parseShareLink('shadowtls://secret@a.example:443?version=three'),
        throwsFormat('invalid version'),
      );
    });
  });

  group('remaining schemes', () {
    test('hysteria falls back through auth, auth_str and userinfo', () {
      expect(
        parseShareLink('hysteria://a.example:443?auth_str=secret')!['auth-str'],
        'secret',
      );
      expect(
        parseShareLink('hysteria://secret@a.example:443')!['auth-str'],
        'secret',
      );
      final full = parseShareLink(
        'hysteria://a.example:443?auth=s&up=10&down=50&obfs=xplus',
      )!;
      expect(full['up'], '10');
      expect(full['down'], '50');
      expect(full['obfs'], 'xplus');
      expect(full['tls'], isTrue);
    });

    test('hysteria2 reads auth from the query and carries port hopping', () {
      final proxy = parseShareLink(
        'hy2://a.example:443?auth=secret&mport=443-500&obfs=salamander'
        '&obfs-password=cover',
      )!;
      expect(proxy['type'], 'hysteria2');
      expect(proxy['password'], 'secret');
      expect(proxy['ports'], '443-500');
      expect(proxy['obfs'], 'salamander');
      expect(proxy['obfs-password'], 'cover');
    });

    test('hysteria2 refuses a link with no password anywhere', () {
      expect(
        () => parseShareLink('hy2://a.example:443'),
        throwsFormat('Hysteria2 URI is missing a password'),
      );
    });

    test('tuic needs both a uuid and a password', () {
      expect(
        () => parseShareLink('tuic://onlyuuid@a.example:443'),
        throwsFormat('TUIC URI is missing a UUID or password'),
      );
    });

    test('trojan and anytls need a password', () {
      expect(
        () => parseShareLink('trojan://a.example:443'),
        throwsFormat('Trojan URI is missing a password'),
      );
      expect(
        () => parseShareLink('anytls://a.example:443'),
        throwsFormat('AnyTLS URI is missing a password'),
      );
    });

    test('http and socks5 carry credentials but only http gets tls', () {
      final http = parseShareLink(
        'http://user:pass@a.example:8080?security=tls',
      )!;
      expect(http['username'], 'user');
      expect(http['password'], 'pass');
      expect(http['tls'], isTrue);

      final socks = parseShareLink('socks://user:pass@a.example:1080')!;
      expect(socks['type'], 'socks5');
      expect(socks['username'], 'user');
      expect(socks.containsKey('tls'), isFalse);
    });
  });
}
