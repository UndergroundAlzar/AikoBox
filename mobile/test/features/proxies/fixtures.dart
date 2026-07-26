/// Shared fixtures for the proxies-page tests.
library;

import 'package:aikobox_mobile/core/models.dart';

/// A leaf outbound.
///
/// [delay] is the latest successful measurement. Pass `failed: true` for a node
/// that has been probed and did not answer — that is history with a zero
/// sample and a null delay, which is exactly what `ProxyNode.fromJson` builds
/// out of the core's response.
ProxyNode node(
  String name, {
  int? delay,
  bool failed = false,
  String type = 'Shadowsocks',
  bool udp = false,
}) {
  final history = <DelaySample>[
    if (failed) DelaySample(time: DateTime.utc(2026), delay: 0),
    if (delay != null) DelaySample(time: DateTime.utc(2026), delay: delay),
  ];
  return ProxyNode(
    name: name,
    type: type,
    udp: udp,
    delay: delay,
    history: history,
  );
}

/// Named `proxyGroup` rather than `group` so it does not shadow
/// `flutter_test`'s test grouping function.
ProxyGroup proxyGroup(
  String name, {
  required List<String> members,
  String type = 'Selector',
  String now = '',
  String? testUrl,
  bool hidden = false,
}) => ProxyGroup(
  name: name,
  type: type,
  now: now.isEmpty ? (members.isEmpty ? '' : members.first) : now,
  all: members,
  hidden: hidden,
  testUrl: testUrl,
);

/// Builds a snapshot the way `parseProxiesResponse` does: every group is also
/// present in the node table, because a group can be a member of another group.
///
/// An explicit entry in [nodes] wins over the synthesised one, so a test can
/// give a nested group its own delay history.
ProxiesSnapshot snapshotOf({
  required List<ProxyGroup> groups,
  required List<ProxyNode> nodes,
}) => ProxiesSnapshot(
  groups: groups,
  nodes: <String, ProxyNode>{
    for (final g in groups) g.name: ProxyNode(name: g.name, type: g.type),
    for (final n in nodes) n.name: n,
  },
);
