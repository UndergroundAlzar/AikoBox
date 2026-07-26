/// Client for the Clash API that libbox exposes at `experimental.clash_api`.
///
/// Port of `src/main/core/mihomoApi.ts`. REST over `http`, streams over
/// `web_socket_channel`, bearer-token auth, bounded reconnect.
///
/// ## The parse-inside-the-try rule
///
/// Every websocket frame is decoded by [decodeClashFrame] and nothing else.
/// The `jsonDecode` **and** the model construction both live inside that one
/// `try`. The desktop app has a live crash from getting this wrong on exactly
/// one of its four streams; funnelling all four through a single choke point is
/// what makes it impossible to reproduce here.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';

/// A REST call the core rejected, or a response that was not usable.
class ClashApiException implements Exception {
  const ClashApiException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  bool get isNotFound => statusCode == 404;

  @override
  String toString() =>
      'ClashApiException(${statusCode == null ? '' : '$statusCode '}$message)';
}

/// Opens a websocket. Injectable so tests never touch a real socket.
typedef WebSocketConnector =
    WebSocketChannel Function(Uri url, Map<String, dynamic> headers);

WebSocketChannel _defaultConnector(Uri url, Map<String, dynamic> headers) =>
    IOWebSocketChannel.connect(url, headers: headers);

/// Decodes one websocket frame into [T], or `null` when the frame is unusable.
///
/// Nothing about this can throw: a malformed frame, a binary frame, a JSON
/// array where an object was expected, or a model constructor that trips over a
/// surprising field all resolve to `null` and the stream keeps running.
T? decodeClashFrame<T>(Object? frame, T Function(Map<String, dynamic>) parse) {
  try {
    final String text;
    if (frame is String) {
      text = frame;
    } else if (frame is List<int>) {
      text = utf8.decode(frame);
    } else {
      return null;
    }
    if (text.trim().isEmpty) return null;
    final decoded = jsonDecode(text);
    if (decoded is! Map) return null;
    return parse(<String, dynamic>{
      for (final entry in decoded.entries) entry.key.toString(): entry.value,
    });
  } catch (_) {
    return null;
  }
}

/// Parses `GET /proxies` into a [ProxiesSnapshot].
///
/// An entry is a group when it carries an `all` array, exactly as
/// `mihomoApi.ts:isMihomoGroup` decides it.
ProxiesSnapshot parseProxiesResponse(Map<String, dynamic> json) {
  final raw = json['proxies'];
  if (raw is! Map) {
    throw const ClashApiException('/proxies did not return a proxies object');
  }
  final groups = <ProxyGroup>[];
  final nodes = <String, ProxyNode>{};
  var sawGlobal = false;

  for (final entry in raw.entries) {
    final name = entry.key.toString();
    final value = entry.value;
    if (value is! Map) continue;
    final item = <String, dynamic>{
      for (final field in value.entries) field.key.toString(): field.value,
      'name': name,
    };
    if (name == 'GLOBAL') sawGlobal = true;
    if (item['all'] is List) {
      groups.add(ProxyGroup.fromJson(item));
      // A group is also selectable as a member of another group, so it needs a
      // node entry too — otherwise nested selectors render as gaps.
      nodes[name] = ProxyNode.fromJson(item);
    } else {
      nodes[name] = ProxyNode.fromJson(item);
    }
  }

  if (!sawGlobal) {
    throw const ClashApiException('GLOBAL proxy not found');
  }

  return ProxiesSnapshot(
    groups: List<ProxyGroup>.unmodifiable(groups),
    nodes: Map<String, ProxyNode>.unmodifiable(nodes),
  );
}

/// Parses `GET /rules`.
List<RuleItem> parseRulesResponse(Map<String, dynamic> json) {
  final raw = json['rules'];
  if (raw is! List) return const <RuleItem>[];
  return List<RuleItem>.unmodifiable(<RuleItem>[
    for (final entry in raw)
      if (entry is Map)
        RuleItem.fromJson(<String, dynamic>{
          for (final field in entry.entries) field.key.toString(): field.value,
        }),
  ]);
}

/// Parses `GET /providers/proxies` or `GET /providers/rules`.
Map<String, ProviderInfo> parseProvidersResponse(Map<String, dynamic> json) {
  final raw = json['providers'];
  if (raw is! Map) return const <String, ProviderInfo>{};
  return Map<String, ProviderInfo>.unmodifiable(<String, ProviderInfo>{
    for (final entry in raw.entries)
      if (entry.value is Map)
        entry.key.toString(): ProviderInfo.fromJson(<String, dynamic>{
          for (final field in (entry.value as Map).entries)
            field.key.toString(): field.value,
          'name': entry.key.toString(),
        }),
  });
}

/// Parses a `/proxies/<name>/delay` response. `null` means the probe failed —
/// the core answers `{"message": "..."}` rather than an error status.
int? parseDelayResponse(Map<String, dynamic> json) {
  final delay = json['delay'];
  if (delay is num && delay > 0) return delay.toInt();
  if (delay is String) {
    final parsed = int.tryParse(delay.trim());
    if (parsed != null && parsed > 0) return parsed;
  }
  return null;
}

/// Parses a `/group/<name>/delay` response: `{"节点名": 123, ...}`. Entries the
/// core reports as `0` (failed) are kept, because the grid paints them red.
Map<String, int> parseGroupDelayResponse(Map<String, dynamic> json) {
  final result = <String, int>{};
  for (final entry in json.entries) {
    final value = entry.value;
    if (value is num) {
      result[entry.key] = value.toInt();
    } else if (value is String) {
      final parsed = int.tryParse(value.trim());
      if (parsed != null) result[entry.key] = parsed;
    }
  }
  return Map<String, int>.unmodifiable(result);
}

/// Recomputes per-connection speeds by diffing two `/connections` frames.
///
/// sing-box's clash_api, unlike mihomo's, does not send `uploadSpeed` /
/// `downloadSpeed`. Without this the connections page shows a permanent 0 B/s.
ConnectionsSnapshot applyConnectionSpeeds(
  ConnectionsSnapshot snapshot,
  Map<String, ConnectionInfo> previous,
  Duration elapsed,
) {
  final seconds = elapsed.inMilliseconds <= 0
      ? 1.0
      : elapsed.inMilliseconds / 1000.0;
  return snapshot.copyWith(
    connections: <ConnectionInfo>[
      for (final connection in snapshot.connections)
        if (connection.uploadSpeed != 0 || connection.downloadSpeed != 0)
          connection
        else if (previous[connection.id] case final before?)
          connection.copyWith(
            uploadSpeed: ((connection.upload - before.upload) / seconds)
                .round()
                .clamp(0, 1 << 62),
            downloadSpeed: ((connection.download - before.download) / seconds)
                .round()
                .clamp(0, 1 << 62),
          )
        else
          connection,
    ],
  );
}

/// The Clash API client. One instance per `(host, port, secret)` triple; the
/// controller replaces it whenever the core restarts on a new controller.
class ClashApi {
  ClashApi({
    required this.host,
    required this.port,
    required this.secret,
    http.Client? httpClient,
    WebSocketConnector? connector,
    Duration timeout = const Duration(seconds: 15),
    this.maxStreamRetries = 10,
    this.reconnectInterval = const Duration(seconds: 1),
  }) : _client = httpClient ?? http.Client(),
       _ownsClient = httpClient == null,
       _connect = connector ?? _defaultConnector,
       _timeout = timeout;

  final String host;
  final int port;
  final String secret;

  /// Reconnect attempts per stream before it gives up, matching the desktop's
  /// `MAX_RETRY`. Reset to full on every frame received.
  final int maxStreamRetries;
  final Duration reconnectInterval;

  final http.Client _client;
  final bool _ownsClient;
  final WebSocketConnector _connect;
  final Duration _timeout;
  bool _closed = false;

  Map<String, String> get _headers => <String, String>{
    if (secret.isNotEmpty) 'Authorization': 'Bearer $secret',
    'Accept': 'application/json',
  };

  Uri _uri(List<String> segments, [Map<String, String>? query]) => Uri(
    scheme: 'http',
    host: host,
    port: port,
    pathSegments: segments,
    queryParameters: query,
  );

  Uri _wsUri(List<String> segments, [Map<String, String>? query]) => Uri(
    scheme: 'ws',
    host: host,
    port: port,
    pathSegments: segments,
    // The token also goes in the query string: some builds of the clash_api
    // handler read it there and ignore the header on the upgrade request.
    queryParameters: <String, String>{
      ...?query,
      if (secret.isNotEmpty) 'token': secret,
    },
  );

  /// Releases the http client if this instance created it. Streams already
  /// handed out are unaffected until their subscriptions are cancelled.
  void close() {
    if (_closed) return;
    _closed = true;
    if (_ownsClient) _client.close();
  }

  // -------------------------------------------------------------------------
  // REST
  // -------------------------------------------------------------------------

  Future<Map<String, dynamic>> _decodeBody(
    http.Response response,
    String label,
  ) async {
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ClashApiException(
        '$label failed with HTTP ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }
    if (response.bodyBytes.isEmpty) return const <String, dynamic>{};
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (error) {
      throw ClashApiException('$label returned malformed JSON');
    }
    if (decoded is Map) {
      return <String, dynamic>{
        for (final entry in decoded.entries) entry.key.toString(): entry.value,
      };
    }
    throw ClashApiException('$label did not return a JSON object');
  }

  Future<Map<String, dynamic>> _get(
    List<String> segments,
    String label, {
    Map<String, String>? query,
  }) async {
    final http.Response response;
    try {
      response = await _client
          .get(_uri(segments, query), headers: _headers)
          .timeout(_timeout);
    } on TimeoutException {
      throw ClashApiException('$label timed out');
    } catch (error) {
      throw ClashApiException('$label could not reach the core');
    }
    return _decodeBody(response, label);
  }

  Future<void> _send(
    String method,
    List<String> segments,
    String label, {
    Object? body,
    Map<String, String>? query,
  }) async {
    final request = http.Request(method, _uri(segments, query))
      ..headers.addAll(_headers);
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.StreamedResponse streamed;
    try {
      streamed = await _client.send(request).timeout(_timeout);
    } on TimeoutException {
      throw ClashApiException('$label timed out');
    } catch (error) {
      throw ClashApiException('$label could not reach the core');
    }
    // Drain so the connection can be reused even when we ignore the payload.
    await streamed.stream.drain<void>();
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw ClashApiException(
        '$label failed with HTTP ${streamed.statusCode}',
        statusCode: streamed.statusCode,
      );
    }
  }

  /// `GET /version`.
  Future<String> version() async {
    final json = await _get(<String>['version'], 'GET /version');
    final value = json['version'];
    return value == null ? '' : value.toString();
  }

  /// `GET /configs`.
  Future<Map<String, dynamic>> configs() =>
      _get(<String>['configs'], 'GET /configs');

  /// `PATCH /configs` — how `mode`, `log-level` and the listen ports are changed
  /// without restarting the core.
  Future<void> patchConfigs(Map<String, dynamic> patch) =>
      _send('PATCH', <String>['configs'], 'PATCH /configs', body: patch);

  /// `GET /proxies`.
  Future<ProxiesSnapshot> proxies() async =>
      parseProxiesResponse(await _get(<String>['proxies'], 'GET /proxies'));

  /// `PUT /proxies/<group>` — pick [node] inside [group].
  Future<void> selectProxy(String group, String node) => _send(
    'PUT',
    <String>['proxies', group],
    'PUT /proxies/$group',
    body: <String, dynamic>{'name': node},
  );

  /// `GET /proxies/<name>/delay`. `null` when the probe failed.
  Future<int?> proxyDelay(
    String name, {
    String url = 'https://www.gstatic.com/generate_204',
    int timeoutMs = 5000,
  }) async {
    final json = await _get(
      <String>['proxies', name, 'delay'],
      'GET /proxies/$name/delay',
      query: <String, String>{'url': url, 'timeout': '$timeoutMs'},
    );
    return parseDelayResponse(json);
  }

  /// `GET /group/<name>/delay`.
  Future<Map<String, int>> groupDelay(
    String group, {
    String url = 'https://www.gstatic.com/generate_204',
    int timeoutMs = 5000,
  }) async {
    final json = await _get(
      <String>['group', group, 'delay'],
      'GET /group/$group/delay',
      query: <String, String>{'url': url, 'timeout': '$timeoutMs'},
    );
    return parseGroupDelayResponse(json);
  }

  /// `GET /rules`.
  Future<List<RuleItem>> rules() async =>
      parseRulesResponse(await _get(<String>['rules'], 'GET /rules'));

  /// `GET /providers/proxies`.
  ///
  /// sing-box has no Clash proxy providers; a failure here is soft, exactly as
  /// `mihomoApi.ts:mihomoProxyProviders` treats it.
  Future<Map<String, ProviderInfo>> proxyProviders() async {
    try {
      return parseProvidersResponse(
        await _get(<String>['providers', 'proxies'], 'GET /providers/proxies'),
      );
    } on ClashApiException {
      return const <String, ProviderInfo>{};
    }
  }

  /// `GET /providers/rules`. Soft-fails like [proxyProviders].
  Future<Map<String, ProviderInfo>> ruleProviders() async {
    try {
      return parseProvidersResponse(
        await _get(<String>['providers', 'rules'], 'GET /providers/rules'),
      );
    } on ClashApiException {
      return const <String, ProviderInfo>{};
    }
  }

  /// `PUT /providers/proxies/<name>`.
  Future<void> updateProxyProvider(String name) => _send('PUT', <String>[
    'providers',
    'proxies',
    name,
  ], 'PUT /providers/proxies/$name');

  /// `PUT /providers/rules/<name>`.
  Future<void> updateRuleProvider(String name) => _send('PUT', <String>[
    'providers',
    'rules',
    name,
  ], 'PUT /providers/rules/$name');

  /// `GET /connections`.
  Future<ConnectionsSnapshot> connectionsOnce() async =>
      ConnectionsSnapshot.fromJson(
        await _get(<String>['connections'], 'GET /connections'),
      );

  /// `DELETE /connections/<id>`.
  Future<void> closeConnection(String id) =>
      _send('DELETE', <String>['connections', id], 'DELETE /connections/$id');

  /// `DELETE /connections`.
  Future<void> closeAllConnections() =>
      _send('DELETE', <String>['connections'], 'DELETE /connections');

  // -------------------------------------------------------------------------
  // Streams
  // -------------------------------------------------------------------------

  /// The single reconnecting websocket implementation behind all four streams.
  ///
  /// Bounded retry: [maxStreamRetries] attempts, [reconnectInterval] apart, with
  /// the budget restored to full whenever a frame arrives — a stream that is
  /// working is never counted against its own retry budget.
  Stream<T> _jsonStream<T>(
    List<String> segments,
    T Function(Map<String, dynamic>) parse, {
    Map<String, String>? query,
  }) async* {
    var retriesLeft = maxStreamRetries;
    while (true) {
      WebSocketChannel? channel;
      try {
        channel = _connect(_wsUri(segments, query), <String, dynamic>{
          if (secret.isNotEmpty) 'Authorization': 'Bearer $secret',
        });
        // The readiness future has to be observed. A failed connection
        // completes it with an error, and an unobserved one is reported as an
        // unhandled async error instead of becoming a reconnect.
        await channel.ready;
        await for (final frame in channel.stream) {
          retriesLeft = maxStreamRetries;
          final value = decodeClashFrame<T>(frame, parse);
          if (value != null) yield value;
        }
      } catch (_) {
        // Connection refused, upgrade rejected, socket reset — all of them
        // just mean "try again", and none of them may kill the stream.
      } finally {
        _closeQuietly(channel);
      }
      if (retriesLeft <= 0) return;
      retriesLeft--;
      await Future<void>.delayed(reconnectInterval);
    }
  }

  /// Closes a channel without waiting for it.
  ///
  /// Deliberately not awaited: closing a channel whose connection never
  /// succeeded returns a future that never completes, because the underlying
  /// stream controller has no listener left to drain it. Awaiting that would
  /// wedge the reconnect loop on the very failure it exists to recover from.
  static void _closeQuietly(WebSocketChannel? channel) {
    if (channel == null) return;
    unawaited(channel.sink.close().then<void>((_) {}, onError: (Object _) {}));
  }

  /// `ws://…/traffic` — bytes/second, one frame per second.
  Stream<TrafficPoint> trafficStream() =>
      _jsonStream<TrafficPoint>(<String>['traffic'], TrafficPoint.fromJson);

  /// `ws://…/memory`.
  Stream<MemoryPoint> memoryStream() =>
      _jsonStream<MemoryPoint>(<String>['memory'], MemoryPoint.fromJson);

  /// `ws://…/logs`.
  Stream<LogLine> logsStream({LogLevel level = LogLevel.info}) =>
      _jsonStream<LogLine>(
        <String>['logs'],
        LogLine.fromClashJson,
        query: <String, String>{'level': level.singboxWireName},
      );

  /// `ws://…/connections`, with per-connection speeds filled in locally.
  Stream<ConnectionsSnapshot> connectionsStream() {
    var previous = <String, ConnectionInfo>{};
    DateTime? previousAt;
    return _jsonStream<ConnectionsSnapshot>(<String>[
      'connections',
    ], ConnectionsSnapshot.fromJson).map((snapshot) {
      final now = DateTime.now();
      final elapsed = previousAt == null
          ? Duration.zero
          : now.difference(previousAt!);
      final withSpeeds = previous.isEmpty
          ? snapshot
          : applyConnectionSpeeds(snapshot, previous, elapsed);
      previous = <String, ConnectionInfo>{
        for (final connection in snapshot.connections)
          connection.id: connection,
      };
      previousAt = now;
      return withSpeeds;
    });
  }
}
