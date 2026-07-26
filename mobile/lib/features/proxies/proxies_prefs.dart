/// Display preferences that belong to the proxies page alone.
///
/// The settings the desktop app keeps in `IAppConfig` — sort order, hide
/// unavailable, column count — live in [AppConfig] and are edited from the
/// settings page too. The three that exist only here (which of the two views is
/// showing, how tall a card is, how tight the grid packs) plus the accordion's
/// expand state are page state, so they persist through `SharedPreferences`
/// rather than widening the shared config file.
///
/// Nothing in this file imports `core/providers.dart`; it is deliberately
/// testable on its own.
library;

import 'dart:async';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

const SetEquality<String> _stringSet = SetEquality<String>();

/// Which of the two proxy layouts is showing.
///
/// [tab] is FlClash's tab strip — one group at a time, the grid fills the page.
/// [list] is the desktop app's accordion — every group stacked, each one
/// expandable in place.
enum ProxiesViewType {
  tab('tab'),
  list('list');

  const ProxiesViewType(this.wireName);

  final String wireName;

  static ProxiesViewType fromWire(Object? value) {
    final text = value?.toString();
    for (final candidate in ProxiesViewType.values) {
      if (candidate.wireName == text) return candidate;
    }
    return ProxiesViewType.tab;
  }
}

/// How much of a node a grid cell shows.
enum ProxyCardDensity {
  /// Name, type badges and the delay pill on its own row.
  expand('expand'),

  /// Name over a single row holding the type and the delay pill.
  shrink('shrink'),

  /// One line of name, then the type/delay row.
  min('min');

  const ProxyCardDensity(this.wireName);

  final String wireName;

  static ProxyCardDensity fromWire(Object? value) {
    final text = value?.toString();
    for (final candidate in ProxyCardDensity.values) {
      if (candidate.wireName == text) return candidate;
    }
    return ProxyCardDensity.shrink;
  }
}

/// Adjusts the computed column count by ±1. Port of FlClash's `ProxiesLayout`.
enum ProxiesLayout {
  loose('loose', -1),
  standard('standard', 0),
  tight('tight', 1);

  const ProxiesLayout(this.wireName, this.columnDelta);

  final String wireName;

  /// Added to `max((width / 250).ceil(), 2)`.
  final int columnDelta;

  static ProxiesLayout fromWire(Object? value) {
    final text = value?.toString();
    for (final candidate in ProxiesLayout.values) {
      if (candidate.wireName == text) return candidate;
    }
    return ProxiesLayout.standard;
  }
}

const String kProxiesViewTypePrefKey = 'aiko.proxies.viewType';
const String kProxiesDensityPrefKey = 'aiko.proxies.cardDensity';
const String kProxiesLayoutPrefKey = 'aiko.proxies.layout';
const String kProxiesExpandedPrefKey = 'aiko.proxies.expandedGroups';
const String kProxiesActiveGroupPrefKey = 'aiko.proxies.activeGroup';

/// Immutable snapshot of the page's own preferences.
@immutable
class ProxiesPrefs {
  const ProxiesPrefs({
    this.viewType = ProxiesViewType.tab,
    this.density = ProxyCardDensity.shrink,
    this.layout = ProxiesLayout.standard,
    this.expandedGroups = const <String>{},
    this.activeGroup,
  });

  static const ProxiesPrefs defaults = ProxiesPrefs();

  final ProxiesViewType viewType;
  final ProxyCardDensity density;
  final ProxiesLayout layout;

  /// Names of the groups the accordion is showing expanded.
  final Set<String> expandedGroups;

  /// The group the tab strip was last left on, so the page comes back to it.
  final String? activeGroup;

  bool isExpanded(String groupName) => expandedGroups.contains(groupName);

  ProxiesPrefs copyWith({
    ProxiesViewType? viewType,
    ProxyCardDensity? density,
    ProxiesLayout? layout,
    Set<String>? expandedGroups,
    String? activeGroup,
    bool clearActiveGroup = false,
  }) => ProxiesPrefs(
    viewType: viewType ?? this.viewType,
    density: density ?? this.density,
    layout: layout ?? this.layout,
    expandedGroups: expandedGroups ?? this.expandedGroups,
    activeGroup: clearActiveGroup ? null : (activeGroup ?? this.activeGroup),
  );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ProxiesPrefs &&
          other.viewType == viewType &&
          other.density == density &&
          other.layout == layout &&
          other.activeGroup == activeGroup &&
          _stringSet.equals(other.expandedGroups, expandedGroups);

  @override
  int get hashCode => Object.hash(
    viewType,
    density,
    layout,
    activeGroup,
    _stringSet.hash(expandedGroups),
  );

  @override
  String toString() =>
      'ProxiesPrefs(${viewType.wireName}, ${density.wireName}, '
      '${layout.wireName}, ${expandedGroups.length} expanded)';
}

/// Reads the persisted page preferences. Never throws — a storage failure just
/// means the defaults.
Future<ProxiesPrefs> loadProxiesPrefs() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final expanded = prefs.getStringList(kProxiesExpandedPrefKey);
    return ProxiesPrefs(
      viewType: ProxiesViewType.fromWire(
        prefs.getString(kProxiesViewTypePrefKey),
      ),
      density: ProxyCardDensity.fromWire(
        prefs.getString(kProxiesDensityPrefKey),
      ),
      layout: ProxiesLayout.fromWire(prefs.getString(kProxiesLayoutPrefKey)),
      expandedGroups: expanded == null
          ? const <String>{}
          : Set<String>.unmodifiable(expanded),
      activeGroup: prefs.getString(kProxiesActiveGroupPrefKey),
    );
  } catch (_) {
    return ProxiesPrefs.defaults;
  }
}

/// Publishes [ProxiesPrefs] and writes every change back to disk.
///
/// [build] answers with the defaults and hydrates immediately afterwards, the
/// same shape `AppConfigNotifier` uses, so no screen has to render a spinner
/// for something this small.
class ProxiesPrefsNotifier extends Notifier<ProxiesPrefs> {
  Future<void> _writes = Future<void>.value();

  @override
  ProxiesPrefs build() {
    unawaited(_hydrate());
    return ProxiesPrefs.defaults;
  }

  Future<void> _hydrate() async {
    final loaded = await loadProxiesPrefs();
    if (ref.mounted) state = loaded;
  }

  /// Serialises writes so two quick taps cannot land out of order.
  Future<void> _persist(Future<void> Function(SharedPreferences prefs) apply) {
    _writes = _writes.then((_) async {
      try {
        await apply(await SharedPreferences.getInstance());
      } catch (_) {
        // A preference that did not survive a restart is not worth an error
        // surface; the in-memory value is already correct.
      }
    });
    return _writes;
  }

  /// Flushes any queued write. Tests await this; the app does not need to.
  @visibleForTesting
  Future<void> settle() => _writes;

  Future<void> setViewType(ProxiesViewType value) async {
    if (state.viewType == value) return;
    state = state.copyWith(viewType: value);
    await _persist((p) => p.setString(kProxiesViewTypePrefKey, value.wireName));
  }

  Future<void> setDensity(ProxyCardDensity value) async {
    if (state.density == value) return;
    state = state.copyWith(density: value);
    await _persist((p) => p.setString(kProxiesDensityPrefKey, value.wireName));
  }

  Future<void> setLayout(ProxiesLayout value) async {
    if (state.layout == value) return;
    state = state.copyWith(layout: value);
    await _persist((p) => p.setString(kProxiesLayoutPrefKey, value.wireName));
  }

  Future<void> setActiveGroup(String? name) async {
    if (state.activeGroup == name) return;
    state = state.copyWith(activeGroup: name, clearActiveGroup: name == null);
    await _persist(
      (p) => name == null
          ? p.remove(kProxiesActiveGroupPrefKey)
          : p.setString(kProxiesActiveGroupPrefKey, name),
    );
  }

  Future<void> toggleGroup(String name) {
    final next = Set<String>.of(state.expandedGroups);
    if (!next.remove(name)) next.add(name);
    return _setExpanded(next);
  }

  Future<void> expandAll(Iterable<String> names) =>
      _setExpanded(Set<String>.of(names));

  Future<void> collapseAll() => _setExpanded(const <String>{});

  Future<void> _setExpanded(Set<String> next) async {
    state = state.copyWith(expandedGroups: Set<String>.unmodifiable(next));
    await _persist(
      (p) => p.setStringList(
        kProxiesExpandedPrefKey,
        next.toList(growable: false),
      ),
    );
  }
}

final proxiesPrefsProvider =
    NotifierProvider<ProxiesPrefsNotifier, ProxiesPrefs>(
      ProxiesPrefsNotifier.new,
    );
