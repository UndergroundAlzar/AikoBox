/// The connections feed: active/closed bookkeeping, pausing, filtering and
/// sorting.
///
/// `core/providers.dart` publishes one `/connections` websocket frame at a time
/// with per-connection speeds already differenced. What it does not do — and
/// should not, because it is a shared stream — is remember which connections
/// used to exist. That memory is what the "Closed" tab is, and it lives here.
///
/// The bookkeeping is a direct port of the handler in
/// `src/renderer/src/pages/connections.tsx`, including its cap on retained
/// history, with one deliberate change: closed connections are derived from the
/// *already trimmed* history rather than the untrimmed one, so the buffer is
/// hard-bounded at [kClosedConnectionBufferLimit] instead of drifting a frame
/// past it.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';
import 'connection_fields.dart';

/// How many closed connections are kept for the "Closed" tab.
///
/// The desktop keeps the same number. Every retained record is a live
/// `ConnectionInfo` on a phone's heap, and 200 is already more history than
/// anyone scrolls through.
const int kClosedConnectionBufferLimit = 200;

/// What the connections page sorts on. Wire names match
/// `AppConfig.connectionOrderBy`, which is shared with the desktop's config.
enum ConnectionSortField {
  time('time'),
  upload('upload'),
  download('download'),
  uploadSpeed('uploadSpeed'),
  downloadSpeed('downloadSpeed');

  const ConnectionSortField(this.wireName);

  final String wireName;

  /// Falls back to [ConnectionSortField.time] for anything unrecognised, which
  /// is what a config written by a newer build looks like from here.
  static ConnectionSortField fromWire(Object? value) {
    final String text = value is String ? value.trim() : '';
    for (final ConnectionSortField field in ConnectionSortField.values) {
      if (field.wireName == text) return field;
    }
    return ConnectionSortField.time;
  }
}

/// The feed as the page sees it.
@immutable
class ConnectionsFeedState {
  const ConnectionsFeedState({
    this.active = const <ConnectionInfo>[],
    this.closed = const <ConnectionInfo>[],
    this.uploadTotal = 0,
    this.downloadTotal = 0,
    this.paused = false,
  });

  /// Connections the core reported in the most recently ingested frame.
  final List<ConnectionInfo> active;

  /// Connections seen earlier that the core no longer reports, newest last.
  final List<ConnectionInfo> closed;

  /// Cumulative bytes since the core started.
  final int uploadTotal;
  final int downloadTotal;

  /// While true, incoming frames are dropped and the lists stand still.
  final bool paused;

  ConnectionsFeedState copyWith({
    List<ConnectionInfo>? active,
    List<ConnectionInfo>? closed,
    int? uploadTotal,
    int? downloadTotal,
    bool? paused,
  }) => ConnectionsFeedState(
    active: active ?? this.active,
    closed: closed ?? this.closed,
    uploadTotal: uploadTotal ?? this.uploadTotal,
    downloadTotal: downloadTotal ?? this.downloadTotal,
    paused: paused ?? this.paused,
  );

  @override
  String toString() =>
      'ConnectionsFeedState(active: ${active.length}, '
      'closed: ${closed.length}, paused: $paused)';
}

/// Turns the shared `/connections` stream into active/closed lists.
class ConnectionsFeedNotifier extends Notifier<ConnectionsFeedState> {
  /// Every connection seen recently, active or not, oldest first. Bounded by
  /// [_historyLimit] on every ingest.
  List<ConnectionInfo> _history = const <ConnectionInfo>[];

  @override
  ConnectionsFeedState build() {
    ref.listen<AsyncValue<ConnectionsSnapshot>>(connectionsSnapshotProvider, (
      AsyncValue<ConnectionsSnapshot>? previous,
      AsyncValue<ConnectionsSnapshot> next,
    ) {
      next.whenOrNull<void>(data: ingest);
    }, fireImmediately: true);

    ref.listen<CoreStatus>(coreStatusProvider, (
      CoreStatus? previous,
      CoreStatus next,
    ) {
      // The socket simply stops when the core goes away; without this the
      // "Active" tab would keep showing connections that no longer exist.
      if (previous != null &&
          previous.state == CoreState.running &&
          next.state != CoreState.running) {
        retireAll();
      }
    });

    return const ConnectionsFeedState();
  }

  List<ConnectionInfo> _mergedHistory() {
    // Later writes win, so the freshest counters for a still-open connection
    // replace whatever the history was holding.
    final Map<String, ConnectionInfo> merged = <String, ConnectionInfo>{
      for (final ConnectionInfo item in _history) item.id: item,
      for (final ConnectionInfo item in state.active) item.id: item,
    };
    return merged.values.toList(growable: false);
  }

  static List<ConnectionInfo> _trim(List<ConnectionInfo> items, int limit) =>
      items.length > limit
      ? items.sublist(items.length - limit)
      : items;

  /// Folds one `/connections` frame into the feed.
  ///
  /// The closed list is trimmed *after* it is derived, not before, so the cap
  /// applies to the thing it is supposed to cap. Retained history is then
  /// pruned back to exactly what is on screen — anything else would be a
  /// record nobody can see and nobody can clear.
  @visibleForTesting
  void ingest(ConnectionsSnapshot snapshot) {
    if (!ref.mounted || state.paused) return;

    final List<ConnectionInfo> active = snapshot.connections;
    final Set<String> activeIds = <String>{
      for (final ConnectionInfo item in active) item.id,
    };

    final List<ConnectionInfo> merged = _mergedHistory();
    final List<ConnectionInfo> closed = _trim(<ConnectionInfo>[
      for (final ConnectionInfo item in merged)
        if (!activeIds.contains(item.id))
          item.copyWith(uploadSpeed: 0, downloadSpeed: 0),
    ], kClosedConnectionBufferLimit);

    _history = _retain(merged, activeIds, closed);

    state = state.copyWith(
      active: active,
      closed: closed,
      uploadTotal: snapshot.uploadTotal,
      downloadTotal: snapshot.downloadTotal,
    );
  }

  /// Moves everything to the "Closed" tab. Called when the core stops.
  @visibleForTesting
  void retireAll() {
    if (!ref.mounted) return;
    final List<ConnectionInfo> closed = _trim(<ConnectionInfo>[
      for (final ConnectionInfo item in _mergedHistory())
        item.copyWith(uploadSpeed: 0, downloadSpeed: 0),
    ], kClosedConnectionBufferLimit);
    _history = closed;
    state = state.copyWith(active: const <ConnectionInfo>[], closed: closed);
  }

  static List<ConnectionInfo> _retain(
    List<ConnectionInfo> merged,
    Set<String> activeIds,
    List<ConnectionInfo> closed,
  ) {
    final Set<String> keep = <String>{
      ...activeIds,
      for (final ConnectionInfo item in closed) item.id,
    };
    return <ConnectionInfo>[
      for (final ConnectionInfo item in merged)
        if (keep.contains(item.id)) item,
    ];
  }

  /// Freezes or resumes the feed. Frames that arrive while paused are dropped,
  /// not queued — the next frame carries the full state anyway.
  ///
  /// Resuming re-reads the socket's current frame rather than waiting for the
  /// next one. Riverpod suppresses a notification when the new value equals the
  /// old, and `ConnectionsSnapshot` has value equality, so an idle tunnel could
  /// otherwise leave the list frozen long after the user pressed play.
  void setPaused({required bool paused}) {
    if (state.paused == paused) return;
    state = state.copyWith(paused: paused);
    if (!paused) {
      ref
          .read(connectionsSnapshotProvider)
          .whenOrNull<void>(data: ingest);
    }
  }

  /// Drops one closed record. Also drops it from the retained history, or the
  /// next frame would put it straight back.
  void dismissClosed(String id) {
    _history = <ConnectionInfo>[
      for (final ConnectionInfo item in _history)
        if (item.id != id) item,
    ];
    state = state.copyWith(
      closed: <ConnectionInfo>[
        for (final ConnectionInfo item in state.closed)
          if (item.id != id) item,
      ],
    );
  }

  /// Drops the closed records in [ids], or all of them when [ids] is null.
  void clearClosed({Set<String>? ids}) {
    final Set<String> doomed =
        ids ??
        <String>{for (final ConnectionInfo item in state.closed) item.id};
    if (doomed.isEmpty) return;
    _history = <ConnectionInfo>[
      for (final ConnectionInfo item in _history)
        if (!doomed.contains(item.id)) item,
    ];
    state = state.copyWith(
      closed: <ConnectionInfo>[
        for (final ConnectionInfo item in state.closed)
          if (!doomed.contains(item.id)) item,
      ],
    );
  }
}

final NotifierProvider<ConnectionsFeedNotifier, ConnectionsFeedState>
connectionsFeedProvider =
    NotifierProvider<ConnectionsFeedNotifier, ConnectionsFeedState>(
      ConnectionsFeedNotifier.new,
    );

/// Free-text filter across the whole record, case-insensitively.
///
/// An empty or whitespace-only [query] returns [source] unchanged rather than a
/// copy, so the common case allocates nothing.
List<ConnectionInfo> filterConnections(
  List<ConnectionInfo> source,
  String query,
) {
  final String needle = query.trim().toLowerCase();
  if (needle.isEmpty) return source;
  return <ConnectionInfo>[
    for (final ConnectionInfo item in source)
      if (connectionHaystack(item).contains(needle)) item,
  ];
}

/// Orders [source] by [field].
///
/// `List.sort` is not a stable sort, and most of these fields are zero for most
/// connections — without a tie-break the rows would shuffle on every frame. Ties
/// therefore fall back to start time and then to id, which makes the order total
/// and the list visually still.
List<ConnectionInfo> sortConnections(
  List<ConnectionInfo> source, {
  required ConnectionSortField field,
  required bool ascending,
}) {
  int primary(ConnectionInfo a, ConnectionInfo b) {
    switch (field) {
      case ConnectionSortField.time:
        return 0;
      case ConnectionSortField.upload:
        return a.upload.compareTo(b.upload);
      case ConnectionSortField.download:
        return a.download.compareTo(b.download);
      case ConnectionSortField.uploadSpeed:
        return a.uploadSpeed.compareTo(b.uploadSpeed);
      case ConnectionSortField.downloadSpeed:
        return a.downloadSpeed.compareTo(b.downloadSpeed);
    }
  }

  final List<ConnectionInfo> sorted = List<ConnectionInfo>.of(source)
    ..sort((ConnectionInfo a, ConnectionInfo b) {
      int result = primary(a, b);
      if (result == 0) result = a.start.compareTo(b.start);
      if (result == 0) result = a.id.compareTo(b.id);
      return ascending ? result : -result;
    });
  return sorted;
}
