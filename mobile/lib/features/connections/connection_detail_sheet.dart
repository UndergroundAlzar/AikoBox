/// The connection detail sheet, with "copy as Clash rule" on every field that
/// can become one.
///
/// Port of `connection-detail-modal.tsx`. Each row carries a copy button; where
/// the field maps onto a rule the button opens a menu whose first entry is the
/// value as shown and whose remaining entries are ready-to-paste rule lines
/// (see `clash_rule.dart` for the generation, which matches the desktop
/// exactly).
///
/// The sheet re-resolves its connection out of the live feed on every frame, so
/// byte counters keep ticking while it is open and the row flips to "closed"
/// the moment the core drops it — the same thing the desktop's
/// `selectedConnection` memo does.
library;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/app_theme.dart';
import 'clash_rule.dart';
import 'connection_fields.dart';
import 'connections_controller.dart';
import 'format.dart';

/// Opens the detail sheet for [connection].
Future<void> showConnectionDetailSheet(
  BuildContext context, {
  required ConnectionInfo connection,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (BuildContext sheetContext) =>
        ConnectionDetailSheet(initial: connection),
  );
}

/// The sheet body, exposed so it can be pumped without a navigator.
class ConnectionDetailSheet extends ConsumerWidget {
  const ConnectionDetailSheet({super.key, required this.initial});

  /// The record the row was showing when it was tapped. Used as a fallback once
  /// the connection ages out of the retained history.
  final ConnectionInfo initial;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ThemeData theme = Theme.of(context);
    final AikoL10n l10n = context.l10n;
    final ConnectionsFeedState feed = ref.watch(connectionsFeedProvider);

    final ConnectionInfo? live = feed.active.firstWhereOrNull(
      (ConnectionInfo item) => item.id == initial.id,
    );
    final ConnectionInfo connection =
        live ??
        feed.closed.firstWhereOrNull(
          (ConnectionInfo item) => item.id == initial.id,
        ) ??
        initial;
    final bool isActive = live != null;
    final ConnectionFields fields = connectionFieldsOf(connection);

    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * 0.85,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 8, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    l10n.t('connections.detail.title'),
                    style: theme.textTheme.titleMedium,
                  ),
                ),
                IconButton(
                  tooltip: l10n.t('connections.detail.close'),
                  onPressed: () => Navigator.of(context).maybePop(),
                  icon: const Icon(Icons.close_rounded),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Flexible(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 20),
              children: <Widget>[
                ConnectionDetailRow(
                  label: l10n.t('connections.detail.status'),
                  value: isActive
                      ? l10n.t('connections.active')
                      : l10n.t('connections.closed'),
                  copyable: false,
                ),
                ConnectionDetailRow(
                  label: l10n.t('connections.detail.establishTime'),
                  value: '${formatTimestamp(connection.start)}  '
                      '(${formatElapsedClock(DateTime.now().difference(connection.start))})',
                ),
                if (fields.rule.isNotEmpty)
                  ConnectionDetailRow(
                    label: l10n.t('connections.detail.rule'),
                    value: fields.rule,
                  ),
                if (fields.chain.isNotEmpty)
                  ConnectionDetailRow(
                    label: l10n.t('connections.detail.proxyChain'),
                    value: fields.chain,
                  ),
                ConnectionDetailRow(
                  label: l10n.t('connections.detail.connectionType'),
                  value: fields.typeLabel,
                  targets: <ClashRuleTarget>[
                    if (fields.type.isNotEmpty)
                      ClashRuleTarget(ClashRulePrefix.inType, fields.type),
                    if (fields.network.isNotEmpty)
                      ClashRuleTarget(ClashRulePrefix.network, fields.network),
                  ],
                ),
                if (fields.hostname.isNotEmpty)
                  ConnectionDetailRow(
                    label: l10n.t('connections.detail.host'),
                    value: fields.hostname,
                    targets: fields.hostTargets,
                  ),
                if (fields.process.isNotEmpty)
                  ConnectionDetailRow(
                    label: l10n.t('connections.detail.processName'),
                    value: fields.process,
                    targets: <ClashRuleTarget>[
                      ClashRuleTarget(
                        ClashRulePrefix.processName,
                        fields.process,
                      ),
                    ],
                  ),
                if (fields.sourceIp.isNotEmpty)
                  ConnectionDetailRow(
                    label: l10n.t('connections.detail.sourceIP'),
                    value: fields.sourceIp,
                    targets: <ClashRuleTarget>[
                      ClashRuleTarget(
                        ClashRulePrefix.srcIpCidr,
                        fields.sourceIp,
                      ),
                    ],
                  ),
                if (fields.destinationIp.isNotEmpty)
                  ConnectionDetailRow(
                    label: l10n.t('connections.detail.destinationIP'),
                    value: fields.destinationIp,
                    targets: <ClashRuleTarget>[
                      ClashRuleTarget(
                        ClashRulePrefix.ipCidr,
                        fields.destinationIp,
                      ),
                    ],
                  ),
                if (fields.port.isNotEmpty)
                  ConnectionDetailRow(
                    label: l10n.t('connections.detail.destinationPort'),
                    value: fields.port,
                    targets: <ClashRuleTarget>[
                      ClashRuleTarget(ClashRulePrefix.dstPort, fields.port),
                    ],
                  ),
                ConnectionDetailRow(
                  label: l10n.t('connections.uploadAmount'),
                  value: formatTrafficText(l10n, connection.upload),
                  copyable: false,
                ),
                ConnectionDetailRow(
                  label: l10n.t('connections.downloadAmount'),
                  value: formatTrafficText(l10n, connection.download),
                  copyable: false,
                ),
                ConnectionDetailRow(
                  label: l10n.t('connections.uploadSpeed'),
                  value: formatSpeedText(l10n, connection.uploadSpeed),
                  copyable: false,
                ),
                ConnectionDetailRow(
                  label: l10n.t('connections.downloadSpeed'),
                  value: formatSpeedText(l10n, connection.downloadSpeed),
                  copyable: false,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One `label / value / copy` row of the detail sheet.
class ConnectionDetailRow extends StatelessWidget {
  const ConnectionDetailRow({
    super.key,
    required this.label,
    required this.value,
    this.targets = const <ClashRuleTarget>[],
    this.copyable = true,
  });

  final String label;
  final String value;

  /// Rule prefixes this value can be turned into. Empty means the copy button
  /// copies the value itself with no menu.
  final List<ClashRuleTarget> targets;

  /// Set false for rows that are pure read-out (byte counters, status).
  final bool copyable;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AikoL10n l10n = context.l10n;

    final List<ClashRuleCandidate> candidates = clashRuleCandidates(
      displayValue: value,
      targets: targets,
    );
    final bool hasMenu = candidates.length > 1;

    Widget? trailing;
    if (copyable && value.isNotEmpty) {
      trailing = hasMenu
          ? PopupMenuButton<String>(
              tooltip: l10n.t('connections.detail.copyRule'),
              icon: const Icon(Icons.copy_rounded, size: 18),
              onSelected: (String text) => _copy(
                context,
                text,
                isRule: text != value,
              ),
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                for (final ClashRuleCandidate candidate in candidates)
                  PopupMenuItem<String>(
                    value: candidate.text,
                    child: Text(
                      candidate.text,
                      style: candidate.isRaw
                          ? theme.textTheme.bodyMedium
                          : theme.textTheme.bodyMedium?.copyWith(
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                              color: scheme.primary,
                            ),
                    ),
                  ),
              ],
            )
          : IconButton(
              tooltip: l10n.t('common.copy'),
              iconSize: 18,
              onPressed: () => _copy(context, value, isRule: false),
              icon: const Icon(Icons.copy_rounded),
            );
    }

    return Padding(
      padding: EdgeInsets.fromLTRB(16, 10, trailing == null ? 16 : 4, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 116,
            child: Text(
              label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: scheme.onSurface,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  static void _copy(
    BuildContext context,
    String text, {
    required bool isRule,
  }) {
    final AikoL10n l10n = context.l10n;
    // Fire and forget: the platform side of setData cannot fail in a way the
    // user could act on, and blocking the menu dismissal on it would be worse.
    Clipboard.setData(ClipboardData(text: text));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        duration: AikoDims.slowMotion * 6,
        content: Text(
          isRule
              ? l10n.t('connections.copyRuleSuccess')
              : l10n.t('common.copied'),
        ),
      ),
    );
  }
}
