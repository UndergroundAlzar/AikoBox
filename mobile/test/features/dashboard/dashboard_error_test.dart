import 'package:aikobox_mobile/core/providers.dart';
import 'package:aikobox_mobile/features/dashboard/dashboard.dart';
import 'package:aikobox_mobile/l10n/aiko_l10n.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

void main() {
  late AikoL10n l10n;

  setUp(() async {
    l10n = await primeEnglish();
  });

  tearDown(AikoL10n.resetForTests);

  test('a declined VPN prompt gets its own wording, not a generic error', () {
    final DashboardErrorPresentation presentation = dashboardErrorPresentation(
      l10n,
      const CoreStartException(
        CoreStartException.codeVpnPermissionDenied,
        'VPN permission was not granted',
      ),
    );
    expect(presentation.title, l10n.t('vpn.permission.denied.title'));
    expect(presentation.message, l10n.t('vpn.permission.denied.message'));
    expect(presentation.title, isNot(l10n.t('common.error.default')));
  });

  test('a missing profile points at the profile screen wording', () {
    final DashboardErrorPresentation presentation = dashboardErrorPresentation(
      l10n,
      const CoreStartException(
        CoreStartException.codeNoProfile,
        'No profile is selected',
      ),
    );
    expect(presentation.title, l10n.t('dashboard.noProfile.title'));
  });

  test('the health gate failure explains that nothing was exposed', () {
    final DashboardErrorPresentation presentation = dashboardErrorPresentation(
      l10n,
      const CoreStartException(
        CoreStartException.codeHealthGateFailed,
        'The core started but never answered its control API',
      ),
    );
    expect(presentation.title, l10n.t('error.code.E_CORE_START_FAILED'));
    expect(presentation.message, l10n.t('vpn.healthCheck.failed'));
  });

  test('N4: converter refusals survive verbatim in the details', () {
    const List<String> refusals = <String>[
      'Refusing to convert: proxy "HK 01" uses an unsupported cipher.',
      'Refusing to convert: rule-provider "ads" has no url.',
    ];
    final DashboardErrorPresentation presentation = dashboardErrorPresentation(
      l10n,
      const CoreStartException(
        CoreStartException.codeConversionRefused,
        'Refusing to convert: proxy "HK 01" uses an unsupported cipher.',
        details: refusals,
      ),
    );
    expect(presentation.details, refusals);
    // The heading is localised; the refusals themselves are not paraphrased.
    expect(presentation.title, l10n.t('mihomo.error.profileCheckFailed'));
    for (final String refusal in refusals) {
      expect(presentation.clipboardText, contains(refusal));
    }
  });

  test('a platform failure keeps its code-derived heading', () {
    final DashboardErrorPresentation presentation = dashboardErrorPresentation(
      l10n,
      const AikoCoreException(
        AikoCoreException.codeTunEstablishFailed,
        'establish() returned null',
        'android.net.VpnService',
      ),
    );
    expect(presentation.title, l10n.t('error.code.E_TUN_ESTABLISH_FAILED'));
    expect(presentation.details, <String>['android.net.VpnService']);
  });

  test('an unrecognised code falls back without losing the message', () {
    final DashboardErrorPresentation presentation = dashboardErrorPresentation(
      l10n,
      const AikoCoreException('E_SOMETHING_NEW', 'brand new failure'),
    );
    expect(presentation.title, l10n.t('common.error.default'));
    expect(presentation.message, 'brand new failure');
  });

  test('a plain object is still shown rather than swallowed', () {
    final DashboardErrorPresentation presentation = dashboardErrorPresentation(
      l10n,
      StateError('boom'),
    );
    expect(presentation.title, l10n.t('common.error.default'));
    expect(presentation.message, contains('boom'));
  });

  test('the untyped fallback never quotes a subscription URL (N7)', () {
    final DashboardErrorPresentation presentation = dashboardErrorPresentation(
      l10n,
      StateError(
        'GET https://user:pw@sub.example.net/feed/s3cr3t-token?key=s3cr3t '
        'failed',
      ),
    );
    expect(presentation.message, isNotNull);
    expect(presentation.message, isNot(contains('s3cr3t')));
    expect(presentation.message, isNot(contains('user:pw')));
    // The host survives so the user can still tell which subscription broke.
    expect(presentation.message, contains('sub.example.net'));
    expect(presentation.clipboardText, isNot(contains('s3cr3t')));
  });

  test('a bearer token in an untyped failure is scrubbed too (N7)', () {
    final DashboardErrorPresentation presentation = dashboardErrorPresentation(
      l10n,
      StateError('rejected: Authorization: Bearer abcdef0123456789'),
    );
    expect(presentation.message, isNot(contains('abcdef0123456789')));
  });
}
