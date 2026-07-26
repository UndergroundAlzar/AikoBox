import 'package:aikobox_mobile/core/models.dart';
import 'package:aikobox_mobile/features/profiles/widgets/profile_card.dart';
import 'package:aikobox_mobile/features/profiles/widgets/subscription_usage_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import '../harness.dart';

ProfileItem _remote({
  String name = 'HK Nodes',
  SubscriptionUsage? extra,
  bool autoUpdate = false,
  int? updated,
  String? home,
}) => ProfileItem(
  id: 'p1',
  type: 'remote',
  name: name,
  url: 'https://example.com/sub?token=secret',
  extra: extra,
  autoUpdate: autoUpdate,
  updated: updated,
  home: home,
);

void main() {
  late Map<String, String> en;
  late ProviderContainer container;

  setUpAll(() => en = loadLocaleStrings());

  setUp(() {
    container = ProviderContainer();
    addTearDown(container.dispose);
  });

  Future<void> pumpCard(
    WidgetTester tester,
    Widget card, {
    Size surface = const Size(400, 800),
  }) => pumpPage(
    tester,
    Scaffold(
      body: Padding(padding: const EdgeInsets.all(8), child: card),
    ),
    container: container,
    surface: surface,
  );

  testWidgets('shows the name and the remote tag', (tester) async {
    await pumpCard(
      tester,
      ProfileCard(
        item: _remote(),
        isCurrent: false,
        onSelect: () {},
        onAction: (_) {},
      ),
    );

    expect(find.text('HK Nodes'), findsOneWidget);
    expect(find.text(en['profiles.remote']!), findsOneWidget);
    expect(find.text(en['profiles.local']!), findsNothing);
    expect(find.text(en['profiles.current']!), findsNothing);
  });

  testWidgets('the current profile is marked and cannot be re-selected', (
    tester,
  ) async {
    var selected = 0;
    await pumpCard(
      tester,
      ProfileCard(
        item: _remote(),
        isCurrent: true,
        onSelect: () => selected++,
        onAction: (_) {},
      ),
    );

    expect(find.text(en['profiles.current']!), findsOneWidget);
    await tester.tap(find.text('HK Nodes'));
    await tester.pumpAndSettle();
    expect(selected, 0);
  });

  testWidgets('tapping a non-current card selects it', (tester) async {
    var selected = 0;
    await pumpCard(
      tester,
      ProfileCard(
        item: _remote(),
        isCurrent: false,
        onSelect: () => selected++,
        onAction: (_) {},
      ),
    );

    await tester.tap(find.text('HK Nodes'));
    await tester.pumpAndSettle();
    expect(selected, 1);
  });

  testWidgets('a local profile offers no refresh', (tester) async {
    await pumpCard(
      tester,
      ProfileCard(
        item: const ProfileItem(id: 'p2', type: 'local', name: 'Hand written'),
        isCurrent: false,
        onSelect: () {},
        onAction: (_) {},
      ),
    );

    expect(find.text(en['profiles.local']!), findsOneWidget);
    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
  });

  testWidgets('refresh reports the action', (tester) async {
    final actions = <ProfileCardAction>[];
    await pumpCard(
      tester,
      ProfileCard(
        item: _remote(),
        isCurrent: false,
        onSelect: () {},
        onAction: actions.add,
      ),
    );

    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.pumpAndSettle();
    expect(actions, <ProfileCardAction>[ProfileCardAction.refresh]);
  });

  testWidgets('a refresh in flight shows a spinner instead of the icon', (
    tester,
  ) async {
    // Not `pumpPage`: a spinner never stops animating, so `pumpAndSettle`
    // would time out rather than settle.
    await tester.pumpWidget(
      hostPage(
        Scaffold(
          body: ProfileCard(
            item: _remote(),
            isCurrent: false,
            isRefreshing: true,
            onSelect: () {},
            onAction: (_) {},
          ),
        ),
        container: container,
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byIcon(Icons.refresh_rounded), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });

  testWidgets('while busy nothing can be pressed', (tester) async {
    var selected = 0;
    final actions = <ProfileCardAction>[];
    await pumpCard(
      tester,
      ProfileCard(
        item: _remote(),
        isCurrent: false,
        isBusy: true,
        onSelect: () => selected++,
        onAction: actions.add,
      ),
    );

    await tester.tap(find.text('HK Nodes'));
    await tester.tap(find.byIcon(Icons.refresh_rounded));
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(selected, 0);
    expect(actions, isEmpty);
  });

  testWidgets('a subscription with a quota shows the usage meter', (
    tester,
  ) async {
    await pumpCard(
      tester,
      ProfileCard(
        item: _remote(
          extra: const SubscriptionUsage(
            upload: 512 * 1024 * 1024,
            download: 512 * 1024 * 1024,
            total: 4 * 1024 * 1024 * 1024,
            expire: 0,
          ),
        ),
        isCurrent: false,
        onSelect: () {},
        onAction: (_) {},
      ),
    );

    expect(find.byType(SubscriptionUsageBar), findsOneWidget);
    expect(find.textContaining('1.00 GB'), findsOneWidget);
    expect(find.textContaining('4.00 GB'), findsOneWidget);
    expect(find.text(en['profiles.neverExpire']!), findsOneWidget);
  });

  testWidgets('an unlimited subscription is not shown as fully used', (
    tester,
  ) async {
    await pumpCard(
      tester,
      ProfileCard(
        item: _remote(
          extra: const SubscriptionUsage(
            upload: 1024,
            download: 1024,
            total: 0,
            expire: 0,
          ),
        ),
        isCurrent: false,
        onSelect: () {},
        onAction: (_) {},
      ),
    );

    expect(
      find.textContaining(en['profiles.traffic.unlimited']!),
      findsOneWidget,
    );
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, 0);
  });

  testWidgets('an expired subscription says so', (tester) async {
    await pumpCard(
      tester,
      ProfileCard(
        item: _remote(
          extra: SubscriptionUsage(
            upload: 0,
            download: 0,
            total: 1024,
            expire:
                DateTime.now()
                    .subtract(const Duration(days: 2))
                    .millisecondsSinceEpoch ~/
                1000,
          ),
        ),
        isCurrent: false,
        onSelect: () {},
        onAction: (_) {},
      ),
    );

    expect(find.text(en['profiles.traffic.expired']!), findsOneWidget);
  });

  testWidgets('an override is advertised on the card', (tester) async {
    await pumpCard(
      tester,
      ProfileCard(
        item: _remote(autoUpdate: true),
        isCurrent: false,
        hasOverride: true,
        onSelect: () {},
        onAction: (_) {},
      ),
    );

    expect(find.text(en['profiles.editFile.override']!), findsOneWidget);
    expect(find.text(en['profiles.editInfo.autoUpdate']!), findsOneWidget);
  });

  testWidgets('the overflow menu offers the editors and delete', (
    tester,
  ) async {
    final actions = <ProfileCardAction>[];
    await pumpCard(
      tester,
      ProfileCard(
        item: _remote(),
        isCurrent: false,
        onSelect: () {},
        onAction: actions.add,
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();

    expect(find.text(en['profiles.editInfo.title']!), findsOneWidget);
    expect(find.text(en['profiles.editFile.title']!), findsOneWidget);
    expect(find.text(en['profiles.editRules.title']!), findsOneWidget);
    expect(find.text(en['profiles.qrCode.show']!), findsOneWidget);
    // No home page URL on this item, so no "Home" row.
    expect(find.text(en['profiles.home']!), findsNothing);

    await tester.tap(find.text(en['profiles.editRules.title']!));
    await tester.pumpAndSettle();
    expect(actions, <ProfileCardAction>[ProfileCardAction.editRules]);
  });

  testWidgets('a local profile is offered no QR code', (tester) async {
    await pumpCard(
      tester,
      ProfileCard(
        item: const ProfileItem(id: 'p2', type: 'local', name: 'Hand written'),
        isCurrent: false,
        onSelect: () {},
        onAction: (_) {},
      ),
    );

    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    expect(find.text(en['profiles.qrCode.show']!), findsNothing);
  });

  testWidgets('the URL never reaches the card', (tester) async {
    await pumpCard(
      tester,
      ProfileCard(
        item: _remote(),
        isCurrent: false,
        onSelect: () {},
        onAction: (_) {},
      ),
    );

    // The subscription token is a credential; the list is not the place for it.
    expect(find.textContaining('token=secret'), findsNothing);
    expect(find.textContaining('example.com'), findsNothing);
  });
}
