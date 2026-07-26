/// The dashboard: a staggered grid of cards, a morphing start/stop FAB, and
/// the one place the app tells you the tunnel is unhappy.
///
/// The grid is the desktop sider ported whole — same card keys, same
/// `col-span-2` / `col-span-1` / `hidden` model, same persistence through
/// `AppConfig` — laid out as FlClash lays out its dashboard rather than as a
/// fixed sidebar.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import 'card_layout_sheet.dart';
import 'dashboard_cards.dart';
import 'dashboard_providers.dart';
import 'start_button.dart';

class DashboardPage extends ConsumerStatefulWidget {
  const DashboardPage({
    super.key,
    this.showAppBar = true,
    this.bottomInset = 0,
  });

  /// Set false when the shell draws its own header for this page.
  final bool showAppBar;

  /// Extra bottom padding, for a shell that puts a navigation bar under the
  /// page. On top of the FAB clearance the page adds anyway.
  final double bottomInset;

  @override
  ConsumerState<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends ConsumerState<DashboardPage> {
  /// The error text the user has already waved away, so it does not come back
  /// on every rebuild.
  String? _dismissedError;

  Future<void> _refresh() async {
    ref.invalidate(proxiesProvider);
    ref.invalidate(outboundModeProvider);
    ref.invalidate(rulesProvider);
    ref.invalidate(proxyProvidersProvider);
    ref.invalidate(ruleProvidersProvider);
    ref.invalidate(profilesProvider);
    ref.invalidate(profileRuntimeSummaryProvider);
    ref.invalidate(coreVersionProvider);
    await ref.read(networkLatencyProvider.notifier).refresh();
  }

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;
    final AppConfig config = ref.watch(appConfigProvider);
    final CoreStatus status = ref.watch(coreStatusProvider);
    final List<String> order = resolveDashboardCardOrder(config.cardOrder);
    final List<StaggeredGridItem> items = buildDashboardGridItems(
      order: order,
      config: config,
    );

    final String? error =
        status.error != null && status.error != _dismissedError
        ? status.error
        : null;

    return AikoScaffold(
      showAppBar: widget.showAppBar,
      title: l10n.t('dashboard.title'),
      automaticallyImplyLeading: false,
      safeAreaBottom: false,
      actions: <Widget>[
        IconButton(
          onPressed: () => showDashboardLayoutSheet(context),
          tooltip: l10n.t('dashboard.cards.title'),
          icon: const Icon(Icons.dashboard_customize_outlined),
        ),
      ],
      floatingActionButton: const DashboardStartButton(),
      body: RefreshIndicator(
        onRefresh: _refresh,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: EdgeInsets.fromLTRB(
            AikoDims.pagePadding,
            8,
            AikoDims.pagePadding,
            AikoDims.fabClearance + widget.bottomInset,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (error != null) ...<Widget>[
                _ErrorStrip(
                  message: error,
                  onDismiss: () => setState(() => _dismissedError = error),
                ),
                const SizedBox(height: AikoDims.gridSpacing),
              ] else if (!status.isRunning) ...<Widget>[
                _StatusStrip(status: status),
                const SizedBox(height: AikoDims.gridSpacing),
              ],
              if (items.isEmpty)
                EmptyState(
                  icon: Icons.dashboard_customize_outlined,
                  title: l10n.t('common.emptyState'),
                  message: l10n.t('dashboard.cards.hint'),
                  action: FilledButton(
                    onPressed: () => showDashboardLayoutSheet(context),
                    child: Text(l10n.t('dashboard.cards.title')),
                  ),
                )
              else
                StaggeredGrid(items: items),
            ],
          ),
        ),
      ),
    );
  }
}

/// One quiet line saying what the core is doing, shown whenever the FAB's
/// running/stopped morph is not the whole story.
class _StatusStrip extends StatelessWidget {
  const _StatusStrip({required this.status});

  final CoreStatus status;

  static const Map<CoreState, String> _labelKeys = <CoreState, String>{
    CoreState.stopped: 'dashboard.status.stopped',
    CoreState.starting: 'dashboard.status.starting',
    CoreState.running: 'dashboard.status.running',
    CoreState.stopping: 'dashboard.status.stopping',
    CoreState.failed: 'dashboard.status.failed',
  };

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final AikoStatusColors colors = AikoStatusColors.of(context);

    final Color dot = switch (status.state) {
      CoreState.running => colors.good,
      CoreState.starting || CoreState.stopping => colors.warn,
      CoreState.failed => colors.bad,
      CoreState.stopped => theme.colorScheme.outline,
    };

    return Row(
      children: <Widget>[
        Container(
          width: 8,
          height: 8,
          decoration: ShapeDecoration(color: dot, shape: const CircleBorder()),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            l10n.t(_labelKeys[status.state] ?? 'dashboard.status.stopped'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      ],
    );
  }
}

/// The core has something to say and it is not good news.
///
/// The text is the core's own — N4 and N5 both want it shown as it was
/// written, not summarised — so the localised part is the heading and the
/// dismiss action.
class _ErrorStrip extends StatelessWidget {
  const _ErrorStrip({required this.message, required this.onDismiss});

  final String message;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);

    return CommonCard(
      icon: Icons.error_outline_rounded,
      label: l10n.t('common.error.default'),
      isError: true,
      headerActions: <Widget>[
        IconButton(
          onPressed: onDismiss,
          tooltip: l10n.t('common.dismiss'),
          icon: const Icon(Icons.close_rounded),
        ),
      ],
      child: Text(
        message,
        style: theme.textTheme.bodySmall?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}
