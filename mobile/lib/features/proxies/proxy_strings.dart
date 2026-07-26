/// The localised strings the proxies widgets need, resolved once per build.
///
/// The widgets below this file take display text, never keys — the same rule
/// `lib/widgets/` follows. Bundling them keeps the lookups in one place instead
/// of scattering `context.l10n` through the grid, which on a 500-cell page
/// would be 500 `Localizations.of` walks per frame.
library;

import 'package:flutter/widgets.dart';

import '../../l10n/aiko_l10n.dart';

/// Resolves [preferred] when the bundle has it, otherwise [fallback].
///
/// Two strings this page wants do not exist in `assets/locales/` yet: a name
/// for each of the two views, and a verb for expanding one group rather than
/// all of them. Rather than ship a raw key on screen, the page borrows the
/// closest existing string and picks up the precise one automatically the day
/// it is added.
String proxyText(AikoL10n l10n, String preferred, String fallback) =>
    l10n.has(preferred) ? l10n.t(preferred) : l10n.t(fallback);

@immutable
class ProxyStrings {
  const ProxyStrings({
    required this.testGroup,
    required this.testNode,
    required this.locate,
    required this.current,
    required this.nodeCount,
  });

  factory ProxyStrings.of(BuildContext context) {
    final l10n = AikoL10n.of(context);
    return ProxyStrings(
      testGroup: l10n.t('proxies.testAll'),
      testNode: l10n.t('proxies.delay.test'),
      locate: l10n.t('proxies.locate'),
      current: l10n.t('proxies.current'),
      nodeCount: (int count) => l10n.plural('plural.nodes', count),
    );
  }

  /// Tooltip on the per-group URL-test button.
  final String testGroup;

  /// Tooltip on a cell's latency pill.
  final String testNode;

  /// Tooltip on the scroll-to-current-node button.
  final String locate;

  /// Label for the badge on a node a group picked by itself.
  final String current;

  /// "12 nodes", pluralised for the active locale.
  final String Function(int count) nodeCount;
}
