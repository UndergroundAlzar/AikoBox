/// Validates converter output against the **real** sing-box binary.
///
/// Unit tests prove the port agrees with the TypeScript original. They cannot
/// prove that either implementation emits something the core will actually
/// load — the two defects this suite caught (`up_mbps` as a float, and the
/// `outbound` DNS rule item that sing-box 1.13 refuses outright) were both
/// invisible to structural assertions and both present in the desktop app.
///
/// Ported from `src/main/core/singbox/realConfig.test.ts` and extended to cover
/// every protocol the converter emits.
///
/// Skipped when `<repo>/extra/sidecar/sing-box*` is absent, so a checkout
/// without the sidecar still runs green.
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import '../tool/clash_yaml.dart';
import 'support.dart';

void main() {
  final File? core = _findCore();
  final Directory? fixtures = _findDir('src/main/core/singbox/fixtures');

  group(
    'real sing-box configuration gate',
    () {
      late Directory workDir;

      setUpAll(() {
        workDir = Directory.systemTemp.createTempSync('aikobox-singbox-check-');
      });

      tearDownAll(() {
        if (workDir.existsSync()) workDir.deleteSync(recursive: true);
      });

      void expectAccepted(String name, ConvertResult result) {
        expect(result.errors, isEmpty, reason: 'conversion refused $name');
        final File configFile = File(
          '${workDir.path}${Platform.pathSeparator}$name.json',
        )..writeAsStringSync(
            const JsonEncoder.withIndent('  ').convert(result.config),
          );
        final ProcessResult run = Process.runSync(
          core!.path,
          <String>[
            'check',
            '-D',
            workDir.path,
            '-c',
            configFile.path,
            '--disable-color',
          ],
        );
        expect(
          run.exitCode,
          0,
          reason: 'sing-box rejected $name:\n${run.stdout}${run.stderr}',
        );
      }

      test('keeps the pinned sidecar available for schema verification', () {
        expect(core!.existsSync(), isTrue);
      });

      test('converts the realistic airport fixture on every platform', () {
        final String source = File(
          '${fixtures!.path}${Platform.pathSeparator}'
          'airport-inline-mainstream.yaml',
        ).readAsStringSync();
        for (final String platform in <String>['win32', 'android', '']) {
          final ConvertResult result = convertClashToSingbox(
            parseClashYamlLikeDesktop(source),
            options: ConvertOptions(
              platform: platform,
              controllerSecret: 'fixture-controller-secret',
            ),
          );
          expectAccepted(
            'airport-${platform.isEmpty ? 'unspecified' : platform}',
            result,
          );
        }
      });

      test('emits valid source ACL rules for LAN proxy access', () {
        final ConvertResult result = convertClashToSingbox(
          <String, dynamic>{
            'mixed-port': 17890,
            'allow-lan': true,
            'authentication': <String>['user:password'],
            'lan-allowed-ips': <String>['192.168.50.0/24'],
            'lan-disallowed-ips': <String>['192.168.50.100/32'],
            'proxies': <Object?>[
              <String, dynamic>{
                'name': 'local',
                'type': 'socks5',
                'server': '127.0.0.1',
                'port': 1080,
              },
            ],
            'proxy-groups': <Object?>[
              <String, dynamic>{
                'name': 'PROXY',
                'type': 'select',
                'proxies': <String>['local'],
              },
            ],
            'rules': <String>['MATCH,PROXY'],
          },
          options: const ConvertOptions(
            platform: 'win32',
            controllerSecret: 'fixture-controller-secret',
          ),
        );
        expectAccepted('lan-acl', result);
      });

      test('emits a valid rule set for a fake-ip profile full of '
          'destination-ip rules', () {
        final ConvertResult result = convertClashToSingbox(
          <String, dynamic>{
            'mixed-port': 17890,
            'dns': <String, dynamic>{
              'enable': true,
              'enhanced-mode': 'fake-ip',
              'fake-ip-range': '198.18.0.1/16',
              'nameserver': <String>['https://doh.pub/dns-query'],
            },
            'proxies': <Object?>[
              <String, dynamic>{
                'name': 'node',
                'type': 'ss',
                'server': '192.0.2.20',
                'port': 443,
                'cipher': 'aes-128-gcm',
                'password': 'x',
              },
            ],
            'proxy-groups': <Object?>[
              <String, dynamic>{
                'name': 'PROXY',
                'type': 'select',
                'proxies': <String>['node'],
              },
            ],
            'rules': <String>[
              'IP-CIDR,1.2.3.4/32,DIRECT,no-resolve',
              'IP-CIDR6,2620:0:2d0::/48,DIRECT',
              'GEOIP,LAN,DIRECT',
              'GEOIP,CN,DIRECT',
              'GEOSITE,cn,DIRECT',
              'AND,((GEOIP,CN),(NETWORK,udp)),DIRECT',
              'MATCH,PROXY',
            ],
          },
          options: const ConvertOptions(
            platform: 'win32',
            controllerSecret: 'fixture-controller-secret',
          ),
        );
        // A routing-time resolve action would make any DNS failure drop the
        // connection.
        expect(
          routeRules(result.config).any((Dict r) => r['action'] == 'resolve'),
          isFalse,
        );
        expectAccepted('ip-rules', result);
      });

      test('emits a valid ShadowTLS v3 outbound', () {
        final ConvertResult result = convertClashToSingbox(<String, dynamic>{
          'mixed-port': 17890,
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'ShadowTLS',
              'type': 'shadowtls',
              'server': '192.0.2.10',
              'port': 443,
              'version': 3,
              'password': 'secret',
              'servername': 'www.example.com',
              'tls': true,
            },
          ],
          'proxy-groups': <Object?>[
            <String, dynamic>{
              'name': 'PROXY',
              'type': 'select',
              'proxies': <String>['ShadowTLS'],
            },
          ],
          'rules': <String>['MATCH,PROXY'],
        });
        expectAccepted('shadowtls', result);
      });

      test('emits a loadable outbound for every supported protocol', () {
        final ConvertResult result = convertClashToSingbox(
          _everyProtocolProfile(),
          options: const ConvertOptions(
            platform: 'android',
            controllerSecret: 'fixture-controller-secret',
          ),
        );
        expect(result.errors, isEmpty);
        // every node made it through
        final List<String> tags = <String>[
          ...outboundsOf(result.config).map((Dict o) => o['tag'] as String),
          ...endpointsOf(result.config).map((Dict o) => o['tag'] as String),
        ];
        for (final String expected in <String>[
          'ss',
          'ss-obfs',
          'ss-v2ray',
          'vmess-ws',
          'vmess-h2',
          'vmess-grpc',
          'vless-reality',
          'trojan',
          'hysteria',
          'hysteria2',
          'tuic',
          'wireguard',
          'http',
          'socks',
          'anytls',
          'ssh',
          'shadowtls',
          'plain-direct',
        ]) {
          expect(tags, contains(expected));
        }
        expectAccepted('every-protocol', result);
      });

      test('fractional hysteria bandwidth stays loadable', () {
        // `up_mbps` is a Go int. The desktop converter emits 12.5 verbatim and
        // the core refuses the entire config.
        final ConvertResult result = convertClashToSingbox(<String, dynamic>{
          'mixed-port': 17890,
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'hy2',
              'type': 'hysteria2',
              'server': 'hy2.example',
              'port': 443,
              'password': 'pw',
              'up': 12.5,
              'down': '55.5 Mbps',
              'sni': 'hy2.example',
            },
            <String, dynamic>{
              'name': 'hy1',
              'type': 'hysteria',
              'server': 'hy.example',
              'port': 443,
              'auth-str': 'pw',
              'up': 12.5,
              'down': '55.5 Mbps',
              'sni': 'hy.example',
            },
          ],
          'proxy-groups': <Object?>[
            <String, dynamic>{
              'name': 'PROXY',
              'type': 'select',
              'proxies': <String>['hy2', 'hy1'],
            },
          ],
          'rules': <String>['MATCH,PROXY'],
        });
        expect(outbound(result.config, 'hy2')['up_mbps'], isA<int>());
        expect(outbound(result.config, 'hy2')['down_mbps'], isA<int>());
        expect(outbound(result.config, 'hy1')['up'], '13 Mbps');
        expect(outbound(result.config, 'hy1')['down'], '56 Mbps');
        expectAccepted('fractional-bandwidth', result);
      });

      test('direct-nameserver stays loadable on sing-box 1.13', () {
        // The desktop converter models `direct-nameserver` as a DNS rule with
        // an `outbound: ["direct"]` matcher, which 1.12 deprecated and 1.13
        // refuses outright.
        final ConvertResult result = convertClashToSingbox(<String, dynamic>{
          'mixed-port': 17890,
          'dns': <String, dynamic>{
            'enable': true,
            'nameserver': <String>['https://doh.pub/dns-query'],
            'default-nameserver': <String>['1.1.1.1'],
            'proxy-server-nameserver': <String>['9.9.9.9'],
            'direct-nameserver': <String>['223.5.5.5'],
          },
          'hosts': <String, dynamic>{'router.lan': '192.168.1.1'},
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'node',
              'type': 'socks5',
              'server': '127.0.0.1',
              'port': 1080,
            },
          ],
          'rules': <String>['MATCH,node'],
        });
        expect(
          outbound(result.config, 'direct')['domain_resolver'],
          'dns-direct-0',
        );
        expect(
          dnsRules(result.config).any((Dict r) => r.containsKey('outbound')),
          isFalse,
          reason: 'the deprecated outbound DNS rule item must not be emitted',
        );
        expectAccepted('direct-nameserver', result);
      });

      test('the DNS kitchen sink stays loadable', () {
        final ConvertResult result = convertClashToSingbox(<String, dynamic>{
          'mixed-port': 17890,
          'ipv6': true,
          'hosts': <String, dynamic>{
            'router.lan': '192.168.1.1',
            'nas.lan': <String>['192.168.1.2', 'fd00::2'],
          },
          'dns': <String, dynamic>{
            'enable': true,
            'enhanced-mode': 'fake-ip',
            'fake-ip-range': '198.18.0.1/16',
            'fake-ip-filter': <String>['+.lan', '*.local', 'time.*.com'],
            'default-nameserver': <String>['1.1.1.1'],
            'proxy-server-nameserver': <String>['https://9.9.9.9/dns-query'],
            'direct-nameserver': <String>['223.5.5.5'],
            'nameserver': <String>[
              'https://doh.pub/dns-query',
              'tls://dns.google:853',
              'quic://dns.adguard.com',
              'h3://cloudflare-dns.com/dns-query',
              'udp://[2001:4860:4860::8888]:53',
              'system',
            ],
            'nameserver-policy': <String, dynamic>{
              '+.internal': 'udp://10.0.0.53',
            },
          },
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'node',
              'type': 'socks5',
              'server': '127.0.0.1',
              'port': 1080,
            },
          ],
          'rules': <String>['MATCH,node'],
        });
        expectAccepted('dns-kitchen-sink', result);
      });

      test('a tun profile stays loadable', () {
        // `auto-redirect` is deliberately absent: it needs nftables, so the
        // Windows sidecar fails to initialise the inbound even though the JSON
        // is correct. Its emission is covered structurally in android_test.dart.
        final ConvertResult result = convertClashToSingbox(
          <String, dynamic>{
            'mixed-port': 17890,
            'ipv6': true,
            'tun': <String, dynamic>{
              'enable': true,
              'stack': 'mixed',
              'device': 'aiko0',
              'mtu': 9000,
              'auto-route': true,
              'strict-route': true,
              'endpoint-independent-nat': true,
              'route-exclude-address': <String>['192.168.0.0/16'],
            },
            'sniffer': <String, dynamic>{'enable': true},
            'proxies': <Object?>[
              <String, dynamic>{
                'name': 'node',
                'type': 'socks5',
                'server': '127.0.0.1',
                'port': 1080,
              },
            ],
            'rules': <String>['MATCH,node'],
          },
          options: const ConvertOptions(platform: 'android'),
        );
        expectAccepted('tun', result);
      });
    },
    skip: core == null || fixtures == null
        ? 'sing-box sidecar not found under <repo>/extra/sidecar'
        : null,
  );
}

/// One node of every protocol the converter supports, with realistic values so
/// the core's own validators (cipher names, key lengths, versions) actually run.
Map<String, dynamic> _everyProtocolProfile() {
  return <String, dynamic>{
    'mixed-port': 17890,
    'ipv6': true,
    'proxies': <Object?>[
      <String, dynamic>{
        'name': 'ss',
        'type': 'ss',
        'server': '192.0.2.1',
        'port': 443,
        'cipher': '2022-blake3-aes-128-gcm',
        'password': 'MTIzNDU2Nzg5MDEyMzQ1Ng==',
      },
      <String, dynamic>{
        'name': 'ss-obfs',
        'type': 'ss',
        'server': '192.0.2.2',
        'port': 443,
        'cipher': 'aes-256-gcm',
        'password': 'pw',
        'plugin': 'obfs',
        'plugin-opts': <String, dynamic>{'mode': 'http', 'host': 'bing.com'},
      },
      <String, dynamic>{
        'name': 'ss-v2ray',
        'type': 'ss',
        'server': '192.0.2.3',
        'port': 443,
        'cipher': 'chacha20-ietf-poly1305',
        'password': 'pw',
        'plugin': 'v2ray-plugin',
        'plugin-opts': <String, dynamic>{
          'mode': 'websocket',
          'tls': true,
          'host': 'a.example',
          'path': '/ws',
        },
      },
      <String, dynamic>{
        'name': 'vmess-ws',
        'type': 'vmess',
        'server': '192.0.2.4',
        'port': 443,
        'uuid': 'b831381d-6324-4d53-ad4f-8cda48b30811',
        'alterId': 0,
        'cipher': 'auto',
        'tls': true,
        'servername': 'a.example',
        'network': 'ws',
        'packet-encoding': 'packetaddr',
        'tfo': true,
        'mptcp': true,
        'ip-version': 'prefer-ipv4',
        'ws-opts': <String, dynamic>{
          'path': '/p',
          'headers': <String, dynamic>{'Host': 'a.example'},
          'max-early-data': 2048,
          'early-data-header-name': 'Sec-WebSocket-Protocol',
        },
      },
      <String, dynamic>{
        'name': 'vmess-h2',
        'type': 'vmess',
        'server': '192.0.2.5',
        'port': 443,
        'uuid': 'b831381d-6324-4d53-ad4f-8cda48b30811',
        'network': 'h2',
        'servername': 'h2.example',
        'h2-opts': <String, dynamic>{
          'host': <String>['h2.example'],
          'path': '/h2',
        },
      },
      <String, dynamic>{
        'name': 'vmess-grpc',
        'type': 'vmess',
        'server': '192.0.2.6',
        'port': 443,
        'uuid': 'b831381d-6324-4d53-ad4f-8cda48b30811',
        'tls': true,
        'servername': 'g.example',
        'network': 'grpc',
        'grpc-opts': <String, dynamic>{'grpc-service-name': 'svc'},
      },
      <String, dynamic>{
        'name': 'vless-reality',
        'type': 'vless',
        'server': '192.0.2.7',
        'port': 443,
        'uuid': 'b831381d-6324-4d53-ad4f-8cda48b30811',
        'flow': 'xtls-rprx-vision',
        'client-fingerprint': 'chrome',
        'servername': 'www.example.com',
        'reality-opts': <String, dynamic>{
          'public-key': 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI-T4E7RoLJS0',
          'short-id': '0123456789abcdef',
        },
      },
      <String, dynamic>{
        'name': 'trojan',
        'type': 'trojan',
        'server': '192.0.2.8',
        'port': 443,
        'password': 'pw',
        'sni': 't.example',
        'skip-cert-verify': true,
        'alpn': <String>['h2', 'http/1.1'],
        'network': 'ws',
        'ws-opts': <String, dynamic>{'path': '/tj'},
      },
      <String, dynamic>{
        'name': 'hysteria',
        'type': 'hysteria',
        'server': '192.0.2.9',
        'ports': '20000-30000',
        'hop-interval': 20,
        'up': '100 Mbps',
        'down': '500 Mbps',
        'auth-str': 'secret',
        'sni': 'h.example',
      },
      <String, dynamic>{
        'name': 'hysteria2',
        'type': 'hysteria2',
        'server': '192.0.2.10',
        'ports': <String>['40000-40100'],
        'hop-interval': 15,
        'up': '1 Gbps',
        'down': '2 GBps',
        'password': 'pw',
        'obfs': 'salamander',
        'obfs-password': 'ob',
        'sni': 'h2.example',
      },
      <String, dynamic>{
        'name': 'tuic',
        'type': 'tuic',
        'server': '192.0.2.11',
        'port': 443,
        'uuid': 'b831381d-6324-4d53-ad4f-8cda48b30811',
        'password': 'pw',
        'congestion-controller': 'bbr',
        'udp-relay-mode': 'native',
        'reduce-rtt': true,
        'heartbeat-interval': 3000,
        'sni': 'tu.example',
      },
      <String, dynamic>{
        'name': 'wireguard',
        'type': 'wireguard',
        'server': '192.0.2.12',
        'port': 51820,
        'ip': '172.16.0.2',
        'ipv6': 'fd00::2',
        'private-key': 'CJ9L1v3AaLPqPHFWvJ7oJUwyRnnaGpbYcvfMBBTPXFo=',
        'public-key': 'jNXHt1yRo0vDuchQlIP6Z0ZvjT3KtzVI+T4E7RoLJS0=',
        'mtu': 1408,
        'reserved': <int>[1, 2, 3],
      },
      <String, dynamic>{
        'name': 'http',
        'type': 'http',
        'server': '192.0.2.13',
        'port': 8080,
        'username': 'u',
        'password': 'p',
        'tls': true,
        'sni': 'p.example',
      },
      <String, dynamic>{
        'name': 'socks',
        'type': 'socks5',
        'server': '192.0.2.14',
        'port': 1080,
        'username': 'u',
        'password': 'p',
      },
      <String, dynamic>{
        'name': 'anytls',
        'type': 'anytls',
        'server': '192.0.2.15',
        'port': 443,
        'password': 'pw',
        'sni': 'at.example',
        'idle-session-check-interval': '20s',
        'idle-session-timeout': '40s',
        'min-idle-session': 2,
      },
      <String, dynamic>{
        'name': 'ssh',
        'type': 'ssh',
        'server': '192.0.2.16',
        'port': 22,
        'username': 'alice',
        'password': 'secret',
        'host-key-algorithms': <String>['ssh-ed25519'],
        'client-version': 'SSH-2.0-AikoBox',
      },
      <String, dynamic>{
        'name': 'shadowtls',
        'type': 'shadowtls',
        'server': '192.0.2.17',
        'port': 443,
        'version': 3,
        'password': 'secret',
        'servername': 'www.example.com',
      },
      <String, dynamic>{'name': 'plain-direct', 'type': 'direct'},
    ],
    'proxy-groups': <Object?>[
      <String, dynamic>{
        'name': 'PROXY',
        'type': 'select',
        'include-all': true,
      },
      <String, dynamic>{
        'name': 'Auto',
        'type': 'url-test',
        'include-all': true,
        'filter': '(?i)ss|vmess',
        'url': 'http://cp.cloudflare.com/generate_204',
        'interval': 300,
        'tolerance': 20,
      },
    ],
    'rules': <String>[
      'DOMAIN-SUFFIX,example.com,Auto',
      'GEOIP,CN,DIRECT',
      'MATCH,PROXY',
    ],
  };
}

File? _findCore() {
  final String name =
      Platform.isWindows ? 'sing-box.exe' : 'sing-box';
  Directory? dir = Directory.current.absolute;
  for (int depth = 0; depth < 8 && dir != null; depth++) {
    final File candidate = File(
      <String>[dir.path, 'extra', 'sidecar', name].join(Platform.pathSeparator),
    );
    if (candidate.existsSync()) return candidate;
    final Directory parent = dir.parent;
    dir = parent.path == dir.path ? null : parent;
  }
  return null;
}

Directory? _findDir(String relative) {
  final List<String> parts = relative.split('/');
  Directory? dir = Directory.current.absolute;
  for (int depth = 0; depth < 8 && dir != null; depth++) {
    final Directory candidate = Directory(
      <String>[dir.path, ...parts].join(Platform.pathSeparator),
    );
    if (candidate.existsSync()) return candidate;
    final Directory parent = dir.parent;
    dir = parent.path == dir.path ? null : parent;
  }
  return null;
}
