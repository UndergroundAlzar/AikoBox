/// View state for the logs page: level filter, search, pause, and the cap on
/// how much of the buffer is ever rendered.
///
/// ## The cap
///
/// `core/providers.dart` already keeps a ring buffer of `AppConfig.maxLogLines`
/// (default 1000) lines, so nothing here grows without bound in the way the
/// desktop's `cachedLogs` did before it grew a `shift()`. What this file adds is
/// a second, *hard* ceiling that does not move when a user raises the setting:
/// [kLogsViewLineLimit] lines. Only the newest that many are filtered and
/// rendered.
///
/// 1000 was chosen because it is roughly a minute of `debug`-level output from
/// a busy core, it is far more than anyone reads by scrolling, and one
/// `LogLine` plus its rendered element costs enough that ten thousand of them
/// is a visible memory step on a mid-range phone. `logs.bufferHint` says the
/// number out loud in the UI so a user hunting for an old line knows it is gone
/// rather than mis-filtered.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// The hard ceiling on rendered log lines. See the library comment.
const int kLogsViewLineLimit = 1000;

/// Severity choices offered by the level menu, most severe first.
///
/// `LogLevel.silent` is not offered: it is a core-side setting meaning "emit
/// nothing", not a filter the page can apply to lines that already exist.
const List<LogLevel> kLogFilterLevels = <LogLevel>[
  LogLevel.error,
  LogLevel.warning,
  LogLevel.info,
  LogLevel.debug,
];

/// l10n key for a level's name. The desktop spells these under `mihomo.*` and
/// the translations already exist there.
String logLevelLabelKey(LogLevel level) => switch (level) {
  LogLevel.silent => 'mihomo.silent',
  LogLevel.error => 'mihomo.error',
  LogLevel.warning => 'mihomo.warning',
  LogLevel.info => 'mihomo.info',
  LogLevel.debug => 'mihomo.debug',
};

/// True when [line] should survive a filter set to [level].
///
/// Severity runs `silent < error < warning < info < debug` in [LogLevel]'s
/// declaration order, so "at least as severe as" is an index comparison.
/// Picking *Error* shows errors only; picking *Info* shows everything except
/// debug.
bool logPassesLevel(LogLine line, LogLevel? level) =>
    level == null || line.severity.index <= level.index;

/// True when [line] matches the free-text [query], searching both the message
/// and the level name — the two things the desktop searches.
bool logMatchesQuery(LogLine line, String query) {
  if (query.isEmpty) return true;
  return line.payload.toLowerCase().contains(query) ||
      line.level.toLowerCase().contains(query);
}

@immutable
class LogsViewState {
  const LogsViewState({
    this.query = '',
    this.level,
    this.paused = false,
    this.frozen = const <LogLine>[],
  });

  /// Already lower-cased so the filter itself is a plain `contains`.
  final String query;

  /// `null` means "all levels".
  final LogLevel? level;

  final bool paused;

  /// The buffer as it stood when the feed was paused. Empty while running.
  final List<LogLine> frozen;

  LogsViewState copyWith({
    String? query,
    LogLevel? level,
    bool clearLevel = false,
    bool? paused,
    List<LogLine>? frozen,
  }) => LogsViewState(
    query: query ?? this.query,
    level: clearLevel ? null : (level ?? this.level),
    paused: paused ?? this.paused,
    frozen: frozen ?? this.frozen,
  );
}

class LogsViewNotifier extends Notifier<LogsViewState> {
  @override
  LogsViewState build() => const LogsViewState();

  void setQuery(String query) {
    final String normalised = query.trim().toLowerCase();
    if (normalised == state.query) return;
    state = state.copyWith(query: normalised);
  }

  void setLevel(LogLevel? level) {
    state = level == null
        ? state.copyWith(clearLevel: true)
        : state.copyWith(level: level);
  }

  /// Pausing snapshots the buffer so the list stands still while the core keeps
  /// talking; resuming drops the snapshot and rejoins the live one.
  void setPaused({required bool paused}) {
    if (state.paused == paused) return;
    state = state.copyWith(
      paused: paused,
      frozen: paused
          ? List<LogLine>.unmodifiable(ref.read(logsProvider))
          : const <LogLine>[],
    );
  }

  /// Clears the shared buffer and, if paused, the frozen copy with it —
  /// otherwise "clear" would visibly do nothing.
  void clear() {
    ref.read(logsProvider.notifier).clear();
    if (state.paused) state = state.copyWith(frozen: const <LogLine>[]);
  }
}

final NotifierProvider<LogsViewNotifier, LogsViewState> logsViewProvider =
    NotifierProvider<LogsViewNotifier, LogsViewState>(LogsViewNotifier.new);

/// The lines the page actually renders, **newest first**.
///
/// The order is reversed here rather than in the widget because the list is
/// drawn with `reverse: true`: index 0 is the newest line and sits at the
/// bottom of the viewport, which is what keeps the view pinned to the tail
/// without any scroll-controller work.
final Provider<List<LogLine>> visibleLogsProvider = Provider<List<LogLine>>((
  Ref ref,
) {
  final LogsViewState view = ref.watch(logsViewProvider);
  // While paused the live buffer is deliberately not watched, so incoming
  // lines do not rebuild a list that cannot change.
  final List<LogLine> source = view.paused
      ? view.frozen
      : ref.watch(logsProvider);

  final int start = source.length > kLogsViewLineLimit
      ? source.length - kLogsViewLineLimit
      : 0;

  final List<LogLine> out = <LogLine>[];
  for (int i = source.length - 1; i >= start; i--) {
    final LogLine line = source[i];
    if (logPassesLevel(line, view.level) &&
        logMatchesQuery(line, view.query)) {
      out.add(line);
    }
  }
  return List<LogLine>.unmodifiable(out);
});
