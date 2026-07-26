import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aikobox_mobile/core/clash_api.dart';
import 'package:aikobox_mobile/core/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('decodeClashFrame', () {
    // The desktop app crashed because one of its four websocket handlers did
    // its JSON.parse outside the try. Every frame shape that could possibly
    // arrive has to resolve to null here, never to a throw.
    test('accepts a well-formed frame', () {
      final point = decodeClashFrame<TrafficPoint>(
        '{"up":100,"down":200}',
        TrafficPoint.fromJson,
      );
      expect(point, isNotNull);
      expect(point!.up, 100);
      expect(point.down, 200);
    });

    test('returns null instead of throwing for malformed JSON', () {
      expect(
        decodeClashFrame<TrafficPoint>('{not json', TrafficPoint.fromJson),
        isNull,
      );
      expect(decodeClashFrame<TrafficPoint>('', TrafficPoint.fromJson), isNull);
      expect(
        decodeClashFrame<TrafficPoint>('   ', TrafficPoint.fromJson),
        isNull,
      );
      expect(
        decodeClashFrame<TrafficPoint>('null', TrafficPoint.fromJson),
        isNull,
      );
      expect(
        decodeClashFrame<TrafficPoint>('[1,2,3]', TrafficPoint.fromJson),
        isNull,
      );
      expect(
        decodeClashFrame<TrafficPoint>('"a string"', TrafficPoint.fromJson),
        isNull,
      );
      expect(decodeClashFrame<TrafficPoint>(42, TrafficPoint.fromJson), isNull);
      expect(
        decodeClashFrame<TrafficPoint>(null, TrafficPoint.fromJson),
        isNull,
      );
    });

    test(
      'returns null instead of throwing when the parser itself blows up',
      () {
        expect(
          decodeClashFrame<TrafficPoint>(
            '{"up":1}',
            (json) => throw StateError('parser exploded'),
          ),
          isNull,
        );
      },
    );

    test('decodes binary frames as UTF-8 and survives invalid bytes', () {
      expect(
        decodeClashFrame<TrafficPoint>(
          utf8.encode('{"up":5,"down":6}'),
          TrafficPoint.fromJson,
        )!.up,
        5,
      );
      expect(
        decodeClashFrame<TrafficPoint>(<int>[
          0xC3,
          0x28,
          0xFF,
        ], TrafficPoint.fromJson),
        isNull,
      );
    });

    test('all four stream payload shapes decode without throwing', () {
      expect(
        decodeClashFrame<TrafficPoint>(
          '{"up":1,"down":2}',
          TrafficPoint.fromJson,
        ),
        isNotNull,
      );
      expect(
        decodeClashFrame<MemoryPoint>(
          '{"inuse":123,"oslimit":456}',
          MemoryPoint.fromJson,
        ),
        isNotNull,
      );
      expect(
        decodeClashFrame<LogLine>(
          '{"type":"info","payload":"hi"}',
          LogLine.fromClashJson,
        ),
        isNotNull,
      );
      expect(
        decodeClashFrame<ConnectionsSnapshot>(
          '{"downloadTotal":1,"uploadTotal":2,"connections":[],"memory":3}',
          ConnectionsSnapshot.fromJson,
        ),
        isNotNull,
      );

      // …and the same four refuse the same garbage the same way.
      for (final parser in <Object? Function(Object?)>[
        (frame) => decodeClashFrame<TrafficPoint>(frame, TrafficPoint.fromJson),
        (frame) => decodeClashFrame<MemoryPoint>(frame, MemoryPoint.fromJson),
        (frame) => decodeClashFrame<LogLine>(frame, LogLine.fromClashJson),
        (frame) => decodeClashFrame<ConnectionsSnapshot>(
          frame,
          ConnectionsSnapshot.fromJson,
        ),
      ]) {
        expect(parser('<html>502 Bad Gateway</html>'), isNull);
        expect(parser('{"truncated":'), isNull);
      }
    });
  });

  group('parseProxiesResponse', () {
    Map<String, dynamic> proxiesPayload() => <String, dynamic>{
      'proxies': <String, dynamic>{
        'DIRECT': <String, dynamic>{
          'type': 'Direct',
          'udp': true,
          'history': <dynamic>[],
        },
        '香港 01': <String, dynamic>{
          'type': 'Shadowsocks',
          'udp': true,
          'alive': true,
          'history': <dynamic>[
            <String, dynamic>{'time': '2026-07-26T10:00:00Z', 'delay': 0},
            <String, dynamic>{'time': '2026-07-26T10:01:00Z', 'delay': 143},
          ],
        },
        '节点选择': <String, dynamic>{
          'type': 'Selector',
          'now': '香港 01',
          'all': <String>['DIRECT', '香港 01'],
          'hidden': false,
          'icon': '',
        },
        'GLOBAL': <String, dynamic>{
          'type': 'Selector',
          'now': '节点选择',
          'all': <String>['节点选择', 'DIRECT', '香港 01'],
          'hidden': false,
        },
      },
    };

    test('splits groups from nodes and keeps the core ordering', () {
      final snapshot = parseProxiesResponse(proxiesPayload());

      expect(snapshot.groups.map((g) => g.name), <String>['节点选择', 'GLOBAL']);
      expect(
        snapshot.nodes.keys,
        containsAll(<String>['DIRECT', '香港 01', '节点选择']),
      );
      expect(snapshot.groupNamed('节点选择')!.now, '香港 01');
      expect(snapshot.groupNamed('节点选择')!.all, <String>['DIRECT', '香港 01']);
    });

    test('takes the latest successful probe as the node delay', () {
      final node = parseProxiesResponse(proxiesPayload()).nodeNamed('香港 01')!;
      expect(node.delay, 143);
      expect(node.history, hasLength(2));
      expect(node.history.first.failed, isTrue);
      expect(node.udp, isTrue);
    });

    test('reports a failed probe as no delay rather than as zero', () {
      final snapshot = parseProxiesResponse(<String, dynamic>{
        'proxies': <String, dynamic>{
          'GLOBAL': <String, dynamic>{
            'type': 'Selector',
            'now': 'x',
            'all': <String>['x'],
          },
          'x': <String, dynamic>{
            'type': 'Vmess',
            'history': <dynamic>[
              <String, dynamic>{'time': '2026-07-26T10:00:00Z', 'delay': 0},
            ],
          },
        },
      });
      expect(snapshot.nodeNamed('x')!.delay, isNull);
    });

    test(
      'a group is also addressable as a node, so nested selectors render',
      () {
        final snapshot = parseProxiesResponse(proxiesPayload());
        expect(snapshot.nodeNamed('节点选择'), isNotNull);
        expect(snapshot.membersOf('GLOBAL').map((n) => n.name), <String>[
          '节点选择',
          'DIRECT',
          '香港 01',
        ]);
      },
    );

    test('refuses a response with no GLOBAL outbound', () {
      expect(
        () => parseProxiesResponse(<String, dynamic>{
          'proxies': <String, dynamic>{
            'DIRECT': <String, dynamic>{'type': 'Direct'},
          },
        }),
        throwsA(isA<ClashApiException>()),
      );
    });

    test('refuses a response that is not a proxies object', () {
      expect(
        () => parseProxiesResponse(<String, dynamic>{'proxies': 'nope'}),
        throwsA(isA<ClashApiException>()),
      );
    });

    test('skips entries the core sent as something other than an object', () {
      final snapshot = parseProxiesResponse(<String, dynamic>{
        'proxies': <String, dynamic>{
          'GLOBAL': <String, dynamic>{
            'type': 'Selector',
            'now': '',
            'all': <String>[],
          },
          'junk': 'not an object',
        },
      });
      expect(snapshot.nodes.containsKey('junk'), isFalse);
    });
  });

  group('parseRulesResponse', () {
    test('parses rules and tolerates junk entries', () {
      final rules = parseRulesResponse(<String, dynamic>{
        'rules': <dynamic>[
          <String, dynamic>{
            'type': 'DOMAIN-SUFFIX',
            'payload': 'google.com',
            'proxy': '节点选择',
            'size': -1,
          },
          <String, dynamic>{'type': 'MATCH', 'payload': '', 'proxy': 'DIRECT'},
          'not an object',
        ],
      });

      expect(rules, hasLength(2));
      expect(rules.first.payload, 'google.com');
      expect(rules.last.type, 'MATCH');
      expect(rules.last.size, -1);
    });

    test('an absent rules array is an empty list, not a crash', () {
      expect(parseRulesResponse(<String, dynamic>{}), isEmpty);
      expect(parseRulesResponse(<String, dynamic>{'rules': 12}), isEmpty);
    });
  });

  group('parseProvidersResponse', () {
    test('parses providers, their proxies and their subscription usage', () {
      final providers = parseProvidersResponse(<String, dynamic>{
        'providers': <String, dynamic>{
          'Airport': <String, dynamic>{
            'type': 'Proxy',
            'vehicleType': 'HTTP',
            'updatedAt': '2026-07-26T09:00:00Z',
            'proxies': <dynamic>[
              <String, dynamic>{'name': 'a'},
              <String, dynamic>{'name': 'b'},
            ],
            'subscriptionInfo': <String, dynamic>{
              'Upload': 10,
              'Download': 20,
              'Total': 100,
              'Expire': 2218532293,
            },
          },
        },
      });

      final airport = providers['Airport']!;
      expect(airport.name, 'Airport');
      expect(airport.proxyNames, <String>['a', 'b']);
      expect(airport.subscription!.used, 30);
      expect(airport.subscription!.usedFraction, closeTo(0.3, 1e-9));
      expect(airport.updatedAt, isNotNull);
    });

    test('an absent providers object is an empty map', () {
      expect(parseProvidersResponse(<String, dynamic>{}), isEmpty);
    });
  });

  group('delay parsing', () {
    test('a successful probe returns milliseconds', () {
      expect(parseDelayResponse(<String, dynamic>{'delay': 143}), 143);
      expect(parseDelayResponse(<String, dynamic>{'delay': '143'}), 143);
    });

    test('a failed probe returns null rather than zero', () {
      expect(parseDelayResponse(<String, dynamic>{'delay': 0}), isNull);
      expect(
        parseDelayResponse(<String, dynamic>{'message': 'timeout'}),
        isNull,
      );
      expect(parseDelayResponse(<String, dynamic>{}), isNull);
    });

    test('group delay keeps failures so the grid can paint them red', () {
      final delays = parseGroupDelayResponse(<String, dynamic>{
        '香港 01': 143,
        '日本 02': 0,
        'broken': 'nope',
      });
      expect(delays, <String, int>{'香港 01': 143, '日本 02': 0});
    });
  });

  group('ConnectionInfo', () {
    test(
      'derives a display host from metadata, preferring the sniffed name',
      () {
        final connection = ConnectionInfo.fromJson(<String, dynamic>{
          'id': 'abc',
          'upload': 100,
          'download': 200,
          'start': '2026-07-26T10:00:00Z',
          'chains': <String>['香港 01', '节点选择'],
          'rule': 'DomainSuffix',
          'rulePayload': 'google.com',
          'metadata': <String, dynamic>{
            'network': 'TCP',
            'host': 'www.google.com',
            'destinationIP': '142.250.0.1',
            'destinationPort': '443',
            'process': 'com.android.chrome',
          },
        });

        expect(connection.host, 'www.google.com:443');
        expect(connection.network, 'tcp');
        expect(connection.outbound, '香港 01');
        expect(connection.process, 'com.android.chrome');
      },
    );

    test('falls back to the destination IP when nothing was sniffed', () {
      final connection = ConnectionInfo.fromJson(<String, dynamic>{
        'id': 'abc',
        'metadata': <String, dynamic>{
          'network': 'udp',
          'destinationIP': '1.1.1.1',
          'destinationPort': '53',
        },
      });
      expect(connection.host, '1.1.1.1:53');
    });

    test('a snapshot with no connections array is empty, not a crash', () {
      final snapshot = ConnectionsSnapshot.fromJson(<String, dynamic>{
        'uploadTotal': 5,
        'downloadTotal': 6,
        'memory': 7,
      });
      expect(snapshot.connections, isEmpty);
      expect(snapshot.uploadTotal, 5);
    });
  });

  group('applyConnectionSpeeds', () {
    ConnectionInfo make(String id, int upload, int download) => ConnectionInfo(
      id: id,
      host: 'h',
      network: 'tcp',
      rule: '',
      chains: const <String>[],
      upload: upload,
      download: download,
      uploadSpeed: 0,
      downloadSpeed: 0,
      start: DateTime(2026),
    );

    test('derives speeds by diffing consecutive snapshots', () {
      final previous = <String, ConnectionInfo>{'a': make('a', 1000, 2000)};
      final result = applyConnectionSpeeds(
        ConnectionsSnapshot(
          connections: <ConnectionInfo>[make('a', 3000, 5000)],
        ),
        previous,
        const Duration(seconds: 2),
      );

      expect(result.connections.single.uploadSpeed, 1000);
      expect(result.connections.single.downloadSpeed, 1500);
    });

    test('a brand new connection reports no speed rather than a spike', () {
      final result = applyConnectionSpeeds(
        ConnectionsSnapshot(
          connections: <ConnectionInfo>[make('new', 9999, 9999)],
        ),
        <String, ConnectionInfo>{},
        const Duration(seconds: 1),
      );
      expect(result.connections.single.uploadSpeed, 0);
    });

    test('never produces a negative speed when counters reset', () {
      final result = applyConnectionSpeeds(
        ConnectionsSnapshot(connections: <ConnectionInfo>[make('a', 10, 10)]),
        <String, ConnectionInfo>{'a': make('a', 1000, 1000)},
        const Duration(seconds: 1),
      );
      expect(result.connections.single.uploadSpeed, 0);
      expect(result.connections.single.downloadSpeed, 0);
    });

    test('leaves speeds the core already reported alone', () {
      final reported = make(
        'a',
        100,
        100,
      ).copyWith(uploadSpeed: 42, downloadSpeed: 43);
      final result = applyConnectionSpeeds(
        ConnectionsSnapshot(connections: <ConnectionInfo>[reported]),
        <String, ConnectionInfo>{'a': make('a', 0, 0)},
        const Duration(seconds: 1),
      );
      expect(result.connections.single.uploadSpeed, 42);
      expect(result.connections.single.downloadSpeed, 43);
    });
  });

  group('SubscriptionUsage.tryParseHeader', () {
    test('parses a subscription-userinfo header', () {
      final usage = SubscriptionUsage.tryParseHeader(
        'upload=1234; download=2234; total=1024000; expire=2218532293',
      );
      expect(usage!.upload, 1234);
      expect(usage.download, 2234);
      expect(usage.total, 1024000);
      expect(usage.remaining, 1024000 - 3468);
      expect(usage.expiresAt, isNotNull);
    });

    test('tolerates partial and malformed headers', () {
      expect(SubscriptionUsage.tryParseHeader('total=100')!.total, 100);
      expect(SubscriptionUsage.tryParseHeader('garbage'), isNull);
      expect(SubscriptionUsage.tryParseHeader(''), isNull);
      expect(SubscriptionUsage.tryParseHeader(null), isNull);
      expect(SubscriptionUsage.tryParseHeader('upload=abc'), isNull);
    });

    test('reports no quota rather than dividing by zero', () {
      const usage = SubscriptionUsage(
        upload: 1,
        download: 1,
        total: 0,
        expire: 0,
      );
      expect(usage.usedFraction, isNull);
      expect(usage.remaining, 0);
      expect(usage.expiresAt, isNull);
    });
  });

  group('LogLine', () {
    test('reads the Clash frame shape', () {
      final line = LogLine.fromClashJson(<String, dynamic>{
        'type': 'warning',
        'payload': '[TCP] dial failed',
      });
      expect(line.severity, LogLevel.warning);
      expect(line.payload, '[TCP] dial failed');
    });

    test('reads the platform-channel frame shape', () {
      final line = LogLine.fromChannelJson(<String, dynamic>{
        'level': 'error',
        'message': 'service died',
        'time': 1784000000000,
      });
      expect(line.severity, LogLevel.error);
      expect(line.payload, 'service died');
      expect(line.time.year, greaterThan(2020));
    });

    test('maps sing-box levels onto the Clash set', () {
      expect(LogLevel.fromWire('warn'), LogLevel.warning);
      expect(LogLevel.fromWire('fatal'), LogLevel.error);
      expect(LogLevel.fromWire('panic'), LogLevel.error);
      expect(LogLevel.fromWire('trace'), LogLevel.debug);
      expect(LogLevel.fromWire('nonsense'), LogLevel.info);
      expect(LogLevel.silent.singboxWireName, 'fatal');
    });
  });

  group('ClashApi REST', () {
    ClashApi apiWith(MockClient client) => ClashApi(
      host: '127.0.0.1',
      port: 9090,
      secret: 's3cret',
      httpClient: client,
    );

    test('sends the bearer token on every request', () async {
      late http.Request seen;
      final api = apiWith(
        MockClient((request) async {
          seen = request;
          return http.Response(
            jsonEncode(<String, dynamic>{'version': '1.13.14'}),
            200,
          );
        }),
      );

      expect(await api.version(), '1.13.14');
      expect(seen.headers['Authorization'], 'Bearer s3cret');
      expect(seen.url.path, '/version');
    });

    test('percent-encodes group and node names in the path', () async {
      late http.Request seen;
      final api = apiWith(
        MockClient((request) async {
          seen = request;
          return http.Response('{}', 204);
        }),
      );

      await api.selectProxy('节点选择', '香港 01');

      expect(seen.method, 'PUT');
      expect(seen.url.pathSegments, <String>['proxies', '节点选择']);
      expect(jsonDecode(seen.body), <String, dynamic>{'name': '香港 01'});
    });

    test('passes the delay probe url and timeout through', () async {
      late http.Request seen;
      final api = apiWith(
        MockClient((request) async {
          seen = request;
          return http.Response(jsonEncode(<String, dynamic>{'delay': 88}), 200);
        }),
      );

      expect(
        await api.proxyDelay(
          '香港 01',
          url: 'https://example.test/204',
          timeoutMs: 3000,
        ),
        88,
      );
      expect(seen.url.pathSegments, <String>['proxies', '香港 01', 'delay']);
      expect(seen.url.queryParameters['url'], 'https://example.test/204');
      expect(seen.url.queryParameters['timeout'], '3000');
    });

    test(
      'turns a non-2xx response into a ClashApiException with its status',
      () async {
        final api = apiWith(
          MockClient((request) async => http.Response('nope', 502)),
        );

        await expectLater(
          api.rules(),
          throwsA(
            isA<ClashApiException>().having(
              (e) => e.statusCode,
              'statusCode',
              502,
            ),
          ),
        );
      },
    );

    test(
      'turns malformed JSON into a ClashApiException, not a FormatException',
      () async {
        final api = apiWith(
          MockClient((request) async => http.Response('{oops', 200)),
        );
        await expectLater(api.configs(), throwsA(isA<ClashApiException>()));
      },
    );

    test(
      'soft-fails provider endpoints the sing-box core does not implement',
      () async {
        final api = apiWith(
          MockClient((request) async => http.Response('not found', 404)),
        );

        expect(await api.proxyProviders(), isEmpty);
        expect(await api.ruleProviders(), isEmpty);
      },
    );

    test('surfaces a 404 on group delay so the caller can fall back', () async {
      final api = apiWith(
        MockClient((request) async => http.Response('nope', 404)),
      );
      await expectLater(
        api.groupDelay('g'),
        throwsA(
          isA<ClashApiException>().having(
            (e) => e.isNotFound,
            'isNotFound',
            isTrue,
          ),
        ),
      );
    });

    test('deletes a connection by id', () async {
      late http.BaseRequest seen;
      final api = apiWith(
        MockClient((request) async {
          seen = request;
          return http.Response('', 204);
        }),
      );

      await api.closeConnection('abc/def');
      expect(seen.method, 'DELETE');
      expect(seen.url.pathSegments, <String>['connections', 'abc/def']);
    });

    test('patches configs with a JSON body', () async {
      late http.Request seen;
      final api = apiWith(
        MockClient((request) async {
          seen = request;
          return http.Response('', 204);
        }),
      );

      await api.patchConfigs(<String, dynamic>{'mode': 'global'});
      expect(seen.method, 'PATCH');
      expect(seen.headers['Content-Type'], contains('application/json'));
      expect(jsonDecode(seen.body), <String, dynamic>{'mode': 'global'});
    });

    test(
      'omits the Authorization header when the core has no secret',
      () async {
        late http.Request seen;
        final api = ClashApi(
          host: '127.0.0.1',
          port: 9090,
          secret: '',
          httpClient: MockClient((request) async {
            seen = request;
            return http.Response(
              jsonEncode(<String, dynamic>{'version': 'x'}),
              200,
            );
          }),
        );

        await api.version();
        expect(seen.headers.containsKey('Authorization'), isFalse);
      },
    );
  });

  group('ClashApi websocket streams', () {
    late HttpServer server;

    tearDown(() async {
      await server.close(force: true);
    });

    ClashApi apiFor(HttpServer server, {int retries = 2}) => ClashApi(
      host: server.address.address,
      port: server.port,
      secret: 's3cret',
      maxStreamRetries: retries,
      reconnectInterval: const Duration(milliseconds: 20),
    );

    test('keeps running past a malformed frame', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add('{"up":1,"down":2}');
        socket.add('this is not json');
        socket.add('[]');
        socket.add('{"up":3,"down":4}');
        await socket.close();
      });

      final api = apiFor(server, retries: 0);
      final points = await api.trafficStream().take(2).toList();

      expect(points.map((p) => p.up), <int>[1, 3]);
      api.close();
    });

    test(
      'sends the bearer token both as a header and as a query token',
      () async {
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final seen = Completer<HttpRequest>();
        server.listen((request) async {
          if (!seen.isCompleted) seen.complete(request);
          final socket = await WebSocketTransformer.upgrade(request);
          socket.add('{"up":1,"down":1}');
          await socket.close();
        });

        final api = apiFor(server, retries: 0);
        await api.trafficStream().first;
        final request = await seen.future;

        expect(request.headers.value('authorization'), 'Bearer s3cret');
        expect(request.uri.queryParameters['token'], 's3cret');
        expect(request.uri.path, '/traffic');
        api.close();
      },
    );

    test('reconnects after the core drops the socket', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      var connections = 0;
      server.listen((request) async {
        final index = ++connections;
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add(jsonEncode(<String, dynamic>{'up': index, 'down': 0}));
        await socket.close();
      });

      final api = apiFor(server, retries: 5);
      final points = await api.trafficStream().take(3).toList();

      expect(points.map((p) => p.up), <int>[1, 2, 3]);
      expect(connections, greaterThanOrEqualTo(3));
      api.close();
    });

    test(
      'gives up after the retry budget instead of spinning forever',
      () async {
        // Bind then close, so the port is free and every connection is refused.
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final deadPort = server.port;
        await server.close(force: true);
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);

        final api = ClashApi(
          host: '127.0.0.1',
          port: deadPort,
          secret: '',
          maxStreamRetries: 2,
          reconnectInterval: const Duration(milliseconds: 10),
        );

        // The budget is what makes this terminate at all: without it the stream
        // would retry a dead controller forever and the test would hang.
        final points = await api.trafficStream().toList().timeout(
          const Duration(seconds: 30),
        );

        expect(points, isEmpty);
        api.close();
      },
    );

    test('applies derived speeds to the connections stream', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        Map<String, dynamic> frame(int upload) => <String, dynamic>{
          'uploadTotal': upload,
          'downloadTotal': 0,
          'memory': 0,
          'connections': <dynamic>[
            <String, dynamic>{
              'id': 'a',
              'upload': upload,
              'download': 0,
              'start': '2026-07-26T10:00:00Z',
              'chains': <String>['DIRECT'],
              'rule': 'Match',
              'metadata': <String, dynamic>{
                'network': 'tcp',
                'host': 'example.test',
              },
            },
          ],
        };
        socket.add(jsonEncode(frame(0)));
        await Future<void>.delayed(const Duration(milliseconds: 40));
        socket.add(jsonEncode(frame(4000)));
        await socket.close();
      });

      final api = apiFor(server, retries: 0);
      final snapshots = await api.connectionsStream().take(2).toList();

      expect(snapshots.first.connections.single.uploadSpeed, 0);
      expect(snapshots.last.connections.single.uploadSpeed, greaterThan(0));
      expect(snapshots.last.uploadTotal, 4000);
      api.close();
    });

    test('carries the log level into the query string', () async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final seen = Completer<HttpRequest>();
      server.listen((request) async {
        if (!seen.isCompleted) seen.complete(request);
        final socket = await WebSocketTransformer.upgrade(request);
        socket.add('{"type":"debug","payload":"hello"}');
        await socket.close();
      });

      final api = apiFor(server, retries: 0);
      final line = await api.logsStream(level: LogLevel.debug).first;
      final request = await seen.future;

      expect(request.uri.queryParameters['level'], 'debug');
      expect(line.payload, 'hello');
      api.close();
    });
  });
}
