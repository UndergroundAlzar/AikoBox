import 'package:aikobox_mobile/core/models.dart';
import 'package:aikobox_mobile/features/proxies/proxies_prefs.dart';
import 'package:aikobox_mobile/features/proxies/proxy_layout.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  group('proxyColumnsForWidth', () {
    test('is max((width / 250).ceil(), 2) at the standard layout', () {
      expect(proxyColumnsForWidth(200), 2);
      expect(proxyColumnsForWidth(360), 2);
      expect(proxyColumnsForWidth(500), 2);
      expect(proxyColumnsForWidth(501), 3);
      expect(proxyColumnsForWidth(1000), 4);
    });

    test('layout nudges the count by one either way', () {
      expect(proxyColumnsForWidth(600, layout: ProxiesLayout.loose), 2);
      expect(proxyColumnsForWidth(600, layout: ProxiesLayout.standard), 3);
      expect(proxyColumnsForWidth(600, layout: ProxiesLayout.tight), 4);
    });

    test('never drops below one column', () {
      expect(proxyColumnsForWidth(100, layout: ProxiesLayout.loose), 1);
      expect(proxyColumnsForWidth(0, layout: ProxiesLayout.loose), 1);
      expect(proxyColumnsForWidth(double.infinity), 2);
    });

    test('an explicit column count wins over width and layout', () {
      expect(
        proxyColumnsForWidth(1600, proxyCols: '2', layout: ProxiesLayout.tight),
        2,
      );
      expect(proxyColumnsForWidth(200, proxyCols: '4'), 4);
      expect(proxyColumnsForWidth(200, proxyCols: '0'), 1);
      expect(proxyColumnsForWidth(600, proxyCols: 'auto'), 3);
    });
  });

  group('proxyCardHeight', () {
    const textTheme = TextTheme(
      bodyMedium: TextStyle(fontSize: 14, height: 1.5),
      bodySmall: TextStyle(fontSize: 12, height: 1.5),
      labelSmall: TextStyle(fontSize: 11, height: 1.5),
    );

    double heightFor(ProxyCardDensity density, {TextScaler? scaler}) =>
        proxyCardHeight(
          textTheme: textTheme,
          density: density,
          textScaler: scaler ?? TextScaler.noScaling,
        );

    test('expand > shrink > min', () {
      expect(
        heightFor(ProxyCardDensity.expand),
        greaterThan(heightFor(ProxyCardDensity.shrink)),
      );
      expect(
        heightFor(ProxyCardDensity.shrink),
        greaterThan(heightFor(ProxyCardDensity.min)),
      );
    });

    test('follows FlClash: base is 16 + 2 body + small + 12', () {
      // 16 + 21*2 + 18 + 8 + 4
      expect(heightFor(ProxyCardDensity.shrink), 88);
      // base + labelSmall(16.5) + 6
      expect(heightFor(ProxyCardDensity.expand), closeTo(110.5, 0.01));
      // base - one body line
      expect(heightFor(ProxyCardDensity.min), 67);
    });

    test('grows with the platform text scale', () {
      expect(
        heightFor(ProxyCardDensity.shrink, scaler: const TextScaler.linear(2)),
        greaterThan(heightFor(ProxyCardDensity.shrink)),
      );
    });

    test('never returns less than the minimum touch-sized cell', () {
      final tiny = proxyCardHeight(
        textTheme: const TextTheme(
          bodyMedium: TextStyle(fontSize: 1, height: 1),
          bodySmall: TextStyle(fontSize: 1, height: 1),
          labelSmall: TextStyle(fontSize: 1, height: 1),
        ),
        density: ProxyCardDensity.min,
      );
      expect(tiny, kProxyCardMinHeight);
    });
  });

  group('scroll offsets', () {
    const itemHeight = 100.0;

    test('a grid of n items is rows * height + gutters', () {
      expect(
        proxyGroupGridHeight(itemCount: 4, columns: 2, itemHeight: itemHeight),
        208, // 2 rows + 1 gutter
      );
      expect(
        proxyGroupGridHeight(itemCount: 0, columns: 2, itemHeight: itemHeight),
        0,
      );
      expect(
        proxyGroupGridHeight(itemCount: 3, columns: 2, itemHeight: itemHeight),
        208, // still 2 rows
      );
    });

    test('the first node of the first group sits under its header', () {
      final offset = proxyListScrollOffset(
        groups: const <ProxyGroupExtent>[
          ProxyGroupExtent(itemCount: 10, expanded: true),
        ],
        groupIndex: 0,
        itemIndex: 0,
        columns: 2,
        itemHeight: itemHeight,
      );
      expect(offset, 16 + kProxyGroupHeaderHeight);
    });

    test('a later row adds whole rows plus gutters', () {
      final offset = proxyListScrollOffset(
        groups: const <ProxyGroupExtent>[
          ProxyGroupExtent(itemCount: 10, expanded: true),
        ],
        groupIndex: 0,
        itemIndex: 4,
        columns: 2,
        itemHeight: itemHeight,
      );
      // 16 + header + gap + 2 full rows
      expect(offset, 16 + kProxyGroupHeaderHeight + 8 + 2 * (itemHeight + 8));
    });

    test('an expanded group above shifts everything below it', () {
      const groups = <ProxyGroupExtent>[
        ProxyGroupExtent(itemCount: 4, expanded: true),
        ProxyGroupExtent(itemCount: 4, expanded: false),
        ProxyGroupExtent(itemCount: 4, expanded: true),
      ];
      final first = proxyListScrollOffset(
        groups: groups,
        groupIndex: 2,
        itemIndex: 0,
        columns: 2,
        itemHeight: itemHeight,
      );
      // group 0: header + gap + 208 + groupGap; group 1: header + groupGap
      const block0 = kProxyGroupHeaderHeight + 8 + 208 + kProxyGroupGap;
      const block1 = kProxyGroupHeaderHeight + kProxyGroupGap;
      expect(first, 16 + block0 + block1 + kProxyGroupHeaderHeight);
    });

    test('an out-of-range group index scrolls nowhere', () {
      expect(
        proxyListScrollOffset(
          groups: const <ProxyGroupExtent>[],
          groupIndex: 0,
          itemIndex: 0,
          columns: 2,
          itemHeight: itemHeight,
        ),
        0,
      );
    });

    test('the tab grid offset is whole rows from the top', () {
      expect(
        proxyGridScrollOffset(
          itemIndex: 0,
          columns: 3,
          itemHeight: itemHeight,
          topPadding: 8,
        ),
        0,
      );
      expect(
        proxyGridScrollOffset(
          itemIndex: 7,
          columns: 3,
          itemHeight: itemHeight,
          topPadding: 8,
        ),
        8 + 2 * (itemHeight + 8),
      );
    });
  });

  group('visibleProxyNodes', () {
    final snapshot = snapshotOf(
      groups: <ProxyGroup>[
        proxyGroup(
          'Proxy',
          members: <String>[
            'HK 01',
            'hk 10',
            'JP 02',
            'Dead',
            'Untested',
            'Nested',
          ],
          now: 'HK 01',
        ),
        proxyGroup('Nested', members: <String>['JP 02'], type: 'URLTest'),
        proxyGroup('Hidden', members: <String>['JP 02'], hidden: true),
        proxyGroup('Empty', members: <String>[]),
      ],
      nodes: <ProxyNode>[
        node('HK 01', delay: 120),
        node('hk 10', delay: 40),
        node('JP 02', delay: 900),
        node('Dead', failed: true),
        node('Untested'),
        // The nested group has itself been probed and failed.
        node('Nested', failed: true, type: 'URLTest'),
      ],
    );

    ProxyGroup parentGroup() => snapshot.groupNamed('Proxy')!;

    test('returns every member in declaration order by default', () {
      final views = visibleProxyNodes(snapshot: snapshot, group: parentGroup());
      expect(views.map((v) => v.name), <String>[
        'HK 01',
        'hk 10',
        'JP 02',
        'Dead',
        'Untested',
        'Nested',
      ]);
    });

    test('marks nested groups so they survive hide-unavailable', () {
      final views = visibleProxyNodes(
        snapshot: snapshot,
        group: parentGroup(),
        hideUnavailable: true,
      );
      expect(
        views.map((v) => v.name),
        <String>['HK 01', 'hk 10', 'JP 02', 'Untested', 'Nested'],
        reason: 'a failed leaf goes; a failed group and an untested leaf stay',
      );
      expect(views.firstWhere((v) => v.name == 'Nested').isGroup, isTrue);
    });

    test('search is case-insensitive and trims', () {
      final views = visibleProxyNodes(
        snapshot: snapshot,
        group: parentGroup(),
        query: '  hk ',
      );
      expect(views.map((v) => v.name), <String>['HK 01', 'hk 10']);
    });

    test('a session measurement overrides the core history', () {
      final views = visibleProxyNodes(
        snapshot: snapshot,
        group: parentGroup(),
        delayOverrides: const <String, int?>{'HK 01': 33, 'hk 10': null},
      );
      final byName = <String, ProxyNodeView>{for (final v in views) v.name: v};
      expect(byName['HK 01']!.delay, 33);
      expect(byName['hk 10']!.delay, isNull);
      expect(
        byName['hk 10']!.failed,
        isTrue,
        reason: 'an override present with a null value is a measured failure',
      );
    });

    test('an override of null hides the node under hide-unavailable', () {
      final views = visibleProxyNodes(
        snapshot: snapshot,
        group: parentGroup(),
        hideUnavailable: true,
        delayOverrides: const <String, int?>{'HK 01': null},
      );
      expect(views.map((v) => v.name), isNot(contains('HK 01')));
    });

    test('sorts fastest first, then failures, then never-measured', () {
      final views = visibleProxyNodes(
        snapshot: snapshot,
        group: parentGroup(),
        sort: ProxySortOrder.byDelay,
      );
      expect(views.map((v) => v.name), <String>[
        'hk 10',
        'HK 01',
        'JP 02',
        'Dead',
        'Nested',
        'Untested',
      ]);
    });

    test('sorts by name naturally, so HK 2 precedes HK 10', () {
      final numbered = snapshotOf(
        groups: <ProxyGroup>[
          proxyGroup('G', members: <String>['HK 10', 'HK 2', 'AU 1']),
        ],
        nodes: <ProxyNode>[node('HK 10'), node('HK 2'), node('AU 1')],
      );
      final views = visibleProxyNodes(
        snapshot: numbered,
        group: numbered.groupNamed('G')!,
        sort: ProxySortOrder.byName,
      );
      expect(views.map((v) => v.name), <String>['AU 1', 'HK 2', 'HK 10']);
    });

    test('a delay sort keeps equal elements in their original order', () {
      final tied = snapshotOf(
        groups: <ProxyGroup>[
          proxyGroup('G', members: <String>['a', 'b', 'c']),
        ],
        nodes: <ProxyNode>[
          node('a', delay: 50),
          node('b', delay: 50),
          node('c', delay: 50),
        ],
      );
      final views = visibleProxyNodes(
        snapshot: tied,
        group: tied.groupNamed('G')!,
        sort: ProxySortOrder.byDelay,
      );
      expect(views.map((v) => v.name), <String>['a', 'b', 'c']);
    });
  });

  group('group and current-node lookup', () {
    final snapshot = snapshotOf(
      groups: <ProxyGroup>[
        proxyGroup('Proxy', members: <String>['A', 'B'], now: 'B'),
        proxyGroup('Hidden', members: <String>['A'], hidden: true),
        proxyGroup('Empty', members: <String>[]),
      ],
      nodes: <ProxyNode>[node('A'), node('B')],
    );

    test('hidden and memberless groups never reach the page', () {
      expect(visibleProxyGroups(snapshot).map((g) => g.name), <String>[
        'Proxy',
      ]);
    });

    test('global mode hoists GLOBAL to the front, other modes leave it', () {
      final withGlobal = snapshotOf(
        groups: <ProxyGroup>[
          proxyGroup('Proxy', members: <String>['A']),
          proxyGroup('Auto', members: <String>['A']),
          proxyGroup('GLOBAL', members: <String>['A']),
        ],
        nodes: <ProxyNode>[node('A')],
      );

      expect(visibleProxyGroups(withGlobal).map((g) => g.name), <String>[
        'Proxy',
        'Auto',
        'GLOBAL',
      ]);
      expect(
        visibleProxyGroups(
          withGlobal,
          mode: OutboundMode.global,
        ).map((g) => g.name),
        <String>['GLOBAL', 'Proxy', 'Auto'],
      );
    });

    test(
      'indexOfCurrentNode finds the pick, or -1 once it is filtered out',
      () {
        final proxy = snapshot.groupNamed('Proxy')!;
        final all = visibleProxyNodes(snapshot: snapshot, group: proxy);
        expect(indexOfCurrentNode(all, proxy), 1);

        final filtered = visibleProxyNodes(
          snapshot: snapshot,
          group: proxy,
          query: 'A',
        );
        expect(indexOfCurrentNode(filtered, proxy), -1);
      },
    );
  });
}
