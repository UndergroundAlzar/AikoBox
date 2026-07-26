/// Plain immutable value types shared by the whole app.
///
/// Every class here hand-writes `fromJson` / `toJson` / `copyWith` and value
/// equality. There is deliberately no code generation: a generated file that
/// goes stale in CI costs more than the boilerplate.
///
/// Field shapes mirror the desktop app's `src/shared/types.d.ts`
/// (`IMihomoProxy`, `IMihomoGroup`, `IMihomoConnectionDetail`, `IProfileItem`,
/// `ISubscriptionUserInfo`), reduced to what a phone screen actually renders.
library;

import 'package:collection/collection.dart';

const ListEquality<String> _stringList = ListEquality<String>();
const DeepCollectionEquality _deep = DeepCollectionEquality();

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// `mode` in the Clash API's `/configs`.
enum OutboundMode {
  rule('rule'),
  global('global'),
  direct('direct');

  const OutboundMode(this.wireName);

  /// The literal the core speaks.
  final String wireName;

  static OutboundMode fromWire(Object? value) {
    final name = value?.toString().trim().toLowerCase();
    for (final mode in OutboundMode.values) {
      if (mode.wireName == name) return mode;
    }
    return OutboundMode.rule;
  }
}

/// Lifecycle of the embedded sing-box core, as reported over
/// `EventChannel("aikobox/core/status")`.
///
/// [running] is only ever published after the health gate passes (N1) — it
/// does not mean "the service started".
enum CoreState {
  stopped('stopped'),
  starting('starting'),
  running('running'),
  stopping('stopping'),
  failed('failed');

  const CoreState(this.wireName);

  final String wireName;

  bool get isActive => this == CoreState.running || this == CoreState.starting;

  static CoreState fromWire(Object? value) {
    final name = value?.toString().trim().toLowerCase();
    for (final state in CoreState.values) {
      if (state.wireName == name) return state;
    }
    return CoreState.stopped;
  }
}

/// Log severity, matching the core's `/logs` stream and the desktop's
/// `LogLevel` union.
enum LogLevel {
  silent('silent'),
  error('error'),
  warning('warning'),
  info('info'),
  debug('debug');

  const LogLevel(this.wireName);

  final String wireName;

  /// sing-box has no `silent`; `fatal` is the closest thing to no output.
  String get singboxWireName => this == LogLevel.silent ? 'fatal' : wireName;

  static LogLevel fromWire(Object? value) {
    final name = value?.toString().trim().toLowerCase();
    switch (name) {
      case 'warn':
        return LogLevel.warning;
      case 'fatal':
      case 'panic':
        return LogLevel.error;
      case 'trace':
        return LogLevel.debug;
    }
    for (final level in LogLevel.values) {
      if (level.wireName == name) return level;
    }
    return LogLevel.info;
  }
}

/// Dashboard card sizing. Mirrors the desktop's
/// `CardStatus = 'col-span-2' | 'col-span-1' | 'hidden'`.
enum CardStatus {
  colSpan2('col-span-2'),
  colSpan1('col-span-1'),
  hidden('hidden');

  const CardStatus(this.wireName);

  final String wireName;

  int get columnSpan => this == CardStatus.colSpan2 ? 2 : 1;

  bool get isVisible => this != CardStatus.hidden;

  static CardStatus fromWire(
    Object? value, {
    CardStatus fallback = CardStatus.colSpan1,
  }) {
    final name = value?.toString().trim();
    for (final status in CardStatus.values) {
      if (status.wireName == name) return status;
    }
    return fallback;
  }
}

/// How the per-app split tunnel list is interpreted.
enum SplitTunnelMode {
  off('off'),
  allow('allow'),
  deny('deny');

  const SplitTunnelMode(this.wireName);

  final String wireName;

  static SplitTunnelMode fromWire(Object? value) {
    final name = value?.toString().trim().toLowerCase();
    for (final mode in SplitTunnelMode.values) {
      if (mode.wireName == name) return mode;
    }
    return SplitTunnelMode.off;
  }
}

/// `appTheme` in the desktop config.
enum AppThemeMode {
  system('system'),
  light('light'),
  dark('dark');

  const AppThemeMode(this.wireName);

  final String wireName;

  static AppThemeMode fromWire(Object? value) {
    final name = value?.toString().trim().toLowerCase();
    for (final mode in AppThemeMode.values) {
      if (mode.wireName == name) return mode;
    }
    return AppThemeMode.system;
  }
}

/// `proxyDisplayOrder` in the desktop config.
enum ProxySortOrder {
  byDefault('default'),
  byDelay('delay'),
  byName('name');

  const ProxySortOrder(this.wireName);

  final String wireName;

  static ProxySortOrder fromWire(Object? value) {
    final name = value?.toString().trim().toLowerCase();
    for (final order in ProxySortOrder.values) {
      if (order.wireName == name) return order;
    }
    return ProxySortOrder.byDefault;
  }
}

// ---------------------------------------------------------------------------
// Coercion helpers — every payload here comes off a socket, so nothing is
// allowed to assume a type.
// ---------------------------------------------------------------------------

int _asInt(Object? value, [int fallback = 0]) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value.trim()) ?? fallback;
  return fallback;
}

int? _asIntOrNull(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final trimmed = value.trim();
    if (trimmed.isEmpty) return null;
    return int.tryParse(trimmed);
  }
  return null;
}

bool _asBool(Object? value, [bool fallback = false]) {
  if (value is bool) return value;
  if (value is num) return value != 0;
  if (value is String) {
    final normalized = value.trim().toLowerCase();
    if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
      return true;
    }
    if (normalized == 'false' || normalized == '0' || normalized == 'no') {
      return false;
    }
  }
  return fallback;
}

String _asString(Object? value, [String fallback = '']) {
  if (value == null) return fallback;
  if (value is String) return value;
  return value.toString();
}

String? _asStringOrNull(Object? value) {
  if (value == null) return null;
  final text = value is String ? value : value.toString();
  return text.isEmpty ? null : text;
}

List<String> _asStringList(Object? value) {
  if (value is List) {
    return List<String>.unmodifiable(
      value.where((e) => e != null).map((e) => e.toString()),
    );
  }
  return const <String>[];
}

Map<String, dynamic> _asMap(Object? value) {
  if (value is Map) {
    return <String, dynamic>{
      for (final entry in value.entries) entry.key.toString(): entry.value,
    };
  }
  return const <String, dynamic>{};
}

/// Clash timestamps are RFC 3339 strings; libbox occasionally emits epoch
/// milliseconds. Both are accepted, and an unparseable value never throws.
DateTime _asTime(Object? value, {DateTime? fallback}) {
  if (value is DateTime) return value;
  if (value is num) {
    final millis = value > 1e12 ? value.toInt() : (value * 1000).toInt();
    return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true).toLocal();
  }
  if (value is String && value.trim().isNotEmpty) {
    final parsed = DateTime.tryParse(value.trim());
    if (parsed != null) return parsed.toLocal();
    final epoch = int.tryParse(value.trim());
    if (epoch != null) {
      return DateTime.fromMillisecondsSinceEpoch(
        epoch > 1e12 ? epoch : epoch * 1000,
        isUtc: true,
      ).toLocal();
    }
  }
  return fallback ?? DateTime.fromMillisecondsSinceEpoch(0);
}

// ---------------------------------------------------------------------------
// Proxies
// ---------------------------------------------------------------------------

/// One entry of `IMihomoProxy.history`.
class DelaySample {
  const DelaySample({required this.time, required this.delay});

  factory DelaySample.fromJson(Map<String, dynamic> json) =>
      DelaySample(time: _asTime(json['time']), delay: _asInt(json['delay']));

  final DateTime time;

  /// Milliseconds. `0` is how the core reports a failed probe.
  final int delay;

  bool get failed => delay <= 0;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'time': time.toUtc().toIso8601String(),
    'delay': delay,
  };

  DelaySample copyWith({DateTime? time, int? delay}) =>
      DelaySample(time: time ?? this.time, delay: delay ?? this.delay);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DelaySample && other.time == time && other.delay == delay;

  @override
  int get hashCode => Object.hash(time, delay);

  @override
  String toString() => 'DelaySample($delay ms @ $time)';
}

/// A single outbound. Port of `IMihomoProxy`, trimmed to what the grid shows.
class ProxyNode {
  const ProxyNode({
    required this.name,
    required this.type,
    this.udp = false,
    this.delay,
    this.history = const <DelaySample>[],
    this.alive = true,
    this.providerName,
  });

  factory ProxyNode.fromJson(Map<String, dynamic> json) {
    final history = <DelaySample>[
      if (json['history'] is List)
        for (final entry in json['history'] as List)
          if (entry is Map) DelaySample.fromJson(_asMap(entry)),
    ];
    final latest = history.isEmpty ? null : history.last.delay;
    return ProxyNode(
      name: _asString(json['name']),
      type: _asString(json['type'], 'Unknown'),
      udp: _asBool(json['udp']),
      delay: latest == null || latest <= 0 ? null : latest,
      history: List<DelaySample>.unmodifiable(history),
      alive: _asBool(json['alive'], true),
      providerName: _asStringOrNull(json['provider-name']),
    );
  }

  final String name;

  /// `Shadowsocks`, `Vmess`, `Direct`, `Selector`, … verbatim from the core.
  final String type;
  final bool udp;

  /// Latest successful probe in milliseconds; `null` when untested or failed.
  final int? delay;
  final List<DelaySample> history;
  final bool alive;

  /// Set when the node came from a proxy provider rather than the main list.
  final String? providerName;

  /// `true` for the pseudo-outbounds the core always synthesises.
  bool get isBuiltin =>
      name == 'DIRECT' ||
      name == 'REJECT' ||
      name == 'REJECT-DROP' ||
      name == 'PASS';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'type': type,
    'udp': udp,
    if (delay != null) 'delay': delay,
    'history': history.map((e) => e.toJson()).toList(growable: false),
    'alive': alive,
    if (providerName != null) 'provider-name': providerName,
  };

  ProxyNode copyWith({
    String? name,
    String? type,
    bool? udp,
    int? delay,
    bool clearDelay = false,
    List<DelaySample>? history,
    bool? alive,
    String? providerName,
  }) => ProxyNode(
    name: name ?? this.name,
    type: type ?? this.type,
    udp: udp ?? this.udp,
    delay: clearDelay ? null : (delay ?? this.delay),
    history: history ?? this.history,
    alive: alive ?? this.alive,
    providerName: providerName ?? this.providerName,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProxyNode &&
          other.name == name &&
          other.type == type &&
          other.udp == udp &&
          other.delay == delay &&
          other.alive == alive &&
          other.providerName == providerName &&
          const ListEquality<DelaySample>().equals(other.history, history);

  @override
  int get hashCode => Object.hash(
    name,
    type,
    udp,
    delay,
    alive,
    providerName,
    const ListEquality<DelaySample>().hash(history),
  );

  @override
  String toString() => 'ProxyNode($name, $type, ${delay ?? '-'} ms)';
}

/// A selector / urltest / fallback / load-balance group. Port of `IMihomoGroup`.
class ProxyGroup {
  const ProxyGroup({
    required this.name,
    required this.type,
    required this.now,
    this.all = const <String>[],
    this.hidden = false,
    this.icon,
    this.testUrl,
  });

  factory ProxyGroup.fromJson(Map<String, dynamic> json) => ProxyGroup(
    name: _asString(json['name']),
    type: _asString(json['type'], 'Selector'),
    now: _asString(json['now']),
    all: _asStringList(json['all']),
    hidden: _asBool(json['hidden']),
    icon: _asStringOrNull(json['icon']),
    testUrl: _asStringOrNull(json['testUrl']),
  );

  final String name;

  /// `Selector`, `URLTest`, `Fallback`, `LoadBalance`, `Relay`.
  final String type;

  /// The currently selected member.
  final String now;

  /// Member names, in the order the core reports them.
  final List<String> all;
  final bool hidden;
  final String? icon;
  final String? testUrl;

  /// Only `Selector` accepts a manual choice; everything else picks for itself.
  bool get isSelectable => type.toLowerCase() == 'selector';

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'type': type,
    'now': now,
    'all': all,
    'hidden': hidden,
    if (icon != null) 'icon': icon,
    if (testUrl != null) 'testUrl': testUrl,
  };

  ProxyGroup copyWith({
    String? name,
    String? type,
    String? now,
    List<String>? all,
    bool? hidden,
    String? icon,
    String? testUrl,
  }) => ProxyGroup(
    name: name ?? this.name,
    type: type ?? this.type,
    now: now ?? this.now,
    all: all ?? this.all,
    hidden: hidden ?? this.hidden,
    icon: icon ?? this.icon,
    testUrl: testUrl ?? this.testUrl,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProxyGroup &&
          other.name == name &&
          other.type == type &&
          other.now == now &&
          other.hidden == hidden &&
          other.icon == icon &&
          other.testUrl == testUrl &&
          _stringList.equals(other.all, all);

  @override
  int get hashCode => Object.hash(
    name,
    type,
    now,
    hidden,
    icon,
    testUrl,
    _stringList.hash(all),
  );

  @override
  String toString() =>
      'ProxyGroup($name, $type, now=$now, ${all.length} members)';
}

/// The full result of one `GET /proxies` — groups in declaration order plus a
/// lookup table for every outbound the core knows about.
class ProxiesSnapshot {
  const ProxiesSnapshot({
    this.groups = const <ProxyGroup>[],
    this.nodes = const <String, ProxyNode>{},
  });

  static const ProxiesSnapshot empty = ProxiesSnapshot();

  final List<ProxyGroup> groups;
  final Map<String, ProxyNode> nodes;

  ProxyGroup? groupNamed(String name) =>
      groups.firstWhereOrNull((g) => g.name == name);

  ProxyNode? nodeNamed(String name) => nodes[name];

  /// Members of [groupName] resolved to nodes, skipping anything the core did
  /// not report (a provider member can legitimately be missing).
  List<ProxyNode> membersOf(String groupName) {
    final group = groupNamed(groupName);
    if (group == null) return const <ProxyNode>[];
    return <ProxyNode>[
      for (final memberName in group.all)
        if (nodes[memberName] case final node?)
          node
        else if (groupNamed(memberName) case final nested?)
          ProxyNode(name: nested.name, type: nested.type),
    ];
  }

  ProxiesSnapshot copyWith({
    List<ProxyGroup>? groups,
    Map<String, ProxyNode>? nodes,
  }) => ProxiesSnapshot(
    groups: groups ?? this.groups,
    nodes: nodes ?? this.nodes,
  );

  /// Applies a selection locally so the grid updates before the next poll.
  ProxiesSnapshot withSelection(String groupName, String nodeName) =>
      ProxiesSnapshot(
        groups: <ProxyGroup>[
          for (final group in groups)
            if (group.name == groupName)
              group.copyWith(now: nodeName)
            else
              group,
        ],
        nodes: nodes,
      );

  /// Applies a fresh delay measurement to one node.
  ProxiesSnapshot withDelay(String nodeName, int? delay) {
    final node = nodes[nodeName];
    if (node == null) return this;
    return ProxiesSnapshot(
      groups: groups,
      nodes: <String, ProxyNode>{
        ...nodes,
        nodeName: node.copyWith(delay: delay, clearDelay: delay == null),
      },
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'groups': groups.map((g) => g.toJson()).toList(growable: false),
    'nodes': <String, dynamic>{
      for (final entry in nodes.entries) entry.key: entry.value.toJson(),
    },
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProxiesSnapshot &&
          const ListEquality<ProxyGroup>().equals(other.groups, groups) &&
          const MapEquality<String, ProxyNode>().equals(other.nodes, nodes);

  @override
  int get hashCode => Object.hash(
    const ListEquality<ProxyGroup>().hash(groups),
    const MapEquality<String, ProxyNode>().hash(nodes),
  );
}

// ---------------------------------------------------------------------------
// Connections
// ---------------------------------------------------------------------------

/// One live connection. Port of `IMihomoConnectionDetail`, flattened.
///
/// sing-box's clash_api does not send per-connection speeds the way mihomo
/// does; [uploadSpeed] / [downloadSpeed] are derived by diffing consecutive
/// snapshots in `ClashApi.connectionsStream()`.
class ConnectionInfo {
  const ConnectionInfo({
    required this.id,
    required this.host,
    required this.network,
    required this.rule,
    required this.chains,
    required this.upload,
    required this.download,
    required this.uploadSpeed,
    required this.downloadSpeed,
    required this.start,
    this.type = '',
    this.sourceIp = '',
    this.destinationIp = '',
    this.process = '',
    this.rulePayload = '',
  });

  factory ConnectionInfo.fromJson(Map<String, dynamic> json) {
    final metadata = _asMap(json['metadata']);
    final destinationIp = _asString(metadata['destinationIP']);
    final destinationPort = _asString(metadata['destinationPort']);
    final sniffHost = _asString(metadata['sniffHost']);
    var host = _asString(metadata['host']);
    if (host.isEmpty) host = sniffHost;
    if (host.isEmpty) host = destinationIp;
    if (host.isNotEmpty && destinationPort.isNotEmpty) {
      host = '$host:$destinationPort';
    }

    return ConnectionInfo(
      id: _asString(json['id']),
      host: host,
      network: _asString(metadata['network'], 'tcp').toLowerCase(),
      rule: _asString(json['rule']),
      chains: _asStringList(json['chains']),
      upload: _asInt(json['upload']),
      download: _asInt(json['download']),
      uploadSpeed: _asInt(json['uploadSpeed']),
      downloadSpeed: _asInt(json['downloadSpeed']),
      start: _asTime(json['start'], fallback: DateTime.now()),
      type: _asString(metadata['type']),
      sourceIp: _asString(metadata['sourceIP']),
      destinationIp: destinationIp,
      process: _asString(metadata['process']),
      rulePayload: _asString(json['rulePayload']),
    );
  }

  final String id;

  /// `host:port` when the core sniffed a name, `ip:port` otherwise.
  final String host;

  /// `tcp` or `udp`.
  final String network;
  final String rule;

  /// Outbound chain, outermost first — exactly as the core orders it.
  final List<String> chains;
  final int upload;
  final int download;
  final int uploadSpeed;
  final int downloadSpeed;
  final DateTime start;
  final String type;
  final String sourceIp;
  final String destinationIp;

  /// Android reports the owning package here when `find-process-mode` is on.
  final String process;
  final String rulePayload;

  /// The outbound actually carrying the traffic.
  String get outbound => chains.isEmpty ? '' : chains.first;

  Duration get age => DateTime.now().difference(start);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'upload': upload,
    'download': download,
    'uploadSpeed': uploadSpeed,
    'downloadSpeed': downloadSpeed,
    'start': start.toUtc().toIso8601String(),
    'chains': chains,
    'rule': rule,
    'rulePayload': rulePayload,
    'metadata': <String, dynamic>{
      'host': host,
      'network': network,
      'type': type,
      'sourceIP': sourceIp,
      'destinationIP': destinationIp,
      'process': process,
    },
  };

  ConnectionInfo copyWith({
    String? id,
    String? host,
    String? network,
    String? rule,
    List<String>? chains,
    int? upload,
    int? download,
    int? uploadSpeed,
    int? downloadSpeed,
    DateTime? start,
    String? type,
    String? sourceIp,
    String? destinationIp,
    String? process,
    String? rulePayload,
  }) => ConnectionInfo(
    id: id ?? this.id,
    host: host ?? this.host,
    network: network ?? this.network,
    rule: rule ?? this.rule,
    chains: chains ?? this.chains,
    upload: upload ?? this.upload,
    download: download ?? this.download,
    uploadSpeed: uploadSpeed ?? this.uploadSpeed,
    downloadSpeed: downloadSpeed ?? this.downloadSpeed,
    start: start ?? this.start,
    type: type ?? this.type,
    sourceIp: sourceIp ?? this.sourceIp,
    destinationIp: destinationIp ?? this.destinationIp,
    process: process ?? this.process,
    rulePayload: rulePayload ?? this.rulePayload,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConnectionInfo &&
          other.id == id &&
          other.host == host &&
          other.network == network &&
          other.rule == rule &&
          other.upload == upload &&
          other.download == download &&
          other.uploadSpeed == uploadSpeed &&
          other.downloadSpeed == downloadSpeed &&
          other.start == start &&
          other.type == type &&
          other.sourceIp == sourceIp &&
          other.destinationIp == destinationIp &&
          other.process == process &&
          other.rulePayload == rulePayload &&
          _stringList.equals(other.chains, chains);

  @override
  int get hashCode => Object.hash(
    id,
    host,
    network,
    rule,
    upload,
    download,
    uploadSpeed,
    downloadSpeed,
    start,
    type,
    sourceIp,
    destinationIp,
    process,
    rulePayload,
    _stringList.hash(chains),
  );

  @override
  String toString() => 'ConnectionInfo($id, $network $host via $outbound)';
}

/// One frame of the `/connections` websocket. Port of `IMihomoConnectionsInfo`.
class ConnectionsSnapshot {
  const ConnectionsSnapshot({
    this.connections = const <ConnectionInfo>[],
    this.uploadTotal = 0,
    this.downloadTotal = 0,
    this.memory = 0,
  });

  factory ConnectionsSnapshot.fromJson(Map<String, dynamic> json) =>
      ConnectionsSnapshot(
        connections: <ConnectionInfo>[
          if (json['connections'] is List)
            for (final entry in json['connections'] as List)
              if (entry is Map) ConnectionInfo.fromJson(_asMap(entry)),
        ],
        uploadTotal: _asInt(json['uploadTotal']),
        downloadTotal: _asInt(json['downloadTotal']),
        memory: _asInt(json['memory']),
      );

  static const ConnectionsSnapshot empty = ConnectionsSnapshot();

  final List<ConnectionInfo> connections;
  final int uploadTotal;
  final int downloadTotal;
  final int memory;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'connections': connections.map((c) => c.toJson()).toList(growable: false),
    'uploadTotal': uploadTotal,
    'downloadTotal': downloadTotal,
    'memory': memory,
  };

  ConnectionsSnapshot copyWith({
    List<ConnectionInfo>? connections,
    int? uploadTotal,
    int? downloadTotal,
    int? memory,
  }) => ConnectionsSnapshot(
    connections: connections ?? this.connections,
    uploadTotal: uploadTotal ?? this.uploadTotal,
    downloadTotal: downloadTotal ?? this.downloadTotal,
    memory: memory ?? this.memory,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ConnectionsSnapshot &&
          other.uploadTotal == uploadTotal &&
          other.downloadTotal == downloadTotal &&
          other.memory == memory &&
          const ListEquality<ConnectionInfo>().equals(
            other.connections,
            connections,
          );

  @override
  int get hashCode => Object.hash(
    uploadTotal,
    downloadTotal,
    memory,
    const ListEquality<ConnectionInfo>().hash(connections),
  );
}

// ---------------------------------------------------------------------------
// Logs, traffic, memory
// ---------------------------------------------------------------------------

/// One line from either the Clash `/logs` websocket or
/// `EventChannel("aikobox/core/logs")`.
class LogLine {
  const LogLine({
    required this.level,
    required this.payload,
    required this.time,
  });

  /// Clash `/logs` frames: `{"type": "info", "payload": "..."}`.
  factory LogLine.fromClashJson(Map<String, dynamic> json) => LogLine(
    level: _asString(json['type'] ?? json['level'], 'info').toLowerCase(),
    payload: _asString(json['payload'] ?? json['message']),
    time: json['time'] == null
        ? DateTime.now()
        : _asTime(json['time'], fallback: DateTime.now()),
  );

  /// Platform-channel frames: `{level: String, message: String, time: int}`.
  factory LogLine.fromChannelJson(Map<String, dynamic> json) => LogLine(
    level: _asString(json['level'], 'info').toLowerCase(),
    payload: _asString(json['message'] ?? json['payload']),
    time: json['time'] == null
        ? DateTime.now()
        : _asTime(json['time'], fallback: DateTime.now()),
  );

  factory LogLine.fromJson(Map<String, dynamic> json) =>
      json.containsKey('payload') || json.containsKey('type')
      ? LogLine.fromClashJson(json)
      : LogLine.fromChannelJson(json);

  final String level;
  final String payload;
  final DateTime time;

  LogLevel get severity => LogLevel.fromWire(level);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'level': level,
    'payload': payload,
    'time': time.toUtc().toIso8601String(),
  };

  LogLine copyWith({String? level, String? payload, DateTime? time}) => LogLine(
    level: level ?? this.level,
    payload: payload ?? this.payload,
    time: time ?? this.time,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LogLine &&
          other.level == level &&
          other.payload == payload &&
          other.time == time;

  @override
  int get hashCode => Object.hash(level, payload, time);

  @override
  String toString() => '[$level] $payload';
}

/// One frame of the `/traffic` websocket: bytes moved in the last second.
class TrafficPoint {
  const TrafficPoint({required this.up, required this.down, required this.at});

  factory TrafficPoint.fromJson(Map<String, dynamic> json) => TrafficPoint(
    up: _asInt(json['up']),
    down: _asInt(json['down']),
    at: json['at'] == null
        ? DateTime.now()
        : _asTime(json['at'], fallback: DateTime.now()),
  );

  static final TrafficPoint zero = TrafficPoint(
    up: 0,
    down: 0,
    at: DateTime.fromMillisecondsSinceEpoch(0),
  );

  /// Bytes per second.
  final int up;

  /// Bytes per second.
  final int down;
  final DateTime at;

  int get total => up + down;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'up': up,
    'down': down,
    'at': at.toUtc().toIso8601String(),
  };

  TrafficPoint copyWith({int? up, int? down, DateTime? at}) => TrafficPoint(
    up: up ?? this.up,
    down: down ?? this.down,
    at: at ?? this.at,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrafficPoint &&
          other.up == up &&
          other.down == down &&
          other.at == at;

  @override
  int get hashCode => Object.hash(up, down, at);

  @override
  String toString() => 'TrafficPoint(up=$up/s down=$down/s)';
}

/// One frame of the `/memory` websocket. Port of `IMihomoMemoryInfo`.
class MemoryPoint {
  const MemoryPoint({
    required this.inuse,
    required this.oslimit,
    required this.at,
  });

  factory MemoryPoint.fromJson(Map<String, dynamic> json) => MemoryPoint(
    inuse: _asInt(json['inuse']),
    oslimit: _asInt(json['oslimit']),
    at: json['at'] == null
        ? DateTime.now()
        : _asTime(json['at'], fallback: DateTime.now()),
  );

  final int inuse;
  final int oslimit;
  final DateTime at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'inuse': inuse,
    'oslimit': oslimit,
    'at': at.toUtc().toIso8601String(),
  };

  MemoryPoint copyWith({int? inuse, int? oslimit, DateTime? at}) => MemoryPoint(
    inuse: inuse ?? this.inuse,
    oslimit: oslimit ?? this.oslimit,
    at: at ?? this.at,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MemoryPoint &&
          other.inuse == inuse &&
          other.oslimit == oslimit &&
          other.at == at;

  @override
  int get hashCode => Object.hash(inuse, oslimit, at);
}

// ---------------------------------------------------------------------------
// Rules and providers
// ---------------------------------------------------------------------------

/// One entry of `GET /rules`. Port of `IMihomoRulesDetail`.
class RuleItem {
  const RuleItem({
    required this.type,
    required this.payload,
    required this.proxy,
    this.size = -1,
  });

  factory RuleItem.fromJson(Map<String, dynamic> json) => RuleItem(
    type: _asString(json['type']),
    payload: _asString(json['payload']),
    proxy: _asString(json['proxy']),
    size: _asInt(json['size'], -1),
  );

  final String type;
  final String payload;
  final String proxy;

  /// Rule-set cardinality; `-1` for a plain inline rule.
  final int size;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'type': type,
    'payload': payload,
    'proxy': proxy,
    'size': size,
  };

  RuleItem copyWith({
    String? type,
    String? payload,
    String? proxy,
    int? size,
  }) => RuleItem(
    type: type ?? this.type,
    payload: payload ?? this.payload,
    proxy: proxy ?? this.proxy,
    size: size ?? this.size,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RuleItem &&
          other.type == type &&
          other.payload == payload &&
          other.proxy == proxy &&
          other.size == size;

  @override
  int get hashCode => Object.hash(type, payload, proxy, size);

  @override
  String toString() => 'RuleItem($type,$payload,$proxy)';
}

/// A proxy or rule provider from `GET /providers/{proxies,rules}`.
class ProviderInfo {
  const ProviderInfo({
    required this.name,
    required this.type,
    required this.vehicleType,
    this.behavior,
    this.format,
    this.ruleCount,
    this.updatedAt,
    this.proxyNames = const <String>[],
    this.subscription,
  });

  factory ProviderInfo.fromJson(Map<String, dynamic> json) {
    final rawSubscription = json['subscriptionInfo'];
    return ProviderInfo(
      name: _asString(json['name']),
      type: _asString(json['type']),
      vehicleType: _asString(json['vehicleType']),
      behavior: _asStringOrNull(json['behavior']),
      format: _asStringOrNull(json['format']),
      ruleCount: _asIntOrNull(json['ruleCount']),
      updatedAt: json['updatedAt'] == null ? null : _asTime(json['updatedAt']),
      proxyNames: <String>[
        if (json['proxies'] is List)
          for (final entry in json['proxies'] as List)
            if (entry is Map) _asString(_asMap(entry)['name']),
      ],
      subscription: rawSubscription is Map
          ? SubscriptionUsage.fromUpperJson(_asMap(rawSubscription))
          : null,
    );
  }

  final String name;
  final String type;
  final String vehicleType;
  final String? behavior;
  final String? format;
  final int? ruleCount;
  final DateTime? updatedAt;
  final List<String> proxyNames;
  final SubscriptionUsage? subscription;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'name': name,
    'type': type,
    'vehicleType': vehicleType,
    if (behavior != null) 'behavior': behavior,
    if (format != null) 'format': format,
    if (ruleCount != null) 'ruleCount': ruleCount,
    if (updatedAt != null) 'updatedAt': updatedAt!.toUtc().toIso8601String(),
    'proxies': proxyNames
        .map((n) => <String, dynamic>{'name': n})
        .toList(growable: false),
    if (subscription != null) 'subscriptionInfo': subscription!.toUpperJson(),
  };

  ProviderInfo copyWith({
    String? name,
    String? type,
    String? vehicleType,
    String? behavior,
    String? format,
    int? ruleCount,
    DateTime? updatedAt,
    List<String>? proxyNames,
    SubscriptionUsage? subscription,
  }) => ProviderInfo(
    name: name ?? this.name,
    type: type ?? this.type,
    vehicleType: vehicleType ?? this.vehicleType,
    behavior: behavior ?? this.behavior,
    format: format ?? this.format,
    ruleCount: ruleCount ?? this.ruleCount,
    updatedAt: updatedAt ?? this.updatedAt,
    proxyNames: proxyNames ?? this.proxyNames,
    subscription: subscription ?? this.subscription,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProviderInfo &&
          other.name == name &&
          other.type == type &&
          other.vehicleType == vehicleType &&
          other.behavior == behavior &&
          other.format == format &&
          other.ruleCount == ruleCount &&
          other.updatedAt == updatedAt &&
          other.subscription == subscription &&
          _stringList.equals(other.proxyNames, proxyNames);

  @override
  int get hashCode => Object.hash(
    name,
    type,
    vehicleType,
    behavior,
    format,
    ruleCount,
    updatedAt,
    subscription,
    _stringList.hash(proxyNames),
  );
}

// ---------------------------------------------------------------------------
// Profiles
// ---------------------------------------------------------------------------

/// Traffic allowance reported by a subscription. Port of `ISubscriptionUserInfo`.
class SubscriptionUsage {
  const SubscriptionUsage({
    required this.upload,
    required this.download,
    required this.total,
    required this.expire,
  });

  factory SubscriptionUsage.fromJson(Map<String, dynamic> json) =>
      SubscriptionUsage(
        upload: _asInt(json['upload']),
        download: _asInt(json['download']),
        total: _asInt(json['total']),
        expire: _asInt(json['expire']),
      );

  /// The `Upload`/`Download`/`Total`/`Expire` spelling used inside a provider's
  /// `subscriptionInfo` (`ISubscriptionUserInfoUpper`).
  factory SubscriptionUsage.fromUpperJson(Map<String, dynamic> json) =>
      SubscriptionUsage(
        upload: _asInt(json['Upload'] ?? json['upload']),
        download: _asInt(json['Download'] ?? json['download']),
        total: _asInt(json['Total'] ?? json['total']),
        expire: _asInt(json['Expire'] ?? json['expire']),
      );

  /// Parses a `subscription-userinfo` response header, e.g.
  /// `upload=1234; download=2234; total=1024000; expire=2218532293`.
  /// Returns `null` when the header carries none of the four keys.
  static SubscriptionUsage? tryParseHeader(String? header) {
    if (header == null || header.trim().isEmpty) return null;
    var upload = 0;
    var download = 0;
    var total = 0;
    var expire = 0;
    var matched = false;
    for (final part in header.split(';')) {
      final separator = part.indexOf('=');
      if (separator <= 0) continue;
      final key = part.substring(0, separator).trim().toLowerCase();
      final value = int.tryParse(part.substring(separator + 1).trim());
      if (value == null) continue;
      switch (key) {
        case 'upload':
          upload = value;
          matched = true;
        case 'download':
          download = value;
          matched = true;
        case 'total':
          total = value;
          matched = true;
        case 'expire':
          expire = value;
          matched = true;
      }
    }
    return matched
        ? SubscriptionUsage(
            upload: upload,
            download: download,
            total: total,
            expire: expire,
          )
        : null;
  }

  final int upload;
  final int download;
  final int total;

  /// Unix seconds; `0` means "no expiry reported".
  final int expire;

  int get used => upload + download;

  int get remaining => total <= 0 ? 0 : (total - used).clamp(0, total);

  /// `0.0`–`1.0`, or `null` when the subscription reports no quota.
  double? get usedFraction =>
      total <= 0 ? null : (used / total).clamp(0.0, 1.0);

  DateTime? get expiresAt => expire <= 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(
          expire * 1000,
          isUtc: true,
        ).toLocal();

  Map<String, dynamic> toJson() => <String, dynamic>{
    'upload': upload,
    'download': download,
    'total': total,
    'expire': expire,
  };

  Map<String, dynamic> toUpperJson() => <String, dynamic>{
    'Upload': upload,
    'Download': download,
    'Total': total,
    'Expire': expire,
  };

  SubscriptionUsage copyWith({
    int? upload,
    int? download,
    int? total,
    int? expire,
  }) => SubscriptionUsage(
    upload: upload ?? this.upload,
    download: download ?? this.download,
    total: total ?? this.total,
    expire: expire ?? this.expire,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubscriptionUsage &&
          other.upload == upload &&
          other.download == download &&
          other.total == total &&
          other.expire == expire;

  @override
  int get hashCode => Object.hash(upload, download, total, expire);

  @override
  String toString() => 'SubscriptionUsage($used/$total, expire=$expire)';
}

/// One configuration profile. Port of `IProfileItem`.
class ProfileItem {
  const ProfileItem({
    required this.id,
    required this.type,
    required this.name,
    this.url,
    this.updated,
    this.interval,
    this.autoUpdate = false,
    this.extra,
    this.home,
    this.userAgent,
    this.updateTimeout,
  });

  factory ProfileItem.fromJson(Map<String, dynamic> json) => ProfileItem(
    id: _asString(json['id']),
    type: _asString(json['type'], 'local'),
    name: _asString(json['name']),
    url: _asStringOrNull(json['url']),
    updated: _asIntOrNull(json['updated']),
    interval: _asIntOrNull(json['interval']),
    autoUpdate: _asBool(json['autoUpdate']),
    extra: json['extra'] is Map
        ? SubscriptionUsage.fromJson(_asMap(json['extra']))
        : null,
    home: _asStringOrNull(json['home']),
    userAgent: _asStringOrNull(json['userAgent']),
    updateTimeout: _asIntOrNull(json['updateTimeout']),
  );

  final String id;

  /// `remote` or `local`. The desktop's third value, `plugin`, is not ported —
  /// the `.cpx` plugin gateway is Windows-only.
  final String type;
  final String name;
  final String? url;

  /// Unix milliseconds of the last successful update.
  final int? updated;

  /// Auto-update period in minutes.
  final int? interval;
  final bool autoUpdate;
  final SubscriptionUsage? extra;

  /// The airport's web page, from the `profile-web-page-url` header.
  final String? home;
  final String? userAgent;

  /// Per-profile fetch timeout in seconds.
  final int? updateTimeout;

  bool get isRemote => type == 'remote';

  DateTime? get updatedAt => updated == null || updated! <= 0
      ? null
      : DateTime.fromMillisecondsSinceEpoch(updated!);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'type': type,
    'name': name,
    if (url != null) 'url': url,
    if (updated != null) 'updated': updated,
    if (interval != null) 'interval': interval,
    'autoUpdate': autoUpdate,
    if (extra != null) 'extra': extra!.toJson(),
    if (home != null) 'home': home,
    if (userAgent != null) 'userAgent': userAgent,
    if (updateTimeout != null) 'updateTimeout': updateTimeout,
  };

  ProfileItem copyWith({
    String? id,
    String? type,
    String? name,
    String? url,
    int? updated,
    int? interval,
    bool? autoUpdate,
    SubscriptionUsage? extra,
    String? home,
    String? userAgent,
    int? updateTimeout,
  }) => ProfileItem(
    id: id ?? this.id,
    type: type ?? this.type,
    name: name ?? this.name,
    url: url ?? this.url,
    updated: updated ?? this.updated,
    interval: interval ?? this.interval,
    autoUpdate: autoUpdate ?? this.autoUpdate,
    extra: extra ?? this.extra,
    home: home ?? this.home,
    userAgent: userAgent ?? this.userAgent,
    updateTimeout: updateTimeout ?? this.updateTimeout,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProfileItem &&
          other.id == id &&
          other.type == type &&
          other.name == name &&
          other.url == url &&
          other.updated == updated &&
          other.interval == interval &&
          other.autoUpdate == autoUpdate &&
          other.extra == extra &&
          other.home == home &&
          other.userAgent == userAgent &&
          other.updateTimeout == updateTimeout;

  @override
  int get hashCode => Object.hash(
    id,
    type,
    name,
    url,
    updated,
    interval,
    autoUpdate,
    extra,
    home,
    userAgent,
    updateTimeout,
  );

  @override
  String toString() => 'ProfileItem($id, $type, $name)';
}

// ---------------------------------------------------------------------------
// Core status
// ---------------------------------------------------------------------------

/// What the FAB and the dashboard render. [state] is authoritative; [error]
/// only ever accompanies [CoreState.failed].
class CoreStatus {
  const CoreStatus({
    required this.state,
    this.version,
    this.error,
    this.startedAt,
  });

  factory CoreStatus.fromJson(Map<String, dynamic> json) => CoreStatus(
    state: CoreState.fromWire(json['state']),
    version: _asStringOrNull(json['version']),
    error: _asStringOrNull(json['error']),
    startedAt: json['startedAt'] == null ? null : _asTime(json['startedAt']),
  );

  static const CoreStatus stopped = CoreStatus(state: CoreState.stopped);

  final CoreState state;

  /// The core's own version string; survives across stop/start.
  final String? version;
  final String? error;

  /// Set when [state] became [CoreState.running]; drives the FAB timer.
  final DateTime? startedAt;

  bool get isRunning => state == CoreState.running;

  bool get isBusy => state == CoreState.starting || state == CoreState.stopping;

  Duration? get uptime =>
      startedAt == null ? null : DateTime.now().difference(startedAt!);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'state': state.wireName,
    if (version != null) 'version': version,
    if (error != null) 'error': error,
    if (startedAt != null) 'startedAt': startedAt!.toUtc().toIso8601String(),
  };

  CoreStatus copyWith({
    CoreState? state,
    String? version,
    String? error,
    bool clearError = false,
    DateTime? startedAt,
    bool clearStartedAt = false,
  }) => CoreStatus(
    state: state ?? this.state,
    version: version ?? this.version,
    error: clearError ? null : (error ?? this.error),
    startedAt: clearStartedAt ? null : (startedAt ?? this.startedAt),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CoreStatus &&
          other.state == state &&
          other.version == version &&
          other.error == error &&
          other.startedAt == startedAt;

  @override
  int get hashCode => Object.hash(state, version, error, startedAt);

  @override
  String toString() =>
      'CoreStatus(${state.wireName}${error == null ? '' : ', $error'})';
}

/// One row of `installedApps()`, for the split-tunnel picker.
class InstalledApp {
  const InstalledApp({
    required this.packageName,
    required this.label,
    required this.isSystem,
  });

  factory InstalledApp.fromJson(Map<String, dynamic> json) => InstalledApp(
    packageName: _asString(json['packageName']),
    label: _asString(json['label']),
    isSystem: _asBool(json['isSystem']),
  );

  final String packageName;
  final String label;
  final bool isSystem;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'packageName': packageName,
    'label': label,
    'isSystem': isSystem,
  };

  InstalledApp copyWith({String? packageName, String? label, bool? isSystem}) =>
      InstalledApp(
        packageName: packageName ?? this.packageName,
        label: label ?? this.label,
        isSystem: isSystem ?? this.isSystem,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is InstalledApp &&
          other.packageName == packageName &&
          other.label == label &&
          other.isSystem == isSystem;

  @override
  int get hashCode => Object.hash(packageName, label, isSystem);
}

// ---------------------------------------------------------------------------
// Settings
// ---------------------------------------------------------------------------

/// The dashboard card keys, in the desktop's `DEFAULT_SIDER_ORDER` order minus
/// the cards that have no Android meaning (`sysproxy`, `tun`, `override`).
const List<String> kDefaultCardOrder = <String>[
  'network',
  'mode',
  'profile',
  'proxy',
  'connection',
  'usage',
  'mihomo',
  'rule',
  'dns',
  'sniff',
  'resource',
  'log',
];

const Map<String, CardStatus> _defaultCardStatus = <String, CardStatus>{
  'network': CardStatus.colSpan2,
  'mode': CardStatus.colSpan2,
  'profile': CardStatus.colSpan2,
  'proxy': CardStatus.colSpan1,
  'connection': CardStatus.colSpan1,
  'usage': CardStatus.colSpan2,
  'mihomo': CardStatus.colSpan1,
  'rule': CardStatus.colSpan1,
  'dns': CardStatus.colSpan1,
  'sniff': CardStatus.colSpan1,
  'resource': CardStatus.colSpan1,
  'log': CardStatus.colSpan1,
};

/// User settings. Persisted as JSON, written atomically, serialised through a
/// queue (N6). The Android-relevant subset of the desktop's `IAppConfig`.
class AppConfig {
  const AppConfig({
    this.appTheme = AppThemeMode.system,
    this.useDynamicColor = true,
    this.seedColor = 0xFF3B82F6,
    this.language,
    this.proxyDisplayMode = 'simple',
    this.proxyDisplayOrder = ProxySortOrder.byDefault,
    this.proxyCols = 'auto',
    this.hideUnavailableProxies = false,
    this.delayTestUrl = 'https://www.gstatic.com/generate_204',
    this.delayTestTimeout = 5000,
    this.delayTestConcurrency = 20,
    this.connectionOrderBy = 'time',
    this.connectionDirection = 'desc',
    this.autoCloseConnection = true,
    this.silentStart = false,
    this.ipv6 = false,
    this.logLevel = LogLevel.info,
    this.maxLogLines = 1000,
    this.userAgent,
    this.subscriptionTimeout = 30000,
    this.splitTunnelMode = SplitTunnelMode.off,
    this.splitTunnelPackages = const <String>[],
    this.allowLan = false,
    this.mixedPort = 17890,
    this.tunStack = 'mixed',
    this.autoRedirect = false,
    this.cardOrder = kDefaultCardOrder,
    this.cardStatus = _defaultCardStatus,
  });

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final rawStatus = _asMap(json['cardStatus']);
    final order = _asStringList(json['cardOrder']);
    return AppConfig(
      appTheme: AppThemeMode.fromWire(json['appTheme']),
      useDynamicColor: _asBool(json['useDynamicColor'], true),
      seedColor: _asInt(json['seedColor'], 0xFF3B82F6),
      language: _asStringOrNull(json['language']),
      proxyDisplayMode: _asString(json['proxyDisplayMode'], 'simple'),
      proxyDisplayOrder: ProxySortOrder.fromWire(json['proxyDisplayOrder']),
      proxyCols: _asString(json['proxyCols'], 'auto'),
      hideUnavailableProxies: _asBool(json['hideUnavailableProxies']),
      delayTestUrl: _asString(
        json['delayTestUrl'],
        'https://www.gstatic.com/generate_204',
      ),
      delayTestTimeout: _asInt(json['delayTestTimeout'], 5000),
      delayTestConcurrency: _asInt(json['delayTestConcurrency'], 20),
      connectionOrderBy: _asString(json['connectionOrderBy'], 'time'),
      connectionDirection: _asString(json['connectionDirection'], 'desc'),
      autoCloseConnection: _asBool(json['autoCloseConnection'], true),
      silentStart: _asBool(json['silentStart']),
      ipv6: _asBool(json['ipv6']),
      logLevel: LogLevel.fromWire(json['logLevel']),
      maxLogLines: _asInt(json['maxLogLines'], 1000),
      userAgent: _asStringOrNull(json['userAgent']),
      subscriptionTimeout: _asInt(json['subscriptionTimeout'], 30000),
      splitTunnelMode: SplitTunnelMode.fromWire(json['splitTunnelMode']),
      splitTunnelPackages: _asStringList(json['splitTunnelPackages']),
      allowLan: _asBool(json['allowLan']),
      mixedPort: _asInt(json['mixedPort'], 17890),
      tunStack: _asString(json['tunStack'], 'mixed'),
      autoRedirect: _asBool(json['autoRedirect']),
      cardOrder: order.isEmpty
          ? kDefaultCardOrder
          : List<String>.unmodifiable(order),
      cardStatus: rawStatus.isEmpty
          ? _defaultCardStatus
          : Map<String, CardStatus>.unmodifiable(<String, CardStatus>{
              ..._defaultCardStatus,
              for (final entry in rawStatus.entries)
                entry.key: CardStatus.fromWire(entry.value),
            }),
    );
  }

  static const AppConfig defaults = AppConfig();

  final AppThemeMode appTheme;
  final bool useDynamicColor;
  final int seedColor;

  /// One of `zh-CN`, `zh-TW`, `en-US`, `ru-RU`, `fa-IR`; `null` follows the OS.
  final String? language;
  final String proxyDisplayMode;
  final ProxySortOrder proxyDisplayOrder;
  final String proxyCols;
  final bool hideUnavailableProxies;
  final String delayTestUrl;
  final int delayTestTimeout;
  final int delayTestConcurrency;
  final String connectionOrderBy;
  final String connectionDirection;
  final bool autoCloseConnection;
  final bool silentStart;
  final bool ipv6;
  final LogLevel logLevel;
  final int maxLogLines;
  final String? userAgent;
  final int subscriptionTimeout;
  final SplitTunnelMode splitTunnelMode;
  final List<String> splitTunnelPackages;
  final bool allowLan;
  final int mixedPort;
  final String tunStack;

  /// Android-only sing-box tun option; off by default because it needs root on
  /// some ROMs and silently degrades on others.
  final bool autoRedirect;
  final List<String> cardOrder;
  final Map<String, CardStatus> cardStatus;

  CardStatus statusOfCard(String key) =>
      cardStatus[key] ?? _defaultCardStatus[key] ?? CardStatus.colSpan1;

  /// Packages passed to `start()` as the allow-list, per [splitTunnelMode].
  List<String> get includePackages => splitTunnelMode == SplitTunnelMode.allow
      ? splitTunnelPackages
      : const <String>[];

  /// Packages passed to `start()` as the deny-list, per [splitTunnelMode].
  List<String> get excludePackages => splitTunnelMode == SplitTunnelMode.deny
      ? splitTunnelPackages
      : const <String>[];

  Map<String, dynamic> toJson() => <String, dynamic>{
    'appTheme': appTheme.wireName,
    'useDynamicColor': useDynamicColor,
    'seedColor': seedColor,
    if (language != null) 'language': language,
    'proxyDisplayMode': proxyDisplayMode,
    'proxyDisplayOrder': proxyDisplayOrder.wireName,
    'proxyCols': proxyCols,
    'hideUnavailableProxies': hideUnavailableProxies,
    'delayTestUrl': delayTestUrl,
    'delayTestTimeout': delayTestTimeout,
    'delayTestConcurrency': delayTestConcurrency,
    'connectionOrderBy': connectionOrderBy,
    'connectionDirection': connectionDirection,
    'autoCloseConnection': autoCloseConnection,
    'silentStart': silentStart,
    'ipv6': ipv6,
    'logLevel': logLevel.wireName,
    'maxLogLines': maxLogLines,
    if (userAgent != null) 'userAgent': userAgent,
    'subscriptionTimeout': subscriptionTimeout,
    'splitTunnelMode': splitTunnelMode.wireName,
    'splitTunnelPackages': splitTunnelPackages,
    'allowLan': allowLan,
    'mixedPort': mixedPort,
    'tunStack': tunStack,
    'autoRedirect': autoRedirect,
    'cardOrder': cardOrder,
    'cardStatus': <String, dynamic>{
      for (final entry in cardStatus.entries) entry.key: entry.value.wireName,
    },
  };

  AppConfig copyWith({
    AppThemeMode? appTheme,
    bool? useDynamicColor,
    int? seedColor,
    String? language,
    bool clearLanguage = false,
    String? proxyDisplayMode,
    ProxySortOrder? proxyDisplayOrder,
    String? proxyCols,
    bool? hideUnavailableProxies,
    String? delayTestUrl,
    int? delayTestTimeout,
    int? delayTestConcurrency,
    String? connectionOrderBy,
    String? connectionDirection,
    bool? autoCloseConnection,
    bool? silentStart,
    bool? ipv6,
    LogLevel? logLevel,
    int? maxLogLines,
    String? userAgent,
    int? subscriptionTimeout,
    SplitTunnelMode? splitTunnelMode,
    List<String>? splitTunnelPackages,
    bool? allowLan,
    int? mixedPort,
    String? tunStack,
    bool? autoRedirect,
    List<String>? cardOrder,
    Map<String, CardStatus>? cardStatus,
  }) => AppConfig(
    appTheme: appTheme ?? this.appTheme,
    useDynamicColor: useDynamicColor ?? this.useDynamicColor,
    seedColor: seedColor ?? this.seedColor,
    language: clearLanguage ? null : (language ?? this.language),
    proxyDisplayMode: proxyDisplayMode ?? this.proxyDisplayMode,
    proxyDisplayOrder: proxyDisplayOrder ?? this.proxyDisplayOrder,
    proxyCols: proxyCols ?? this.proxyCols,
    hideUnavailableProxies:
        hideUnavailableProxies ?? this.hideUnavailableProxies,
    delayTestUrl: delayTestUrl ?? this.delayTestUrl,
    delayTestTimeout: delayTestTimeout ?? this.delayTestTimeout,
    delayTestConcurrency: delayTestConcurrency ?? this.delayTestConcurrency,
    connectionOrderBy: connectionOrderBy ?? this.connectionOrderBy,
    connectionDirection: connectionDirection ?? this.connectionDirection,
    autoCloseConnection: autoCloseConnection ?? this.autoCloseConnection,
    silentStart: silentStart ?? this.silentStart,
    ipv6: ipv6 ?? this.ipv6,
    logLevel: logLevel ?? this.logLevel,
    maxLogLines: maxLogLines ?? this.maxLogLines,
    userAgent: userAgent ?? this.userAgent,
    subscriptionTimeout: subscriptionTimeout ?? this.subscriptionTimeout,
    splitTunnelMode: splitTunnelMode ?? this.splitTunnelMode,
    splitTunnelPackages: splitTunnelPackages ?? this.splitTunnelPackages,
    allowLan: allowLan ?? this.allowLan,
    mixedPort: mixedPort ?? this.mixedPort,
    tunStack: tunStack ?? this.tunStack,
    autoRedirect: autoRedirect ?? this.autoRedirect,
    cardOrder: cardOrder ?? this.cardOrder,
    cardStatus: cardStatus ?? this.cardStatus,
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppConfig && _deep.equals(other.toJson(), toJson());

  @override
  int get hashCode => _deep.hash(toJson());
}
