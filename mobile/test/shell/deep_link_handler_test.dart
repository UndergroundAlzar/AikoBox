import 'dart:async';

import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/shell/deep_link_handler.dart';
import 'package:aikobox_mobile/features/shell/shell_destination.dart';
import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'shell_harness.dart';

const Map<String, String> _strings = <String, String>{
  'profiles.deepLink.title': 'Import this subscription?',
  'profiles.deepLink.message': '{host} wants to add a subscription.',
  'profiles.import': 'Import',
  'profiles.updating': 'Updating…',
  'profiles.notification.importSuccess': 'Subscription imported successfully',
  'profiles.error.importFailed': 'Subscription import failed',
  'profiles.error.urlParamMissing': 'Missing parameter: url',
  'common.cancel': 'Cancel',
};

/// `AppLinks` is a singleton with a private constructor, so the fake
/// implements the interface rather than extending it.
class FakeAppLinks implements AppLinks {
  FakeAppLinks({this.initial});

  final String? initial;
  final StreamController<String> _strings =
      StreamController<String>.broadcast();

  void emit(String link) => _strings.add(link);

  @override
  Stream<String> get stringLinkStream => _strings.stream;

  @override
  Stream<Uri> get uriLinkStream =>
      _strings.stream.map(Uri.parse).handleError((Object _) {});

  @override
  Future<String?> getInitialLinkString() async => initial;

  @override
  Future<Uri?> getInitialLink() async =>
      initial == null ? null : Uri.tryParse(initial!);

  @override
  Future<String?> getLatestLinkString() async => initial;

  @override
  Future<Uri?> getLatestLink() async =>
      initial == null ? null : Uri.tryParse(initial!);
}

/// Records what the deep-link gate asked the profile store to do.
class RecordingProfiles extends ProfilesNotifier {
  final List<String> importedUrls = <String>[];
  final List<String?> importedNames = <String?>[];
  Object? failWith;

  @override
  Future<List<ProfileItem>> build() async => const <ProfileItem>[];

  @override
  Future<ProfileItem> importRemote({
    required String url,
    String? name,
    String? authToken,
    bool autoUpdate = false,
    int? intervalMinutes,
  }) async {
    importedUrls.add(url);
    importedNames.add(name);
    final Object? failure = failWith;
    if (failure != null) throw failure;
    return ProfileItem(id: 'p1', type: 'remote', name: name ?? 'sub', url: url);
  }
}

String installConfig(String target, {String? name}) {
  final StringBuffer buffer = StringBuffer(
    'aikobox://install-config?url=${Uri.encodeComponent(target)}',
  );
  if (name != null) buffer.write('&name=${Uri.encodeComponent(name)}');
  return buffer.toString();
}

void main() {
  const String target = 'https://airport.example/sub?token=super-secret';

  late RecordingProfiles profiles;
  late ProviderContainer container;

  setUp(() {
    profiles = RecordingProfiles();
    container = ProviderContainer(
      overrides: [profilesProvider.overrideWith(() => profiles)],
    );
    addTearDown(container.dispose);
  });

  Future<FakeAppLinks> pumpListener(
    WidgetTester tester, {
    String? initial,
  }) async {
    final FakeAppLinks links = FakeAppLinks(initial: initial);
    await tester.pumpWidget(
      hostShell(
        DeepLinkListener(
          links: links,
          child: const Scaffold(body: SizedBox.expand()),
        ),
        strings: _strings,
        container: container,
      ),
    );
    await tester.pumpAndSettle();
    return links;
  }

  testWidgets('a launch link asks before it imports', (
    WidgetTester tester,
  ) async {
    await pumpListener(tester, initial: installConfig(target));

    expect(find.text('Import this subscription?'), findsOneWidget);
    expect(
      profiles.importedUrls,
      isEmpty,
      reason: 'nothing may be fetched before the user answers',
    );
  });

  testWidgets('the sheet names the host and nothing else', (
    WidgetTester tester,
  ) async {
    await pumpListener(tester, initial: installConfig(target));

    expect(
      find.text('airport.example wants to add a subscription.'),
      findsOneWidget,
    );
    expect(find.textContaining('super-secret'), findsNothing);
    expect(find.textContaining('/sub'), findsNothing);
  });

  testWidgets('cancelling imports nothing', (WidgetTester tester) async {
    await pumpListener(tester, initial: installConfig(target));

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(profiles.importedUrls, isEmpty);
    expect(container.read(shellTabProvider), kShellDashboardTab);
  });

  testWidgets('dismissing the sheet counts as cancelling', (
    WidgetTester tester,
  ) async {
    await pumpListener(tester, initial: installConfig(target));

    // Tap the scrim above the sheet.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(find.text('Import this subscription?'), findsNothing);
    expect(profiles.importedUrls, isEmpty);
  });

  testWidgets('confirming imports the full URL and opens Profiles', (
    WidgetTester tester,
  ) async {
    await pumpListener(
      tester,
      initial: installConfig(target, name: 'My provider'),
    );

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(profiles.importedUrls, <String>[target]);
    expect(profiles.importedNames, <String?>['My provider']);
    expect(find.text('Subscription imported successfully'), findsOneWidget);
    expect(container.read(shellTabProvider), kShellProfilesTab);
  });

  testWidgets('a failed import never echoes the link', (
    WidgetTester tester,
  ) async {
    profiles.failWith = StateError('GET $target failed');
    await pumpListener(tester, initial: installConfig(target));

    await tester.tap(find.text('Import'));
    await tester.pumpAndSettle();

    expect(find.text('Subscription import failed'), findsOneWidget);
    expect(find.textContaining('super-secret'), findsNothing);
    expect(container.read(shellTabProvider), kShellDashboardTab);
  });

  testWidgets('an unsafe target is refused without a prompt', (
    WidgetTester tester,
  ) async {
    await pumpListener(
      tester,
      initial: installConfig('http://127.0.0.1/sub?token=super-secret'),
    );

    expect(find.text('Import this subscription?'), findsNothing);
    expect(find.text('Subscription import failed'), findsOneWidget);
    expect(find.textContaining('super-secret'), findsNothing);
    expect(profiles.importedUrls, isEmpty);
  });

  testWidgets('a missing url parameter is named', (WidgetTester tester) async {
    await pumpListener(tester, initial: 'aikobox://install-config?name=x');

    expect(find.text('Missing parameter: url'), findsOneWidget);
  });

  testWidgets('a link for another app is ignored silently', (
    WidgetTester tester,
  ) async {
    await pumpListener(tester, initial: 'https://example.com/page');

    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Import this subscription?'), findsNothing);
  });

  testWidgets('the same link delivered twice only asks once', (
    WidgetTester tester,
  ) async {
    final FakeAppLinks links = await pumpListener(
      tester,
      initial: installConfig(target),
    );

    links.emit(installConfig(target));
    await tester.pumpAndSettle();

    expect(find.text('Import this subscription?'), findsOneWidget);
  });

  testWidgets('a warm-start link is handled too', (WidgetTester tester) async {
    final FakeAppLinks links = await pumpListener(tester);
    expect(find.text('Import this subscription?'), findsNothing);

    links.emit(installConfig(target));
    await tester.pumpAndSettle();

    expect(find.text('Import this subscription?'), findsOneWidget);
  });
}
