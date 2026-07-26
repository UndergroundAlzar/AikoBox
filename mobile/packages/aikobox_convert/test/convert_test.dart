/// Port of `src/main/core/singbox/convert.test.ts`.
///
/// Every `describe`/`it` from the desktop suite is reproduced here, in the same
/// order, with the same assertions. When the two implementations disagree, this
/// file is the referee.
library;

import 'package:test/test.dart';

import 'support.dart';

void main() {
  group('empty profile', () {
    test('produces a valid startable config', () {
      final ConvertResult result =
          convertClashToSingbox(<String, dynamic>{}, options: kNoPlatform);
      final Dict config = result.config;
      expect(config['outbounds'], isA<List<Object?>>());
      // direct + GLOBAL always exist
      expect(outbound(config, 'direct')['type'], 'direct');
      expect(outbound(config, 'GLOBAL')['type'], 'selector');
      expect(strings(outbound(config, 'GLOBAL')['outbounds']), isNotEmpty);
      // dns always has a local server so proxies-by-domain can resolve
      expect(
        dnsServers(config).any((Dict s) => s['type'] == 'local'),
        isTrue,
      );
      // route final falls back to direct
      expect((config['route'] as Dict)['final'], 'direct');
      // controller defaults applied
      final Dict clashApi =
          (config['experimental'] as Dict)['clash_api'] as Dict;
      expect(clashApi['external_controller'], '127.0.0.1:9090');
      expect(result.warnings, isA<List<String>>());
      expect(result.errors, isEmpty);
    });
  });

  group('clash_api / cache_file', () {
    test('maps external-controller, secret, default mode and store_fakeip', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'mode': 'global',
          'profile': <String, dynamic>{'store-fake-ip': true},
        }),
        options: kNoPlatform,
      );
      final Dict experimental = result.config['experimental'] as Dict;
      final Dict clashApi = experimental['clash_api'] as Dict;
      expect(clashApi['external_controller'], '127.0.0.1:9097');
      expect(clashApi['secret'], 'test-secret');
      expect(clashApi['default_mode'], 'Global');
      final Dict cache = experimental['cache_file'] as Dict;
      expect(cache['enabled'], isTrue);
      expect(cache['store_fakeip'], isTrue);
      expect(result.controller.port, 9097);
      expect(result.controller.host, '127.0.0.1');
      expect(result.controller.secret, 'test-secret');
    });

    test('uses a generated controller secret when the profile has none', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{'secret': ''}),
        options: const ConvertOptions(
          platform: '',
          controllerSecret: 'generated-secret',
        ),
      );
      final Dict clashApi =
          (result.config['experimental'] as Dict)['clash_api'] as Dict;
      expect(result.controller.secret, 'generated-secret');
      expect(clashApi['secret'], 'generated-secret');
    });

    test('restricts wildcard controller addresses to loopback', () {
      final SingboxController controller = deriveController(<String, dynamic>{
        'external-controller': '0.0.0.0:9091',
        'secret': 's',
      });
      expect(controller.listen, '127.0.0.1:9091');
      expect(controller.host, '127.0.0.1');
    });

    test('warns when a public controller address is restricted', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{'external-controller': '0.0.0.0:9091'}),
        options: kNoPlatform,
      );
      expect(
        result.warnings,
        contains(
          'external-controller was restricted to 127.0.0.1 for desktop security',
        ),
      );
    });

    test('defaults when empty', () {
      final SingboxController controller =
          deriveController(<String, dynamic>{});
      expect(controller.listen, '127.0.0.1:9090');
      expect(controller.port, 9090);
    });
  });

  group('log level', () {
    test('maps warning -> warn and silent -> fatal', () {
      String levelFor(String level) {
        final ConvertResult result = convertClashToSingbox(
          base(<String, dynamic>{'log-level': level}),
          options: kNoPlatform,
        );
        return (result.config['log'] as Dict)['level'] as String;
      }

      expect(levelFor('warning'), 'warn');
      expect(levelFor('silent'), 'fatal');
      expect(levelFor('debug'), 'debug');
    });
  });

  group('inbounds', () {
    test('creates mixed/socks/http inbounds from ports', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'mixed-port': 7890,
          'socks-port': 7891,
          'port': 7892,
        }),
        options: kNoPlatform,
      ).config;
      final List<Dict> inbounds = inboundsOf(config);
      final Dict mixed =
          findWhere(inbounds, (Dict i) => i['type'] == 'mixed')!;
      expect(mixed['listen_port'], 7890);
      expect(mixed['listen'], '127.0.0.1');
      expect(findWhere(inbounds, (Dict i) => i['type'] == 'socks'), isNotNull);
      expect(findWhere(inbounds, (Dict i) => i['type'] == 'http'), isNotNull);
    });

    test('skips zero ports and honors allow-lan', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'mixed-port': 7890,
          'socks-port': 0,
          'allow-lan': true,
          'ipv6': false,
        }),
        options: kNoPlatform,
      ).config;
      final List<Dict> inbounds = inboundsOf(config);
      expect(findWhere(inbounds, (Dict i) => i['type'] == 'socks'), isNull);
      expect(
        findWhere(inbounds, (Dict i) => i['type'] == 'mixed')!['listen'],
        '0.0.0.0',
      );
    });

    test('maps authentication users onto listeners', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'authentication': <String>['user:pass'],
        }),
        options: kNoPlatform,
      ).config;
      final Dict mixed =
          findWhere(inboundsOf(config), (Dict i) => i['type'] == 'mixed')!;
      expect(
        mixed['users'],
        equals(<Dict>[
          <String, dynamic>{'username': 'user', 'password': 'pass'},
        ]),
      );
    });

    test('creates a tun inbound with mapped settings', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'tun': <String, dynamic>{
            'enable': true,
            'stack': 'mixed',
            'device': 'AikoBox',
            'mtu': 9000,
            'auto-route': true,
            'strict-route': true,
            'route-exclude-address': <String>['192.168.0.0/16'],
          },
        }),
        options: kNoPlatform,
      ).config;
      final Dict tun =
          findWhere(inboundsOf(config), (Dict i) => i['type'] == 'tun')!;
      expect(tun['interface_name'], 'AikoBox');
      expect(tun['stack'], 'mixed');
      expect(tun['mtu'], 9000);
      expect(tun['auto_route'], isTrue);
      expect(tun['strict_route'], isTrue);
      expect(
        strings(tun['route_exclude_address']),
        equals(<String>['192.168.0.0/16']),
      );
      expect(
        strings(tun['address']),
        equals(<String>['198.19.0.1/30', 'fdfe:dcba:9876::1/126']),
      );
      expect(strings(tun['address']), isNot(contains('172.19.0.1/30')));
    });

    test('honors modern and legacy TUN addresses without duplicates', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'tun': <String, dynamic>{
            'enable': true,
            'address': <String>['10.77.0.1/30', 'fd00:77::1/126'],
            'inet4-address': <String>['10.78.0.1/30', '10.77.0.1/30'],
            'inet6-address': 'fd00:78::1/126',
          },
        }),
        options: kNoPlatform,
      ).config;
      final Dict tun =
          findWhere(inboundsOf(config), (Dict i) => i['type'] == 'tun')!;
      expect(
        strings(tun['address']),
        equals(<String>[
          '10.77.0.1/30',
          'fd00:77::1/126',
          '10.78.0.1/30',
          'fd00:78::1/126',
        ]),
      );
    });

    test(
        'uses legacy family overrides and drops configured TUN IPv6 when '
        'top-level IPv6 is disabled', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'ipv6': false,
          'tun': <String, dynamic>{
            'enable': true,
            'inet4-address': '10.88.0.1/30',
            'inet6-address': 'fd00:88::1/126',
          },
        }),
        options: kNoPlatform,
      );
      final Dict tun = findWhere(
        inboundsOf(result.config),
        (Dict i) => i['type'] == 'tun',
      )!;
      expect(strings(tun['address']), equals(<String>['10.88.0.1/30']));
      expect(
        joined(result.warnings),
        matches(RegExp('TUN IPv6 address ignored', caseSensitive: false)),
      );
    });

    test('maps tun.auto-detect-interface to sing-box route settings', () {
      final Dict disabled = convertClashToSingbox(
        base(<String, dynamic>{
          'tun': <String, dynamic>{
            'enable': true,
            'auto-detect-interface': false,
          },
        }),
        options: kNoPlatform,
      ).config;
      final Dict enabled = convertClashToSingbox(
        base(<String, dynamic>{
          'tun': <String, dynamic>{
            'enable': true,
            'auto-detect-interface': true,
          },
        }),
        options: kNoPlatform,
      ).config;
      final Dict legacyTopLevel = convertClashToSingbox(
        base(<String, dynamic>{
          'auto-detect-interface': false,
          'tun': <String, dynamic>{'enable': true},
        }),
        options: kNoPlatform,
      ).config;

      expect((disabled['route'] as Dict)['auto_detect_interface'], isFalse);
      expect((enabled['route'] as Dict)['auto_detect_interface'], isTrue);
      expect(
        (legacyTopLevel['route'] as Dict)['auto_detect_interface'],
        isFalse,
      );
    });

    test('drops redir/tproxy ports on unsupported platforms with a warning',
        () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{'redir-port': 1234, 'tproxy-port': 1235}),
        options: const ConvertOptions(platform: 'win32'),
      );
      final List<Dict> inbounds = inboundsOf(result.config);
      expect(findWhere(inbounds, (Dict i) => i['type'] == 'redirect'), isNull);
      expect(findWhere(inbounds, (Dict i) => i['type'] == 'tproxy'), isNull);
      expect(joined(result.warnings), matches(RegExp('redir-port')));
    });
  });

  group('dns', () {
    test('fake-ip mode creates a fakeip server, filter rules and query_type '
        'rule', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'dns': <String, dynamic>{
            'enable': true,
            'ipv6': false,
            'enhanced-mode': 'fake-ip',
            'fake-ip-range': '198.18.0.1/16',
            'fake-ip-filter': <String>['+.lan', 'time.windows.com'],
            'nameserver': <String>[
              'https://doh.pub/dns-query',
              'tls://223.5.5.5',
            ],
          },
        }),
        options: kNoPlatform,
      ).config;
      final Dict dns = config['dns'] as Dict;
      final List<Dict> servers = dnsServers(config);
      final Dict fakeip = findWhere(servers, (Dict s) => s['type'] == 'fakeip')!;
      expect(fakeip['inet4_range'], '198.18.0.1/16');
      expectSubset(
        findWhere(servers, (Dict s) => s['type'] == 'https'),
        <String, dynamic>{'server': 'doh.pub'},
      );
      expectSubset(
        findWhere(servers, (Dict s) => s['type'] == 'tls'),
        <String, dynamic>{'server': '223.5.5.5'},
      );
      final List<Dict> rules = dnsRules(config);
      // the filter rule resolves real IPs before the fakeip catch-all
      final Dict filterRule = findWhere(
        rules,
        (Dict r) => strings(r['domain_suffix']).contains('.lan'),
      )!;
      expect(filterRule['server'], isNot('dns-fakeip'));
      final Dict last = rules.last;
      expect(last['server'], 'dns-fakeip');
      expect(strings(last['query_type']), equals(<String>['A']));
      expect(fakeip['inet6_range'], isNull);
      expect(dns['strategy'], 'ipv4_only');
      expect(dns['independent_cache'], isTrue);
    });

    test('redir-host mode has no fakeip server', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'dns': <String, dynamic>{
            'enable': true,
            'enhanced-mode': 'redir-host',
            'nameserver': <String>['223.5.5.5'],
          },
        }),
        options: kNoPlatform,
      ).config;
      final List<Dict> servers = dnsServers(config);
      expect(findWhere(servers, (Dict s) => s['type'] == 'fakeip'), isNull);
      expectSubset(
        findWhere(servers, (Dict s) => s['type'] == 'udp'),
        <String, dynamic>{'server': '223.5.5.5'},
      );
    });

    test('respects the ipv6 flag with ipv4_only strategy', () {
      final Dict v4 = convertClashToSingbox(
        base(<String, dynamic>{'ipv6': false}),
        options: kNoPlatform,
      ).config;
      expect((v4['dns'] as Dict)['strategy'], 'ipv4_only');
      final Dict v6 = convertClashToSingbox(
        base(<String, dynamic>{'ipv6': true}),
        options: kNoPlatform,
      ).config;
      expect((v6['dns'] as Dict)['strategy'], isNull);
    });

    test('lets dns.ipv6 disable AAAA even when top-level IPv6 remains enabled',
        () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'ipv6': true,
          'dns': <String, dynamic>{
            'enable': true,
            'ipv6': false,
            'enhanced-mode': 'fake-ip',
          },
        }),
        options: kNoPlatform,
      ).config;
      final Dict dns = config['dns'] as Dict;
      final Dict fakeip =
          findWhere(dnsServers(config), (Dict s) => s['type'] == 'fakeip')!;
      final Dict fakeipRule = findWhere(
        dnsRules(config),
        (Dict r) => r['server'] == 'dns-fakeip',
      )!;

      expect(dns['strategy'], 'ipv4_only');
      expect(fakeip['inet6_range'], isNull);
      expect(strings(fakeipRule['query_type']), equals(<String>['A']));
    });

    test('maps hosts and bootstrap/proxy/direct DNS resolvers', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'hosts': <String, dynamic>{
            'router.lan': '192.168.1.1',
            'nas.lan': <String>['192.168.1.2', 'fd00::2'],
          },
          'dns': <String, dynamic>{
            'enable': true,
            'nameserver': <String>['https://dns.example.com/dns-query'],
            'default-nameserver': <String>['1.1.1.1'],
            'proxy-server-nameserver': <String>['9.9.9.9'],
            'direct-nameserver': <String>['223.5.5.5'],
          },
        }),
        options: kNoPlatform,
      );
      final Dict config = result.config;
      final List<Dict> servers = dnsServers(config);
      final Dict hosts = findWhere(servers, (Dict s) => s['type'] == 'hosts')!;
      expectSubset(
        hosts['predefined'],
        <String, dynamic>{'router.lan': '192.168.1.1'},
      );
      expectSubset(
        dnsRules(config).first,
        <String, dynamic>{'ip_accept_any': true, 'server': 'dns-hosts'},
      );
      expect(
        (config['route'] as Dict)['default_domain_resolver'],
        equals(<String, dynamic>{'server': 'dns-proxy-server-0'}),
      );
      expect(
        firstWhereOrNull(servers, 'dns-0')?['domain_resolver'],
        'dns-bootstrap-0',
      );
      expect(joined(result.warnings), isNot(matches(RegExp('hosts mapping'))));
    });
  });

  group('proxies', () {
    test('maps shadowsocks with obfs plugin', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'ss1',
              'type': 'ss',
              'server': '1.2.3.4',
              'port': 8388,
              'cipher': 'aes-256-gcm',
              'password': 'pw',
              'plugin': 'obfs',
              'plugin-opts': <String, dynamic>{
                'mode': 'http',
                'host': 'bing.com',
              },
            },
          ],
        }),
        options: kNoPlatform,
      ).config;
      expectSubset(outbound(config, 'ss1'), <String, dynamic>{
        'type': 'shadowsocks',
        'server': '1.2.3.4',
        'server_port': 8388,
        'method': 'aes-256-gcm',
        'password': 'pw',
        'plugin': 'obfs-local',
        'plugin_opts': 'obfs=http;obfs-host=bing.com',
      });
    });

    test('maps shadowsocks with v2ray-plugin', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'ss2',
              'type': 'ss',
              'server': 'a.com',
              'port': 443,
              'cipher': 'chacha20-ietf-poly1305',
              'password': 'pw',
              'plugin': 'v2ray-plugin',
              'plugin-opts': <String, dynamic>{
                'mode': 'websocket',
                'tls': true,
                'host': 'a.com',
                'path': '/ws',
              },
            },
          ],
        }),
        options: kNoPlatform,
      ).config;
      final Dict ss = outbound(config, 'ss2');
      expect(ss['plugin'], 'v2ray-plugin');
      expect(ss['plugin_opts'] as String, contains('mode=websocket'));
      expect(ss['plugin_opts'] as String, contains('tls'));
      expect(ss['plugin_opts'] as String, contains('host=a.com'));
    });

    test('maps vmess with ws transport', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'vm1',
              'type': 'vmess',
              'server': 'vm.com',
              'port': 443,
              'uuid': 'uuid-1',
              'alterId': 0,
              'cipher': 'auto',
              'tls': true,
              'servername': 'sni.com',
              'network': 'ws',
              'packet-encoding': 'packetaddr',
              'interface-name': 'Ethernet',
              'tfo': true,
              'ip-version': 'ipv4-prefer',
              'ws-opts': <String, dynamic>{
                'path': '/path',
                'headers': <String, dynamic>{'Host': 'ws.com'},
              },
            },
          ],
        }),
        options: kNoPlatform,
      ).config;
      final Dict vm = outbound(config, 'vm1');
      expectSubset(vm, <String, dynamic>{
        'type': 'vmess',
        'uuid': 'uuid-1',
        'security': 'auto',
        'alter_id': 0,
      });
      expectSubset(vm['transport'], <String, dynamic>{
        'type': 'ws',
        'path': '/path',
        'headers': <String, dynamic>{'Host': 'ws.com'},
      });
      expectSubset(vm['tls'], <String, dynamic>{
        'enabled': true,
        'server_name': 'sni.com',
      });
      expectSubset(vm, <String, dynamic>{
        'packet_encoding': 'packetaddr',
        'bind_interface': 'Ethernet',
        'tcp_fast_open': true,
        'domain_strategy': 'prefer_ipv4',
      });
    });

    test('preserves Clash HTTP transport hosts', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'vm-http',
              'type': 'vmess',
              'server': 'vm.example',
              'port': 443,
              'uuid': 'uuid-http',
              'cipher': 'auto',
              'network': 'http',
              'http-opts': <String, dynamic>{
                'host': <String>['front-one.example', 'front-two.example'],
                'path': <String>['/tunnel'],
              },
            },
          ],
        }),
        options: kNoPlatform,
      ).config;
      expectSubset(outbound(config, 'vm-http')['transport'], <String, dynamic>{
        'type': 'http',
        'host': <String>['front-one.example', 'front-two.example'],
        'path': '/tunnel',
      });
    });

    test('maps vless with reality, vision flow, uTLS and grpc transport', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'vl1',
              'type': 'vless',
              'server': 'vl.com',
              'port': 443,
              'uuid': 'uuid-2',
              'flow': 'xtls-rprx-vision',
              'tls': true,
              'servername': 'real.com',
              'client-fingerprint': 'chrome',
              'reality-opts': <String, dynamic>{
                'public-key': 'pbk',
                'short-id': 'sid',
              },
              'network': 'grpc',
              'grpc-opts': <String, dynamic>{'grpc-service-name': 'svc'},
            },
          ],
        }),
        options: kNoPlatform,
      ).config;
      final Dict vl = outbound(config, 'vl1');
      expect(vl['flow'], 'xtls-rprx-vision');
      final Dict tls = vl['tls'] as Dict;
      expectSubset(tls['reality'], <String, dynamic>{
        'enabled': true,
        'public_key': 'pbk',
        'short_id': 'sid',
      });
      expectSubset(tls['utls'], <String, dynamic>{
        'enabled': true,
        'fingerprint': 'chrome',
      });
      expectSubset(vl['transport'], <String, dynamic>{
        'type': 'grpc',
        'service_name': 'svc',
      });
    });

    test('maps trojan with implicit tls', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'tj1',
              'type': 'trojan',
              'server': 'tj.com',
              'port': 443,
              'password': 'pw',
              'sni': 'sni.tj.com',
              'skip-cert-verify': true,
            },
          ],
        }),
        options: kNoPlatform,
      ).config;
      final Dict tj = outbound(config, 'tj1');
      expect(tj['type'], 'trojan');
      expectSubset(tj['tls'], <String, dynamic>{
        'enabled': true,
        'server_name': 'sni.tj.com',
        'insecure': true,
      });
    });

    test('maps hysteria2 with salamander obfs and bandwidth', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'hy2',
              'type': 'hysteria2',
              'server': 'hy.com',
              'port': 443,
              'password': 'pw',
              'up': '30 Mbps',
              'down': 200,
              'obfs': 'salamander',
              'obfs-password': 'ob',
              'sni': 'hy.com',
            },
          ],
        }),
        options: kNoPlatform,
      ).config;
      final Dict hy = outbound(config, 'hy2');
      expectSubset(hy, <String, dynamic>{
        'type': 'hysteria2',
        'password': 'pw',
        'up_mbps': 30,
        'down_mbps': 200,
      });
      expectSubset(hy['obfs'], <String, dynamic>{
        'type': 'salamander',
        'password': 'ob',
      });
    });

    test('maps hysteria v1, SSH and Hysteria2 port hopping/bandwidth units',
        () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'hy1',
              'type': 'hysteria',
              'server': 'hy.example.com',
              'ports': '20000-30000',
              'hop-interval': 20,
              'up': '1 Gbps',
              'down': '100 Mbps',
              'auth-str': 'secret',
              'sni': 'hy.example.com',
            },
            <String, dynamic>{
              'name': 'hy2-hop',
              'type': 'hysteria2',
              'server': 'hy2.example.com',
              'ports': <String>['40000-40100'],
              'hop-interval': 15,
              'up': '1 Gbps',
              'down': '2 GBps',
              'password': 'secret',
              'sni': 'hy2.example.com',
            },
            <String, dynamic>{
              'name': 'ssh1',
              'type': 'ssh',
              'server': 'ssh.example.com',
              'port': 22,
              'username': 'alice',
              'password': 'secret',
              'host-key': <String>['ssh-ed25519 AAAAfixture'],
            },
          ],
        }),
        options: kNoPlatform,
      );
      final Dict config = result.config;
      expectSubset(outbound(config, 'hy1'), <String, dynamic>{
        'type': 'hysteria',
        'server_ports': <String>['20000:30000'],
        'hop_interval': '20s',
        'up': '1 Gbps',
        'auth_str': 'secret',
      });
      expectSubset(outbound(config, 'hy2-hop'), <String, dynamic>{
        'type': 'hysteria2',
        'server_ports': <String>['40000:40100'],
        'hop_interval': '15s',
        'up_mbps': 1000,
        'down_mbps': 16000,
      });
      expectSubset(outbound(config, 'ssh1'), <String, dynamic>{
        'type': 'ssh',
        'user': 'alice',
        'password': 'secret',
      });
      expect(result.errors, isEmpty);
    });

    test('maps tuic v5', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'tu1',
              'type': 'tuic',
              'server': 'tu.com',
              'port': 443,
              'uuid': 'uuid-3',
              'password': 'pw',
              'congestion-controller': 'bbr',
              'udp-relay-mode': 'native',
              'reduce-rtt': true,
            },
          ],
        }),
        options: kNoPlatform,
      ).config;
      final Dict tu = outbound(config, 'tu1');
      expectSubset(tu, <String, dynamic>{
        'type': 'tuic',
        'uuid': 'uuid-3',
        'password': 'pw',
        'congestion_control': 'bbr',
        'udp_relay_mode': 'native',
        'zero_rtt_handshake': true,
      });
      expect(strings((tu['tls'] as Dict)['alpn']), equals(<String>['h3']));
    });

    test('maps wireguard to an endpoint', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'wg1',
              'type': 'wireguard',
              'server': 'wg.com',
              'port': 51820,
              'ip': '172.16.0.2',
              'private-key': 'priv',
              'public-key': 'pub',
              'reserved': <int>[1, 2, 3],
            },
          ],
        }),
        options: kNoPlatform,
      ).config;
      final Dict wg = endpoint(config, 'wg1');
      expect(wg['type'], 'wireguard');
      expect(strings(wg['address']), equals(<String>['172.16.0.2/32']));
      expect(wg['private_key'], 'priv');
      final Dict peer = (wg['peers'] as List<Object?>).cast<Dict>().first;
      expectSubset(peer, <String, dynamic>{
        'address': 'wg.com',
        'port': 51820,
        'public_key': 'pub',
      });
      expect(numbers(peer['reserved']), equals(<num>[1, 2, 3]));
      // endpoints are selectable in GLOBAL
      expect(strings(outbound(config, 'GLOBAL')['outbounds']), contains('wg1'));
    });

    test('maps http and socks5', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'h1',
              'type': 'http',
              'server': 'h.com',
              'port': 8080,
              'username': 'u',
              'password': 'p',
            },
            <String, dynamic>{
              'name': 's1',
              'type': 'socks5',
              'server': 's.com',
              'port': 1080,
            },
          ],
        }),
        options: kNoPlatform,
      ).config;
      expectSubset(outbound(config, 'h1'), <String, dynamic>{
        'type': 'http',
        'server': 'h.com',
        'server_port': 8080,
      });
      expectSubset(outbound(config, 's1'), <String, dynamic>{
        'type': 'socks',
        'version': '5',
        'server': 's.com',
      });
    });

    test('maps anytls', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'at1',
              'type': 'anytls',
              'server': 'at.com',
              'port': 443,
              'password': 'pw',
              'sni': 'at.com',
              'idle-session-check-interval': '20s',
              'idle-session-timeout': '40s',
              'min-idle-session': 2,
            },
          ],
        }),
        options: kNoPlatform,
      ).config;
      final Dict at = outbound(config, 'at1');
      expect(at['type'], 'anytls');
      expectSubset(at['tls'], <String, dynamic>{
        'enabled': true,
        'server_name': 'at.com',
      });
      expectSubset(at, <String, dynamic>{
        'idle_session_check_interval': '20s',
        'idle_session_timeout': '40s',
        'min_idle_session': 2,
      });
    });

    test('skips unsupported proxy types with a warning, never crashes', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'ssr1',
              'type': 'ssr',
              'server': 'x',
              'port': 1,
            },
            <String, dynamic>{
              'name': 'ok',
              'type': 'ss',
              'server': 'y',
              'port': 2,
              'cipher': 'aes-128-gcm',
              'password': 'p',
            },
          ],
        }),
        options: kNoPlatform,
      );
      expect(firstWhereOrNull(outboundsOf(result.config), 'ssr1'), isNull);
      expect(outbound(result.config, 'ok'), isNotNull);
      expect(joined(result.warnings), matches(RegExp('ssr1')));
    });
  });

  group('proxy groups', () {
    final List<Object?> proxies = <Object?>[
      <String, dynamic>{
        'name': 'p1',
        'type': 'ss',
        'server': 'a',
        'port': 1,
        'cipher': 'aes-128-gcm',
        'password': 'x',
      },
      <String, dynamic>{
        'name': 'p2',
        'type': 'ss',
        'server': 'b',
        'port': 2,
        'cipher': 'aes-128-gcm',
        'password': 'x',
      },
      <String, dynamic>{
        'name': 'HK-1',
        'type': 'ss',
        'server': 'c',
        'port': 3,
        'cipher': 'aes-128-gcm',
        'password': 'x',
      },
    ];

    test('maps select -> selector and url-test -> urltest with '
        'interval/tolerance', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'proxy-groups': <Object?>[
            <String, dynamic>{
              'name': 'Choose',
              'type': 'select',
              'proxies': <String>['Auto', 'p1', 'p2', 'DIRECT'],
            },
            <String, dynamic>{
              'name': 'Auto',
              'type': 'url-test',
              'proxies': <String>['p1', 'p2'],
              'url': 'http://test/204',
              'interval': 300,
              'tolerance': 50,
            },
          ],
        }),
        options: kNoPlatform,
      ).config;
      final Dict select = outbound(config, 'Choose');
      expect(select['type'], 'selector');
      expect(
        strings(select['outbounds']),
        equals(<String>['Auto', 'p1', 'p2', 'direct']),
      );
      expectSubset(outbound(config, 'Auto'), <String, dynamic>{
        'type': 'urltest',
        'url': 'http://test/204',
        'interval': '300s',
        'tolerance': 50,
      });
    });

    test('approximates fallback and load-balance with urltest and warns', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'proxy-groups': <Object?>[
            <String, dynamic>{
              'name': 'FB',
              'type': 'fallback',
              'proxies': <String>['p1', 'p2'],
              'interval': 60,
            },
            <String, dynamic>{
              'name': 'LB',
              'type': 'load-balance',
              'proxies': <String>['p1', 'p2'],
            },
          ],
        }),
        options: kNoPlatform,
      );
      expect(outbound(result.config, 'FB')['type'], 'urltest');
      expect(outbound(result.config, 'LB')['type'], 'urltest');
      expect(joined(result.warnings), matches(RegExp('fallback approximated')));
      expect(
        joined(result.warnings),
        matches(RegExp('load-balance approximated')),
      );
    });

    test('skips relay groups with warning and removes dangling references', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'proxy-groups': <Object?>[
            <String, dynamic>{
              'name': 'Chain',
              'type': 'relay',
              'proxies': <String>['p1', 'p2'],
            },
            <String, dynamic>{
              'name': 'Pick',
              'type': 'select',
              'proxies': <String>['Chain', 'p1'],
            },
          ],
        }),
        options: kNoPlatform,
      );
      expect(firstWhereOrNull(outboundsOf(result.config), 'Chain'), isNull);
      expect(
        strings(outbound(result.config, 'Pick')['outbounds']),
        equals(<String>['p1']),
      );
      expect(joined(result.warnings), matches(RegExp('relay')));
    });

    test('resolves include-all and filter regex statically', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'proxy-groups': <Object?>[
            <String, dynamic>{
              'name': 'HK',
              'type': 'select',
              'include-all': true,
              'filter': '^HK',
            },
          ],
        }),
        options: kNoPlatform,
      ).config;
      expect(
        strings(outbound(config, 'HK')['outbounds']),
        equals(<String>['HK-1']),
      );
    });

    test('supports the common RE2-style leading (?i) filter flag', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'proxy-groups': <Object?>[
            <String, dynamic>{
              'name': 'Hong Kong',
              'type': 'select',
              'include-all': true,
              'filter': '(?i)hk|香港',
            },
          ],
        }),
        options: kNoPlatform,
      );
      expect(
        strings(outbound(result.config, 'Hong Kong')['outbounds']),
        equals(<String>['HK-1']),
      );
      expect(result.errors, isEmpty);
    });

    test('reports empty groups as fatal instead of silently falling back to '
        'direct', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'proxy-groups': <Object?>[
            <String, dynamic>{
              'name': 'Empty',
              'type': 'select',
              'proxies': <String>['does-not-exist'],
            },
          ],
        }),
        options: kNoPlatform,
      );
      expect(
        strings(outbound(result.config, 'Empty')['outbounds']),
        equals(<String>['direct']),
      );
      expect(
        joined(result.errors),
        matches(RegExp('Empty.*refusing unsafe fallback')),
      );
    });

    test('keeps the fatal error and the placeholder "direct" member as one '
        'pair', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'proxy-groups': <Object?>[
            <String, dynamic>{
              'name': 'Empty',
              'type': 'select',
              'proxies': <Object?>[],
            },
          ],
        }),
        options: kNoPlatform,
      );
      // Both halves are load-bearing: the error stops the start, the member
      // keeps the emitted config structurally valid. Dropping either one lets a
      // caller that ignores `errors` ship a silently direct-only group.
      expect(
        result.errors,
        contains(
          'group "Empty": no usable members remain; refusing unsafe fallback '
          'to "direct"',
        ),
      );
      expect(
        strings(outbound(result.config, 'Empty')['outbounds']),
        equals(<String>['direct']),
      );
    });

    test('refuses a group whose name collides with a proxy node', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': <Object?>[
            ...proxies,
            <String, dynamic>{
              'name': 'Auto',
              'type': 'ss',
              'server': 'd',
              'port': 4,
              'cipher': 'aes-128-gcm',
              'password': 'x',
            },
          ],
          'proxy-groups': <Object?>[
            <String, dynamic>{
              'name': 'Auto',
              'type': 'url-test',
              'proxies': <String>['p1', 'p2'],
            },
            <String, dynamic>{
              'name': 'Pick',
              'type': 'select',
              'proxies': <String>['Auto', 'p1'],
            },
          ],
        }),
        options: kNoPlatform,
      );
      final List<Object?> tags =
          outboundsOf(result.config).map((Dict o) => o['tag']).toList();
      expect(
        tags.where((Object? tag) => tag == 'Auto').toList(),
        equals(<Object?>['Auto']),
      );
      expect(outbound(result.config, 'Auto')['type'], 'shadowsocks');
      expect(
        result.errors,
        contains('group "Auto": name collides with a proxy node'),
      );
    });

    test('refuses a group that shadows the built-in direct outbound', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'proxy-groups': <Object?>[
            <String, dynamic>{
              'name': 'direct',
              'type': 'select',
              'proxies': <String>['p1'],
            },
          ],
        }),
        options: kNoPlatform,
      );
      final List<Object?> tags =
          outboundsOf(result.config).map((Dict o) => o['tag']).toList();
      expect(
        tags.where((Object? tag) => tag == 'direct').toList(),
        equals(<Object?>['direct']),
      );
      expect(outbound(result.config, 'direct')['type'], 'direct');
      expect(
        result.errors,
        contains('group "direct": name collides with the built-in direct '
            'outbound'),
      );
    });

    test('still emits groups whose name only collides with a skipped group',
        () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'proxy-groups': <Object?>[
            <String, dynamic>{
              'name': 'Chain',
              'type': 'relay',
              'proxies': <String>['p1', 'p2'],
            },
            <String, dynamic>{
              'name': 'Chain',
              'type': 'select',
              'proxies': <String>['p1'],
            },
          ],
        }),
        options: kNoPlatform,
      );
      expect(outbound(result.config, 'Chain')['type'], 'selector');
      expect(result.errors, isEmpty);
    });

    test('rejects provider-only profiles instead of producing a direct-only '
        'config', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxy-providers': <String, dynamic>{
            'airport': <String, dynamic>{
              'type': 'http',
              'url': 'https://example.invalid/provider.yaml',
            },
          },
          'proxy-groups': <Object?>[
            <String, dynamic>{
              'name': 'Proxy',
              'type': 'select',
              'use': <String>['airport'],
            },
          ],
        }),
        options: kNoPlatform,
      );
      expect(
        joined(result.errors),
        matches(RegExp('proxy-providers.*no inline proxies')),
      );
      expect(
        joined(result.errors),
        matches(
          RegExp(r'unresolved proxy-providers \(use\) must be resolved before '
              'conversion'),
        ),
      );
    });
  });

  group('rules', () {
    final List<Object?> proxies = <Object?>[
      <String, dynamic>{
        'name': 'p1',
        'type': 'ss',
        'server': 'a',
        'port': 1,
        'cipher': 'aes-128-gcm',
        'password': 'x',
      },
    ];

    test('maps basic rule types', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'rules': <String>[
            'DOMAIN,example.com,p1',
            'DOMAIN-SUFFIX,google.com,p1',
            'DOMAIN-KEYWORD,ads,REJECT',
            'IP-CIDR,10.0.0.0/8,DIRECT',
            'IP-CIDR6,2620:0:2d0::/48,DIRECT',
            'SRC-IP-CIDR,192.168.1.0/24,DIRECT',
            'DST-PORT,443,p1',
            'SRC-PORT,7777,DIRECT',
            'PROCESS-NAME,chrome.exe,p1',
            'MATCH,p1',
          ],
        }),
        options: kNoPlatform,
      ).config;
      final List<Dict> rules = routeRules(config);
      expectSubset(
        findWhere(rules, (Dict r) => strings(r['domain']).contains('example.com')),
        <String, dynamic>{'outbound': 'p1'},
      );
      expectSubset(
        findWhere(
          rules,
          (Dict r) => strings(r['domain_suffix']).contains('google.com'),
        ),
        <String, dynamic>{'outbound': 'p1'},
      );
      expectSubset(
        findWhere(
          rules,
          (Dict r) => strings(r['domain_keyword']).contains('ads'),
        ),
        <String, dynamic>{'action': 'reject'},
      );
      expectSubset(
        findWhere(
          rules,
          (Dict r) => strings(r['ip_cidr']).contains('10.0.0.0/8'),
        ),
        <String, dynamic>{'outbound': 'direct'},
      );
      expect(
        findWhere(
          rules,
          (Dict r) => strings(r['ip_cidr']).contains('2620:0:2d0::/48'),
        ),
        isNotNull,
      );
      expect(
        findWhere(
          rules,
          (Dict r) => strings(r['source_ip_cidr']).contains('192.168.1.0/24'),
        ),
        isNotNull,
      );
      expectSubset(
        findWhere(rules, (Dict r) => numbers(r['port']).contains(443)),
        <String, dynamic>{'outbound': 'p1'},
      );
      expect(
        findWhere(rules, (Dict r) => numbers(r['source_port']).contains(7777)),
        isNotNull,
      );
      expect(
        findWhere(
          rules,
          (Dict r) => strings(r['process_name']).contains('chrome.exe'),
        ),
        isNotNull,
      );
      expect((config['route'] as Dict)['final'], 'p1');
    });

    test('maps Windows wildcard/regex process rules and source GeoIP', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'rules': <String>[
            'DOMAIN-WILDCARD,*.example.com,p1',
            'PROCESS-NAME-WILDCARD,chrome*.exe,p1',
            r'PROCESS-PATH-REGEX,^C:\\Apps\\.+\\client\.exe$,p1',
            'SRC-GEOIP,private,DIRECT',
            'MATCH,p1',
          ],
        }),
        options: kNoPlatform,
      );
      final List<Dict> rules = routeRules(result.config);
      expect(
        rules.any((Dict rule) {
          final List<String> regexes = strings(rule['domain_regex']);
          return regexes.isNotEmpty && regexes.first.contains('example');
        }),
        isTrue,
      );
      expect(
        rules.any((Dict rule) => rule['process_path_regex'] is List),
        isTrue,
      );
      expect(
        rules.any((Dict rule) => rule['source_ip_is_private'] == true),
        isTrue,
      );
      expect(result.errors, isEmpty);
    });

    test('converts GEOSITE / GEOIP into remote srs rule-sets with direct '
        'download detour', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'rules': <String>[
            'GEOSITE,category-ads-all,REJECT',
            'GEOIP,CN,DIRECT',
            'GEOIP,LAN,DIRECT',
            'MATCH,p1',
          ],
        }),
        options: kNoPlatform,
      ).config;
      final List<Dict> ruleSetList = ruleSetsOf(config);
      expectSubset(
        firstWhereOrNull(ruleSetList, 'geosite-category-ads-all'),
        <String, dynamic>{
          'type': 'remote',
          'format': 'binary',
          'download_detour': 'direct',
          'url': 'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/'
              'sing/geo/geosite/category-ads-all.srs',
        },
      );
      expect(
        firstWhereOrNull(ruleSetList, 'geoip-cn')?['url'],
        'https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/'
            'geoip/cn.srs',
      );
      final List<Dict> rules = routeRules(config);
      expectSubset(
        findWhere(
          rules,
          (Dict r) =>
              strings(r['rule_set']).contains('geosite-category-ads-all'),
        ),
        <String, dynamic>{'action': 'reject'},
      );
      // GEOIP,LAN becomes ip_is_private, not a rule set
      expectSubset(
        findWhere(rules, (Dict r) => r['ip_is_private'] == true),
        <String, dynamic>{'outbound': 'direct'},
      );
    });

    test('maps logical AND/OR/NOT rules', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'rules': <String>[
            'AND,((DOMAIN-SUFFIX,youtube.com),(NETWORK,UDP)),REJECT',
            'OR,((DOMAIN,a.com),(DOMAIN,b.com)),p1',
            'NOT,((DOMAIN-SUFFIX,cn)),p1',
          ],
        }),
        options: kNoPlatform,
      ).config;
      final List<Dict> rules = routeRules(config);
      final Dict andRule = findWhere(
        rules,
        (Dict r) => r['type'] == 'logical' && r['mode'] == 'and',
      )!;
      expect(andRule['action'], 'reject');
      final List<Dict> andSubs =
          (andRule['rules'] as List<Object?>).cast<Dict>();
      expect(strings(andSubs[0]['domain_suffix']),
          equals(<String>['youtube.com']));
      expect(strings(andSubs[1]['network']), equals(<String>['udp']));
      final Dict orRule = findWhere(
        rules,
        (Dict r) => r['type'] == 'logical' && r['mode'] == 'or',
      )!;
      expect(orRule['outbound'], 'p1');
      final Dict notRule = findWhere(rules, (Dict r) => r['invert'] == true)!;
      expect(strings(notRule['domain_suffix']), equals(<String>['cn']));
    });

    test('rejects rule-providers and unknown targets instead of falling back',
        () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'rules': <String>[
            'RULE-SET,my-provider,p1',
            'DOMAIN,x.com,GhostGroup',
            'MATCH,DIRECT',
          ],
        }),
        options: kNoPlatform,
      );
      final List<Dict> rules = routeRules(result.config);
      expect(
        findWhere(rules, (Dict r) => strings(r['domain']).contains('x.com')),
        isNull,
      );
      expect(joined(result.errors), matches(RegExp('rule-providers')));
      expect(joined(result.errors), matches(RegExp('GhostGroup')));
      expect((result.config['route'] as Dict)['final'], 'direct');
    });

    test('never emits a routing-time resolve action', () {
      // sing-box treats a failed `{action:"resolve"}` as fatal for the
      // connection (route/route.go:537-541), unlike Clash, which just skips the
      // IP rule. With the shipped DoH defaults an unreachable resolver would
      // then drop every connection to a domain, so destination-IP rules stay
      // unresolved instead.
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'rules': <String>[
            'IP-CIDR,1.2.3.4/32,DIRECT,no-resolve',
            'GEOIP,CN,DIRECT',
            'GEOIP,LAN,DIRECT',
            'AND,((DOMAIN-SUFFIX,cn),(IP-CIDR,10.0.0.0/8)),DIRECT',
            'MATCH,p1',
          ],
        }),
        options: kNoPlatform,
      ).config;
      expect(
        routeRules(config).any((Dict r) => r['action'] == 'resolve'),
        isFalse,
      );
    });

    test('peels a trailing no-resolve option off a rule that still has a '
        'target', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'rules': <String>['IP-CIDR,1.2.3.4/32,DIRECT,no-resolve', 'MATCH,p1'],
        }),
        options: kNoPlatform,
      );
      expect(
        findWhere(
          routeRules(result.config),
          (Dict r) => strings(r['ip_cidr']).contains('1.2.3.4/32'),
        ),
        equals(<String, dynamic>{
          'ip_cidr': <String>['1.2.3.4/32'],
          'outbound': 'direct',
        }),
      );
      expect(result.errors, isEmpty);
      expect(
        joined(result.warnings),
        isNot(matches(RegExp(r'1\.2\.3\.4'))),
      );
    });

    test('parses the target of a logical rule that carries no-resolve', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'rules': <String>[
            'AND,((IP-CIDR,10.0.0.0/8),(NETWORK,udp)),DIRECT,no-resolve',
            'MATCH,p1',
          ],
        }),
        options: kNoPlatform,
      );
      expectSubset(
        findWhere(routeRules(result.config), (Dict r) => r['type'] == 'logical'),
        <String, dynamic>{'outbound': 'direct'},
      );
      expect(result.errors, isEmpty);
    });

    test('still aborts on a rule whose target is missing behind no-resolve',
        () {
      // "IP-CIDR,1.2.3.4/32,no-resolve" is a forgotten target, not an
      // option-only rule. Peeling it would downgrade a fatal error to a dropped
      // rule.
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'rules': <String>['IP-CIDR,1.2.3.4/32,no-resolve', 'MATCH,p1'],
        }),
        options: kNoPlatform,
      );
      expect(
        result.errors,
        contains(
          'rule "IP-CIDR,1.2.3.4/32,no-resolve": target "no-resolve" not found '
          'or unsupported',
        ),
      );
    });

    test('still routes to a group that is literally named no-resolve', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'proxy-groups': <Object?>[
            <String, dynamic>{
              'name': 'no-resolve',
              'type': 'select',
              'proxies': <String>['p1'],
            },
          ],
          'rules': <String>['DOMAIN,a.com,no-resolve', 'MATCH,p1'],
        }),
        options: kNoPlatform,
      );
      expectSubset(
        findWhere(
          routeRules(result.config),
          (Dict r) => strings(r['domain']).contains('a.com'),
        ),
        <String, dynamic>{'outbound': 'no-resolve'},
      );
      expect(result.errors, isEmpty);
    });

    test('drops an inverted destination-ip rule instead of emitting a '
        'catch-all', () {
      // `invert` plus an unresolvable destination makes rule_abstract.go report
      // a match, so this rule would send every domain destination to DIRECT.
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'rules': <String>[
            'NOT,((IP-CIDR,10.0.0.0/8)),DIRECT',
            'NOT,((GEOIP,CN)),DIRECT,no-resolve',
            'MATCH,p1',
          ],
        }),
        options: kNoPlatform,
      );
      expect(
        routeRules(result.config).any((Dict r) => r['invert'] == true),
        isFalse,
      );
      expect(
        result.warnings
            .where((String w) =>
                RegExp('inverted destination-IP condition').hasMatch(w))
            .length,
        2,
      );
      expect(result.errors, isEmpty);
      expect((result.config['route'] as Dict)['final'], 'p1');
    });

    test('keeps an inverted source-ip rule, which sing-box can evaluate', () {
      final ConvertResult result = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': proxies,
          'rules': <String>[
            'NOT,((SRC-IP-CIDR,192.168.1.0/24)),DIRECT',
            'MATCH,p1',
          ],
        }),
        options: kNoPlatform,
      );
      expectSubset(
        findWhere(routeRules(result.config), (Dict r) => r['invert'] == true),
        <String, dynamic>{
          'source_ip_cidr': <String>['192.168.1.0/24'],
          'outbound': 'direct',
        },
      );
      expect(
        joined(result.warnings),
        isNot(matches(RegExp('inverted destination-IP'))),
      );
    });
  });

  group('clash mode routing', () {
    test('adds clash_mode rules and a GLOBAL selector containing everything',
        () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'proxies': <Object?>[
            <String, dynamic>{
              'name': 'p1',
              'type': 'ss',
              'server': 'a',
              'port': 1,
              'cipher': 'aes-128-gcm',
              'password': 'x',
            },
          ],
          'proxy-groups': <Object?>[
            <String, dynamic>{
              'name': 'G',
              'type': 'select',
              'proxies': <String>['p1'],
            },
          ],
        }),
        options: kNoPlatform,
      ).config;
      final List<Dict> rules = routeRules(config);
      expectSubset(
        findWhere(rules, (Dict r) => r['clash_mode'] == 'Direct'),
        <String, dynamic>{'outbound': 'direct'},
      );
      expectSubset(
        findWhere(rules, (Dict r) => r['clash_mode'] == 'Global'),
        <String, dynamic>{'outbound': 'GLOBAL'},
      );
      // "Rule" must appear in a rule so sing-box keeps it switchable
      expect(findWhere(rules, (Dict r) => r['clash_mode'] == 'Rule'), isNotNull);
      expect(
        strings(outbound(config, 'GLOBAL')['outbounds']),
        equals(<String>['G', 'p1', 'direct']),
      );
      // clash_mode rules must precede converted profile rules
      final int globalIdx =
          rules.indexWhere((Dict r) => r['clash_mode'] == 'Global');
      expect(globalIdx, greaterThanOrEqualTo(0));
    });

    test('emits sniff and hijack-dns action rules when enabled', () {
      final Dict config = convertClashToSingbox(
        base(<String, dynamic>{
          'sniffer': <String, dynamic>{'enable': true},
          'dns': <String, dynamic>{
            'enable': true,
            'nameserver': <String>['223.5.5.5'],
          },
        }),
        options: kNoPlatform,
      ).config;
      final List<Dict> rules = routeRules(config);
      expect(rules[0], equals(<String, dynamic>{'action': 'sniff'}));
      expect(
        rules[1],
        equals(<String, dynamic>{'protocol': 'dns', 'action': 'hijack-dns'}),
      );
    });
  });
}
