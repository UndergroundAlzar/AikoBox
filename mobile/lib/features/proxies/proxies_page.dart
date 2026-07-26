/// The proxies page: every group the core reports, and every node inside them.
///
/// Port of `src/renderer/src/pages/proxies.tsx`, re-shaped for a phone:
///
/// * two views — FlClash's tab strip and the desktop's accordion — chosen from
///   the options sheet and remembered across launches, along with which groups
///   the accordion has open;
/// * the Surfboard grid: `max(width / 250, 2)` columns, 8 px gutters, a cell
///   showing name / type / latency;
/// * per-node and per-group latency tests, the group sweep bounded by
///   `delayTestConcurrency` and flushed in batches so a 500-node subscription
///   does not repaint once per result;
/// * search, hide-unavailable, sort, card size, layout and column count;
/// * locate-current-node, which computes its scroll target rather than
///   measuring it, because the target row has not been built yet.
///
/// URLTest / Fallback / LoadBalance / Relay groups pick their own member. Their
/// cells are not tappable and the current pick wears a badge, so the fill never
/// reads as a choice the user made and could undo.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import 'proxies_list_view.dart';
import 'proxies_options_sheet.dart';
import 'proxies_prefs.dart';
import 'proxies_providers.dart';
import 'proxies_tab_view.dart';
import 'proxy_delay_engine.dart';
import 'proxy_grid.dart';
import 'proxy_layout.dart';
import 'proxy_strings.dart';

class ProxiesPage extends ConsumerStatefulWidget {
  const ProxiesPage({super.key});

  @override
  ConsumerState<ProxiesPage> createState() => _ProxiesPageState();
}

class _ProxiesPageState extends ConsumerState<ProxiesPage> {
  final ScrollController _listController = ScrollController();
  final Map<String, ScrollController> _tabScrollControllers =
      <String, ScrollController>{};
  final TextEditingController _searchController = TextEditingController();

  bool _searching = false;
  String _query = '';

  /// Group names as of the last build, for the sheet's expand-all button.
  List<String> _groupNames = const <String>[];

  // --- Memoised node lists -------------------------------------------------
  // visibleProxyNodes() runs over every member of every group. On a large
  // subscription that is thousands of objects, and the page rebuilds on every
  // 200 ms delay flush. The inputs are all cheap to compare by identity, so the
  // result is cached until one of them actually changes.
  ProxiesSnapshot? _cacheSnapshot;
  Map<String, int?>? _cacheDelays;
  String _cacheQuery = '';
  bool _cacheHideUnavailable = false;
  ProxySortOrder _cacheSort = ProxySortOrder.byDefault;
  Map<String, List<ProxyNodeView>> _cacheNodes =
      const <String, List<ProxyNodeView>>{};

  @override
  void dispose() {
    _listController.dispose();
    for (final controller in _tabScrollControllers.values) {
      controller.dispose();
    }
    _searchController.dispose();
    super.dispose();
  }

  ScrollController _scrollControllerFor(String groupName) =>
      _tabScrollControllers.putIfAbsent(groupName, ScrollController.new);

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  Future<void> _refresh() async {
    try {
      await ref.read(proxiesProvider.notifier).refresh();
    } catch (error) {
      _reportError(error);
    }
  }

  Future<void> _selectNode(
    ProxyGroupSection section,
    ProxyNodeView node,
  ) async {
    if (!section.selectable) return;
    try {
      // CoreController.selectProxy is what closes live connections when
      // autoCloseConnection is on — see proxies_providers.dart.
      await ref.read(proxiesProvider.notifier).select(section.name, node.name);
    } catch (error) {
      _reportError(error);
    }
  }

  void _testNode(ProxyGroupSection section, ProxyNodeView node) {
    unawaited(
      ref
          .read(proxyDelayProvider.notifier)
          .testNode(node.name, testUrl: section.group.testUrl),
    );
  }

  Future<void> _testGroup(ProxyGroupSection section) async {
    final prefs = ref.read(proxiesPrefsProvider);
    // The desktop opens a collapsed group before sweeping it, so the results
    // are visible as they land rather than hidden behind a chevron.
    if (prefs.viewType == ProxiesViewType.list && !section.expanded) {
      await ref.read(proxiesPrefsProvider.notifier).toggleGroup(section.name);
    }
    await ref.read(proxyDelayProvider.notifier).testGroup(
      section.name,
      <String>[for (final node in section.nodes) node.name],
      testUrl: section.group.testUrl,
    );
  }

  Future<void> _locate(
    ProxyGroupSection section,
    List<ProxyGroupSection> sections, {
    required bool listView,
    required int columns,
    required double itemHeight,
  }) async {
    final index = section.currentIndex;
    if (index < 0) return;

    if (!listView) {
      _animateTo(
        _scrollControllerFor(section.name),
        proxyGridScrollOffset(
          itemIndex: index,
          columns: columns,
          itemHeight: itemHeight,
          topPadding: kProxyTabGridTopPadding,
        ),
      );
      return;
    }

    final groupIndex = sections.indexWhere((s) => s.name == section.name);
    if (groupIndex < 0) return;

    if (!section.expanded) {
      await ref.read(proxiesPrefsProvider.notifier).toggleGroup(section.name);
    }

    // Extents are taken with the target group open, because that is the state
    // the frame after this one will be laid out in.
    final extents = <ProxyGroupExtent>[
      for (var i = 0; i < sections.length; i++)
        i == groupIndex
            ? ProxyGroupExtent(
                itemCount: sections[i].nodes.length,
                expanded: true,
              )
            : sections[i].extent,
    ];
    final offset = proxyListScrollOffset(
      groups: extents,
      groupIndex: groupIndex,
      itemIndex: index,
      columns: columns,
      itemHeight: itemHeight,
    );

    if (section.expanded) {
      _animateTo(_listController, offset);
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _animateTo(_listController, offset);
      });
    }
  }

  void _animateTo(ScrollController controller, double offset) {
    if (!controller.hasClients) return;
    final max = controller.position.maxScrollExtent;
    controller.animateTo(
      offset.clamp(0, max < 0 ? 0 : max),
      duration: AikoDims.slowMotion,
      curve: Curves.easeOut,
    );
  }

  void _toggleSearch() {
    setState(() {
      _searching = !_searching;
      if (!_searching) {
        _searchController.clear();
        _query = '';
      }
    });
  }

  /// Surfaces a failure without swallowing it.
  ///
  /// No explicit `SemanticsService.announce`: [SnackBar] already marks its
  /// content as a live region, and Android has deprecated the announcement
  /// event this would otherwise post.
  void _reportError(Object error) {
    if (!mounted) return;
    final message = '${AikoL10n.of(context).t('common.error.default')}: $error';
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _openOptions() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(AikoDims.sheetRadius),
        ),
      ),
      builder: (BuildContext sheetContext) => Consumer(
        builder: (BuildContext context, WidgetRef ref, Widget? child) {
          final prefs = ref.watch(proxiesPrefsProvider);
          final config = ref.watch(appConfigProvider);
          final prefsNotifier = ref.read(proxiesPrefsProvider.notifier);
          final configNotifier = ref.read(appConfigProvider.notifier);
          final isList = prefs.viewType == ProxiesViewType.list;

          return ProxiesOptionsSheet(
            viewType: prefs.viewType,
            sortOrder: config.proxyDisplayOrder,
            hideUnavailable: config.hideUnavailableProxies,
            density: prefs.density,
            layout: prefs.layout,
            proxyCols: config.proxyCols,
            onViewTypeChanged: prefsNotifier.setViewType,
            onSortOrderChanged: (ProxySortOrder value) => unawaited(
              configNotifier.update(
                (c) => c.copyWith(proxyDisplayOrder: value),
              ),
            ),
            onHideUnavailableChanged: (bool value) => unawaited(
              configNotifier.update(
                (c) => c.copyWith(hideUnavailableProxies: value),
              ),
            ),
            onDensityChanged: prefsNotifier.setDensity,
            onLayoutChanged: prefsNotifier.setLayout,
            onProxyColsChanged: (String value) => unawaited(
              configNotifier.update((c) => c.copyWith(proxyCols: value)),
            ),
            onExpandAll: isList
                ? () => prefsNotifier.expandAll(_groupNames)
                : null,
            onCollapseAll: isList ? prefsNotifier.collapseAll : null,
          );
        },
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Build
  // -------------------------------------------------------------------------

  List<ProxyGroupSection> _sectionsFor({
    required ProxiesSnapshot snapshot,
    required AppConfig config,
    required ProxiesPrefs prefs,
    required ProxyDelayState delay,
    required OutboundMode mode,
  }) {
    final groups = visibleProxyGroups(snapshot, mode: mode);

    final stale =
        !identical(_cacheSnapshot, snapshot) ||
        !identical(_cacheDelays, delay.delays) ||
        _cacheQuery != _query ||
        _cacheHideUnavailable != config.hideUnavailableProxies ||
        _cacheSort != config.proxyDisplayOrder;
    if (stale) {
      _cacheNodes = <String, List<ProxyNodeView>>{
        for (final group in groups)
          group.name: visibleProxyNodes(
            snapshot: snapshot,
            group: group,
            query: _query,
            hideUnavailable: config.hideUnavailableProxies,
            sort: config.proxyDisplayOrder,
            delayOverrides: delay.delays,
          ),
      };
      _cacheSnapshot = snapshot;
      _cacheDelays = delay.delays;
      _cacheQuery = _query;
      _cacheHideUnavailable = config.hideUnavailableProxies;
      _cacheSort = config.proxyDisplayOrder;
    }

    return <ProxyGroupSection>[
      for (final group in groups)
        ProxyGroupSection(
          group: group,
          nodes: _cacheNodes[group.name] ?? const <ProxyNodeView>[],
          expanded: prefs.isExpanded(group.name),
          testing: delay.isGroupTesting(group.name),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AikoL10n.of(context);
    final status = ref.watch(coreStatusProvider);
    final mode = ref.watch(outboundModeProvider);
    final snapshotAsync = ref.watch(proxiesProvider);

    final Widget body;
    if (!status.isRunning) {
      body = EmptyState(
        icon: Icons.lan_outlined,
        title: l10n.t('proxies.empty.title'),
        message: l10n.t('proxies.empty.description'),
      );
    } else if (mode.value == OutboundMode.direct) {
      // Rule and Global both route through outbounds; Direct has nothing to
      // pick between, which is exactly what the desktop shows here.
      body = EmptyState(
        icon: Icons.double_arrow_rounded,
        title: l10n.t('proxies.mode.direct'),
      );
    } else {
      body = snapshotAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace _) => EmptyState(
          icon: Icons.error_outline_rounded,
          title: l10n.t('common.error.default'),
          message: '$error',
          action: FilledButton.tonal(
            onPressed: _refresh,
            child: Text(l10n.t('common.retry')),
          ),
        ),
        data: _buildContent,
      );
    }

    return AikoScaffold(
      title: _searching ? null : l10n.t('proxies.title'),
      titleWidget: _searching ? _buildSearchField(l10n) : null,
      safeAreaBottom: false,
      actions: <Widget>[
        IconButton(
          tooltip: l10n.t('common.search'),
          icon: Icon(
            _searching ? Icons.search_off_rounded : Icons.search_rounded,
          ),
          onPressed: _toggleSearch,
        ),
        IconButton(
          tooltip: l10n.t('proxies.layout.title'),
          icon: const Icon(Icons.tune_rounded),
          onPressed: _openOptions,
        ),
      ],
      body: RefreshIndicator(
        onRefresh: _refresh,
        // The tab view nests its grid inside a horizontal PageView, so the
        // notification the indicator wants arrives one level down.
        notificationPredicate: (ScrollNotification notification) =>
            notification.depth <= 1 &&
            notification.metrics.axis == Axis.vertical,
        child: body,
      ),
    );
  }

  Widget _buildSearchField(AikoL10n l10n) => TextField(
    controller: _searchController,
    autofocus: true,
    textInputAction: TextInputAction.search,
    decoration: InputDecoration(
      isDense: true,
      border: InputBorder.none,
      hintText: l10n.t('proxies.search.placeholder'),
    ),
    onChanged: (String value) => setState(() => _query = value),
  );

  Widget _buildContent(ProxiesSnapshot snapshot) {
    final l10n = AikoL10n.of(context);
    final config = ref.watch(appConfigProvider);
    final prefs = ref.watch(proxiesPrefsProvider);
    final delay = ref.watch(proxyDelayProvider);

    final sections = _sectionsFor(
      snapshot: snapshot,
      config: config,
      prefs: prefs,
      delay: delay,
      mode: ref.watch(outboundModeProvider).value ?? OutboundMode.rule,
    );
    _groupNames = <String>[for (final section in sections) section.name];

    if (sections.isEmpty) {
      // ListView rather than a bare EmptyState: RefreshIndicator needs
      // something that can overscroll, and "nothing here" is exactly when a
      // user reaches for pull-to-refresh.
      return ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        children: <Widget>[
          SizedBox(
            height: 320,
            child: EmptyState(
              icon: Icons.lan_outlined,
              title: l10n.t('proxies.empty.title'),
              message: l10n.t('proxies.empty.description'),
            ),
          ),
        ],
      );
    }

    final strings = ProxyStrings.of(context);

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final columns = proxyColumnsForWidth(
          constraints.maxWidth,
          layout: prefs.layout,
          proxyCols: config.proxyCols,
        );
        final itemHeight = proxyCardHeight(
          textTheme: Theme.of(context).textTheme,
          density: prefs.density,
          textScaler: MediaQuery.textScalerOf(context),
        );
        final listView = prefs.viewType == ProxiesViewType.list;

        void locate(ProxyGroupSection section) => unawaited(
          _locate(
            section,
            sections,
            listView: listView,
            columns: columns,
            itemHeight: itemHeight,
          ),
        );

        if (listView) {
          return ProxiesListView(
            scrollController: _listController,
            sections: sections,
            columns: columns,
            itemHeight: itemHeight,
            density: prefs.density,
            strings: strings,
            testingNodes: delay.testingNodes,
            onToggleGroup: (ProxyGroupSection section) => unawaited(
              ref.read(proxiesPrefsProvider.notifier).toggleGroup(section.name),
            ),
            onTestGroup: (ProxyGroupSection section) =>
                unawaited(_testGroup(section)),
            onLocateGroup: locate,
            onSelectNode: (ProxyGroupSection section, ProxyNodeView node) =>
                unawaited(_selectNode(section, node)),
            onTestNode: _testNode,
          );
        }

        final initialIndex = () {
          final index = _groupNames.indexOf(prefs.activeGroup ?? '');
          return index < 0 ? 0 : index;
        }();

        return DefaultTabController(
          key: ValueKey<String>('proxy-tabs:${_groupNames.join(' ')}'),
          length: sections.length,
          initialIndex: initialIndex,
          child: Builder(
            builder: (BuildContext tabContext) {
              final tabController = DefaultTabController.of(tabContext);
              return _ActiveTabReporter(
                controller: tabController,
                onIndexChanged: (int index) {
                  if (index < 0 || index >= _groupNames.length) return;
                  unawaited(
                    ref
                        .read(proxiesPrefsProvider.notifier)
                        .setActiveGroup(_groupNames[index]),
                  );
                },
                child: ProxiesTabView(
                  tabController: tabController,
                  sections: sections,
                  columns: columns,
                  itemHeight: itemHeight,
                  density: prefs.density,
                  strings: strings,
                  testingNodes: delay.testingNodes,
                  scrollControllerFor: _scrollControllerFor,
                  onTestGroup: (ProxyGroupSection section) =>
                      unawaited(_testGroup(section)),
                  onLocateGroup: locate,
                  onSelectNode:
                      (ProxyGroupSection section, ProxyNodeView node) =>
                          unawaited(_selectNode(section, node)),
                  onTestNode: _testNode,
                ),
              );
            },
          ),
        );
      },
    );
  }
}

/// Reports the settled tab index so the page can remember which group the user
/// was last looking at.
class _ActiveTabReporter extends StatefulWidget {
  const _ActiveTabReporter({
    required this.controller,
    required this.onIndexChanged,
    required this.child,
  });

  final TabController controller;
  final ValueChanged<int> onIndexChanged;
  final Widget child;

  @override
  State<_ActiveTabReporter> createState() => _ActiveTabReporterState();
}

class _ActiveTabReporterState extends State<_ActiveTabReporter> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handle);
  }

  @override
  void didUpdateWidget(covariant _ActiveTabReporter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(_handle);
      widget.controller.addListener(_handle);
    }
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handle);
    super.dispose();
  }

  void _handle() {
    if (widget.controller.indexIsChanging) return;
    widget.onIndexChanged(widget.controller.index);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
