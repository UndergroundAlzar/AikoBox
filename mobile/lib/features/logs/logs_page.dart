/// The real-time logs page.
///
/// Port of `src/renderer/src/pages/logs.tsx`, plus the level filter the desktop
/// never had (it filters only by text) and an explicit, stated cap on how much
/// is kept — see `logs_controller.dart` for the number and why.
///
/// The list is drawn `reverse: true` over a newest-first array, which is how
/// FlClash does it: index 0 is the newest line and sits at the bottom, so the
/// view stays pinned to the tail while the user is at the bottom and stays put
/// when they have scrolled up. The auto-scroll toggle only matters for the
/// second case, where it snaps back to the newest line as lines arrive.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../theme/app_theme.dart';
import '../../widgets/widgets.dart';
import 'log_tile.dart';
import 'logs_controller.dart';

class LogsPage extends ConsumerStatefulWidget {
  const LogsPage({super.key});

  @override
  ConsumerState<LogsPage> createState() => _LogsPageState();
}

class _LogsPageState extends ConsumerState<LogsPage> {
  final TextEditingController _search = TextEditingController();
  final ScrollController _scroll = ScrollController();

  bool _follow = true;

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Snaps back to the newest line when a batch arrives.
  ///
  /// With `reverse: true` the tail is offset 0, so this only ever does anything
  /// when the user has scrolled away from it and left auto-scroll on.
  void _followTail(List<LogLine>? previous, List<LogLine> next) {
    if (!_follow || previous == null || previous.length == next.length) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients || _scroll.offset <= 0) return;
      _scroll.jumpTo(0);
    });
  }

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;
    final ThemeData theme = Theme.of(context);
    final LogsViewState view = ref.watch(logsViewProvider);
    final List<LogLine> lines = ref.watch(visibleLogsProvider);
    final bool running = ref.watch(
      coreStatusProvider.select((CoreStatus status) => status.isRunning),
    );
    ref.listen<List<LogLine>>(visibleLogsProvider, _followTail);

    final bool filtering = view.query.isNotEmpty || view.level != null;

    return AikoScaffold(
      title: l10n.t('logs.title'),
      actions: <Widget>[
        IconButton(
          tooltip: view.paused
              ? l10n.t('connections.resume')
              : l10n.t('connections.pause'),
          color: view.paused ? theme.colorScheme.primary : null,
          onPressed: () => ref
              .read(logsViewProvider.notifier)
              .setPaused(paused: !view.paused),
          icon: Icon(
            view.paused ? Icons.play_arrow_rounded : Icons.pause_rounded,
          ),
        ),
        IconButton(
          tooltip: l10n.t('logs.autoScroll'),
          color: _follow ? theme.colorScheme.primary : null,
          onPressed: () => setState(() => _follow = !_follow),
          icon: const Icon(Icons.vertical_align_bottom_rounded),
        ),
        _LogsMenu(
          lines: lines,
          onClear: () => ref.read(logsViewProvider.notifier).clear(),
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(56),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(AikoDims.pagePadding, 0, 8, 8),
          child: Row(
            children: <Widget>[
              Expanded(
                child: TextField(
                  controller: _search,
                  onChanged: ref.read(logsViewProvider.notifier).setQuery,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    isDense: true,
                    filled: true,
                    hintText: l10n.t('logs.filter'),
                    prefixIcon: const Icon(Icons.search_rounded, size: 20),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                    suffixIcon: view.query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: l10n.t('common.clear'),
                            iconSize: 18,
                            onPressed: () {
                              _search.clear();
                              ref.read(logsViewProvider.notifier).setQuery('');
                            },
                            icon: const Icon(Icons.close_rounded),
                          ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(vertical: 10),
                  ),
                ),
              ),
              _LevelMenu(level: view.level),
            ],
          ),
        ),
      ),
      body: Column(
        children: <Widget>[
          if (view.paused)
            _Banner(
              icon: Icons.pause_circle_outline_rounded,
              text: l10n.t('logs.paused'),
            ),
          Expanded(
            child: lines.isEmpty
                ? EmptyState(
                    icon: Icons.article_outlined,
                    title: filtering
                        ? l10n.t('common.emptyState')
                        : running
                        ? l10n.t('logs.empty')
                        : l10n.t('dashboard.core.notRunning'),
                  )
                : SuperListView.separated(
                    controller: _scroll,
                    reverse: true,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: lines.length,
                    separatorBuilder: (BuildContext context, int index) =>
                        const Divider(height: 1, thickness: 1),
                    itemBuilder: (BuildContext context, int index) {
                      final LogLine line = lines[index];
                      return LogTile(
                        line: line,
                        onCopy: () => _copy(logLineAsText(l10n, line)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
    final AikoL10n l10n = context.l10n;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(l10n.t('common.copied')),
      ),
    );
  }
}

/// "Paused" / informational strip under the app bar.
class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Container(
      width: double.infinity,
      color: theme.colorScheme.secondaryContainer,
      padding: const EdgeInsets.symmetric(
        horizontal: AikoDims.pagePadding,
        vertical: 6,
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 16, color: theme.colorScheme.onSecondaryContainer),
          const SizedBox(width: 8),
          Text(
            text,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSecondaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

/// Severity filter. `null` is "all levels".
class _LevelMenu extends ConsumerWidget {
  const _LevelMenu({required this.level});

  final LogLevel? level;

  static const String _allValue = '#all';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AikoL10n l10n = context.l10n;
    return PopupMenuButton<String>(
      tooltip: l10n.t('mihomo.logLevel'),
      icon: Icon(
        Icons.filter_list_rounded,
        color: level == null ? null : Theme.of(context).colorScheme.primary,
      ),
      onSelected: (String value) => ref
          .read(logsViewProvider.notifier)
          .setLevel(value == _allValue ? null : LogLevel.fromWire(value)),
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        CheckedPopupMenuItem<String>(
          value: _allValue,
          checked: level == null,
          child: Text(l10n.t('logs.level.all')),
        ),
        for (final LogLevel candidate in kLogFilterLevels)
          CheckedPopupMenuItem<String>(
            value: candidate.wireName,
            checked: level == candidate,
            child: Text(l10n.t(logLevelLabelKey(candidate))),
          ),
      ],
    );
  }
}

/// Copy-everything and clear.
class _LogsMenu extends StatelessWidget {
  const _LogsMenu({required this.lines, required this.onClear});

  final List<LogLine> lines;
  final VoidCallback onClear;

  static const String _copyAll = '#copyAll';
  static const String _clear = '#clear';

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;
    return PopupMenuButton<String>(
      tooltip: l10n.t('common.more'),
      icon: const Icon(Icons.more_vert_rounded),
      onSelected: (String value) {
        if (value == _clear) {
          onClear();
          return;
        }
        // The list is newest-first for rendering; a copied transcript reads the
        // other way round.
        Clipboard.setData(
          ClipboardData(
            text: <String>[
              for (final LogLine line in lines.reversed)
                logLineAsText(l10n, line),
            ].join('\n'),
          ),
        );
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text(l10n.t('common.copied')),
          ),
        );
      },
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        PopupMenuItem<String>(
          value: _copyAll,
          enabled: lines.isNotEmpty,
          child: Row(
            children: <Widget>[
              const Icon(Icons.copy_rounded, size: 18),
              const SizedBox(width: 12),
              Text(l10n.t('common.copy')),
            ],
          ),
        ),
        PopupMenuItem<String>(
          value: _clear,
          child: Row(
            children: <Widget>[
              const Icon(Icons.delete_outline_rounded, size: 18),
              const SizedBox(width: 12),
              Text(l10n.t('logs.clear')),
            ],
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem<String>(
          enabled: false,
          child: Text(
            l10n.t(
              'logs.bufferHint',
              args: <String, Object?>{'count': kLogsViewLineLimit},
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
      ],
    );
  }
}
