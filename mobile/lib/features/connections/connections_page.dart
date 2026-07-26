/// The connections page.
///
/// Port of `src/renderer/src/pages/connections.tsx`: Active/Closed tabs with
/// live counts, a free-text filter over the whole record, sort field and
/// direction persisted into `AppConfig`, pause, and close one / close all /
/// close filtered.
///
/// The desktop's table view and its app-icon column are deliberately not here.
/// A resizable seven-column table does not survive a 360 dp screen, and icons
/// are the Android `PackageManager`'s job, which lives behind a channel this
/// layer does not own.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import 'connection_detail_sheet.dart';
import 'connection_tile.dart';
import 'connections_controller.dart';

/// Which list a tab shows.
enum ConnectionsTab { active, closed }

class ConnectionsPage extends ConsumerStatefulWidget {
  const ConnectionsPage({super.key});

  @override
  ConsumerState<ConnectionsPage> createState() => _ConnectionsPageState();
}

class _ConnectionsPageState extends ConsumerState<ConnectionsPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(_onTabChanged);
  final TextEditingController _filter = TextEditingController();

  String _query = '';

  @override
  void dispose() {
    _tabs
      ..removeListener(_onTabChanged)
      ..dispose();
    _filter.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    // The trailing action changes meaning between the tabs, so the app bar has
    // to rebuild even while the indicator is still animating.
    if (mounted) setState(() {});
  }

  ConnectionsTab get _tab =>
      _tabs.index == 0 ? ConnectionsTab.active : ConnectionsTab.closed;

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final ConnectionsFeedState feed = ref.watch(connectionsFeedProvider);
    final AppConfig config = ref.watch(appConfigProvider);
    final bool running = ref.watch(
      coreStatusProvider.select((CoreStatus status) => status.isRunning),
    );

    final ConnectionSortField field = ConnectionSortField.fromWire(
      config.connectionOrderBy,
    );
    final bool ascending = config.connectionDirection == 'asc';
    final DateTime now = DateTime.now();

    final List<ConnectionInfo> visibleActive = sortConnections(
      filterConnections(feed.active, _query),
      field: field,
      ascending: ascending,
    );
    final List<ConnectionInfo> visibleClosed = sortConnections(
      filterConnections(feed.closed, _query),
      field: field,
      ascending: ascending,
    );

    return AikoScaffold(
      title: l10n.t('connections.title'),
      actions: <Widget>[
        IconButton(
          tooltip: feed.paused
              ? l10n.t('connections.resume')
              : l10n.t('connections.pause'),
          onPressed: () => ref
              .read(connectionsFeedProvider.notifier)
              .setPaused(paused: !feed.paused),
          icon: Icon(
            feed.paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          ),
          color: feed.paused ? theme.colorScheme.primary : null,
        ),
        _SortMenu(field: field, ascending: ascending),
      ],
      bottom: PreferredSize(
        // Fixed on purpose: 56 for the filter row (an IconButton's 48 px hit
        // target plus its gap) and 48 for the tab strip. Letting the column
        // measure itself here makes the app bar's height depend on text scale,
        // which is exactly the kind of thing that overflows on someone's phone.
        preferredSize: const Size.fromHeight(104),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                AikoDims.pagePadding,
                0,
                8,
                8,
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _filter,
                      onChanged: (String value) =>
                          setState(() => _query = value),
                      textInputAction: TextInputAction.search,
                      decoration: InputDecoration(
                        isDense: true,
                        filled: true,
                        hintText: l10n.t('connections.filter'),
                        prefixIcon: const Icon(Icons.search_rounded, size: 20),
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 40,
                        ),
                        suffixIcon: _query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: l10n.t('common.clear'),
                                iconSize: 18,
                                onPressed: () {
                                  _filter.clear();
                                  setState(() => _query = '');
                                },
                                icon: const Icon(Icons.close_rounded),
                              ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: _query.isEmpty
                        ? l10n.t('connections.closeAll')
                        : l10n.t('connections.closeFiltered'),
                    color: theme.colorScheme.error,
                    onPressed:
                        (_tab == ConnectionsTab.active
                            ? visibleActive
                            : visibleClosed)
                            .isEmpty
                        ? null
                        : () => _closeVisible(
                            _tab == ConnectionsTab.active
                                ? visibleActive
                                : visibleClosed,
                          ),
                    icon: Icon(
                      _tab == ConnectionsTab.active
                          ? Icons.block_rounded
                          : Icons.delete_sweep_rounded,
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: 48,
              child: TabBar(
                controller: _tabs,
                tabs: <Widget>[
                  _CountTab(
                    label: l10n.t('connections.active'),
                    count: feed.active.length,
                  ),
                  _CountTab(
                    label: l10n.t('connections.closed'),
                    count: feed.closed.length,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: <Widget>[
          _TotalsBar(upload: feed.uploadTotal, download: feed.downloadTotal),
          Expanded(
            child: TabBarView(
              controller: _tabs,
              children: <Widget>[
                _ConnectionsList(
                  connections: visibleActive,
                  isActive: true,
                  now: now,
                  emptyTitle: running
                      ? l10n.t('connections.empty')
                      : l10n.t('dashboard.core.notRunning'),
                  onDismiss: _closeOne,
                ),
                _ConnectionsList(
                  connections: visibleClosed,
                  isActive: false,
                  now: now,
                  emptyTitle: l10n.t('common.emptyState'),
                  onDismiss: (ConnectionInfo connection) => ref
                      .read(connectionsFeedProvider.notifier)
                      .dismissClosed(connection.id),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _closeOne(ConnectionInfo connection) async {
    try {
      await ref.read(coreControllerProvider).closeConnection(connection.id);
    } on Object catch (error) {
      _reportFailure(error);
    }
  }

  /// Closes (active tab) or forgets (closed tab) everything currently listed.
  ///
  /// With no filter this is the desktop's "close all", which goes through the
  /// single `DELETE /connections` call. With a filter it degrades to closing
  /// the visible ids one by one, exactly as the desktop does — the Clash API
  /// has no bulk-by-predicate form.
  Future<void> _closeVisible(List<ConnectionInfo> visible) async {
    final AikoL10n l10n = context.l10n;
    final bool confirmed = await showAikoConfirmSheet(
      context,
      title: l10n.t('connections.closeConfirm.title'),
      message: l10n.t('connections.closeConfirm.content'),
      confirmLabel: l10n.t('common.confirm'),
      cancelLabel: l10n.t('common.cancel'),
      icon: Icons.link_off_rounded,
      destructive: true,
    );
    if (!confirmed || !mounted) return;

    if (_tab == ConnectionsTab.closed) {
      ref.read(connectionsFeedProvider.notifier).clearClosed(
        ids: _query.isEmpty
            ? null
            : <String>{
                for (final ConnectionInfo item in visible) item.id,
              },
      );
      return;
    }

    final CoreController controller = ref.read(coreControllerProvider);
    try {
      if (_query.isEmpty) {
        await controller.closeAllConnections();
      } else {
        for (final ConnectionInfo item in visible) {
          await controller.closeConnection(item.id);
        }
      }
    } on Object catch (error) {
      _reportFailure(error);
    }
  }

  void _reportFailure(Object error) {
    if (!mounted) return;
    final AikoL10n l10n = context.l10n;
    final String message = error is AikoCoreException
        ? (l10n.has('error.code.${error.code}')
              ? l10n.t('error.code.${error.code}')
              : error.message)
        : l10n.t('error.code.E_UNKNOWN');
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(behavior: SnackBarBehavior.floating, content: Text(message)),
    );
  }
}

/// `Active  12` — the tab label with its live count.
class _CountTab extends StatelessWidget {
  const _CountTab({required this.label, required this.count});

  final String label;
  final int count;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Tab(
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 6),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: ShapeDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              shape: const StadiumBorder(),
            ),
            child: Text(
              '$count',
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Cumulative up/down since the core started.
class _TotalsBar extends StatelessWidget {
  const _TotalsBar({required this.upload, required this.download});

  final int upload;
  final int download;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AikoDims.pagePadding,
        6,
        AikoDims.pagePadding,
        4,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          ConnectionTrafficPill(up: upload, down: download),
        ],
      ),
    );
  }
}

class _ConnectionsList extends StatelessWidget {
  const _ConnectionsList({
    required this.connections,
    required this.isActive,
    required this.now,
    required this.emptyTitle,
    required this.onDismiss,
  });

  final List<ConnectionInfo> connections;
  final bool isActive;
  final DateTime now;
  final String emptyTitle;
  final void Function(ConnectionInfo connection) onDismiss;

  @override
  Widget build(BuildContext context) {
    if (connections.isEmpty) {
      return EmptyState(icon: Icons.lan_outlined, title: emptyTitle);
    }
    return SuperListView.builder(
      padding: const EdgeInsets.fromLTRB(
        AikoDims.pagePadding,
        4,
        AikoDims.pagePadding,
        AikoDims.fabClearance,
      ),
      itemCount: connections.length,
      // Rows are keyed by connection id, so a list that reorders under a live
      // sort reuses elements instead of rebuilding every visible row.
      findChildIndexCallback: (Key key) {
        if (key is! ValueKey<String>) return null;
        final int index = connections.indexWhere(
          (ConnectionInfo item) => item.id == key.value,
        );
        return index < 0 ? null : index;
      },
      itemBuilder: (BuildContext context, int index) {
        final ConnectionInfo connection = connections[index];
        return ConnectionTile(
          key: ValueKey<String>(connection.id),
          connection: connection,
          isActive: isActive,
          now: now,
          onOpenDetail: () =>
              showConnectionDetailSheet(context, connection: connection),
          onDismiss: () => onDismiss(connection),
        );
      },
    );
  }
}

/// Sort field and direction, persisted through `AppConfig` so the choice
/// survives a restart the same way it does on the desktop.
///
/// Direction has no menu row of its own: picking the field that is already
/// selected flips it, and the checked row carries an arrow showing which way it
/// currently runs. That is one fewer control on a phone app bar, and — the
/// reason it is done this way rather than the desktop's separate button — the
/// shared locale files have no "ascending"/"descending" strings to label such a
/// row with, and inventing English ones in a widget is not an option.
class _SortMenu extends ConsumerWidget {
  const _SortMenu({required this.field, required this.ascending});

  final ConnectionSortField field;
  final bool ascending;

  static const Map<ConnectionSortField, String> _labelKeys =
      <ConnectionSortField, String>{
        ConnectionSortField.time: 'connections.time',
        ConnectionSortField.upload: 'connections.uploadAmount',
        ConnectionSortField.download: 'connections.downloadAmount',
        ConnectionSortField.uploadSpeed: 'connections.uploadSpeed',
        ConnectionSortField.downloadSpeed: 'connections.downloadSpeed',
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    return PopupMenuButton<String>(
      tooltip: l10n.t('connections.orderBy'),
      icon: const Icon(Icons.sort_rounded),
      onSelected: (String value) async {
        final AppConfigNotifier notifier = ref.read(
          appConfigProvider.notifier,
        );
        final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
          context,
        );
        final String failure = l10n.t('common.error.updateAppConfigFailed');
        final bool sameField = ConnectionSortField.fromWire(value) == field;
        try {
          await notifier.update(
            (AppConfig current) => sameField
                ? current.copyWith(
                    connectionDirection: ascending ? 'desc' : 'asc',
                  )
                : current.copyWith(connectionOrderBy: value),
          );
        } on Object {
          // Persisting a sort preference is not worth an error dialog, but it
          // is worth saying out loud — the menu would otherwise appear to have
          // worked and silently revert on the next launch.
          messenger?.showSnackBar(
            SnackBar(
              behavior: SnackBarBehavior.floating,
              content: Text(failure),
            ),
          );
        }
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        for (final MapEntry<ConnectionSortField, String> entry
            in _labelKeys.entries)
          CheckedPopupMenuItem<String>(
            value: entry.key.wireName,
            checked: entry.key == field,
            child: Row(
              children: <Widget>[
                Expanded(child: Text(l10n.t(entry.value))),
                if (entry.key == field)
                  Icon(
                    ascending
                        ? Icons.arrow_upward_rounded
                        : Icons.arrow_downward_rounded,
                    size: 16,
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
