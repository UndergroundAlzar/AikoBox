/// Search state and filtering for the rules page.
///
/// Deliberately thin: `rulesProvider` and `ruleProvidersProvider` in
/// `core/providers.dart` already own the fetching and the not-running case, so
/// all that is left here is the two search boxes and the predicates behind
/// them.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/providers.dart';

/// Search text for the rule list. Stored lower-cased.
class RulesQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String query) {
    final String normalised = query.trim().toLowerCase();
    if (normalised != state) state = normalised;
  }
}

final NotifierProvider<RulesQueryNotifier, String> rulesQueryProvider =
    NotifierProvider<RulesQueryNotifier, String>(RulesQueryNotifier.new);

/// Search text for the rule-provider list. Stored lower-cased.
class RuleProvidersQueryNotifier extends Notifier<String> {
  @override
  String build() => '';

  void set(String query) {
    final String normalised = query.trim().toLowerCase();
    if (normalised != state) state = normalised;
  }
}

final NotifierProvider<RuleProvidersQueryNotifier, String>
ruleProvidersQueryProvider =
    NotifierProvider<RuleProvidersQueryNotifier, String>(
      RuleProvidersQueryNotifier.new,
    );

/// True when [rule] matches [query] on type, payload or proxy — the three
/// fields the desktop's filter searches.
bool ruleMatchesQuery(RuleItem rule, String query) {
  if (query.isEmpty) return true;
  return rule.payload.toLowerCase().contains(query) ||
      rule.type.toLowerCase().contains(query) ||
      rule.proxy.toLowerCase().contains(query);
}

/// [source] narrowed to [query]. Returns [source] itself when there is nothing
/// to narrow.
List<RuleItem> filterRules(List<RuleItem> source, String query) {
  if (query.isEmpty) return source;
  return <RuleItem>[
    for (final RuleItem rule in source)
      if (ruleMatchesQuery(rule, query)) rule,
  ];
}

/// The rule list, narrowed by [rulesQueryProvider].
final Provider<AsyncValue<List<RuleItem>>> filteredRulesProvider =
    Provider<AsyncValue<List<RuleItem>>>((Ref ref) {
      final String query = ref.watch(rulesQueryProvider);
      return ref
          .watch(rulesProvider)
          .whenData(
            (List<RuleItem> rules) => filterRules(rules, query),
          );
    });

/// True when [provider] matches [query] on any of the fields the row shows.
bool providerMatchesQuery(ProviderInfo provider, String query) {
  if (query.isEmpty) return true;
  return provider.name.toLowerCase().contains(query) ||
      provider.type.toLowerCase().contains(query) ||
      provider.vehicleType.toLowerCase().contains(query) ||
      (provider.behavior?.toLowerCase().contains(query) ?? false) ||
      (provider.format?.toLowerCase().contains(query) ?? false);
}

/// Rule providers as a stable, name-sorted list narrowed by
/// [ruleProvidersQueryProvider].
///
/// The core hands them over as a map; iteration order of a decoded JSON object
/// is insertion order, which is stable enough in practice but not something a
/// list of rows should depend on.
final Provider<AsyncValue<List<ProviderInfo>>> filteredRuleProvidersProvider =
    Provider<AsyncValue<List<ProviderInfo>>>((Ref ref) {
      final String query = ref.watch(ruleProvidersQueryProvider);
      return ref
          .watch(ruleProvidersProvider)
          .whenData((Map<String, ProviderInfo> providers) {
            final List<ProviderInfo> out = <ProviderInfo>[
              for (final ProviderInfo provider in providers.values)
                if (providerMatchesQuery(provider, query)) provider,
            ]..sort(
              (ProviderInfo a, ProviderInfo b) =>
                  a.name.toLowerCase().compareTo(b.name.toLowerCase()),
            );
            return List<ProviderInfo>.unmodifiable(out);
          });
    });

/// Tracks which rule providers have an update in flight, so their rows can show
/// a spinner without the whole list going to a loading state.
class RuleProviderUpdatesNotifier extends Notifier<Set<String>> {
  @override
  Set<String> build() => const <String>{};

  bool isUpdating(String name) => state.contains(name);

  void _mark(String name, {required bool busy}) {
    if (!ref.mounted) return;
    final Set<String> next = <String>{...state};
    if (busy) {
      next.add(name);
    } else {
      next.remove(name);
    }
    state = Set<String>.unmodifiable(next);
  }

  /// Pulls one provider's source again and re-reads the rule list.
  ///
  /// Explicitly user-initiated — nothing on this page refreshes a provider on
  /// its own (N5). Rethrows so the page can surface the failure.
  Future<void> update(String name) async {
    if (state.contains(name)) return;
    _mark(name, busy: true);
    try {
      final ClashApi api = await ref.read(clashApiProvider.future);
      await api.updateRuleProvider(name);
      ref
        ..invalidate(ruleProvidersProvider)
        ..invalidate(rulesProvider);
    } finally {
      _mark(name, busy: false);
    }
  }

  /// [update] for every currently known provider, one at a time.
  ///
  /// Sequential on purpose: each call makes the core fetch a remote list, and a
  /// phone firing twenty of those at once is how you get a provider to rate
  /// limit you.
  Future<int> updateAll(Iterable<String> names) async {
    int failed = 0;
    for (final String name in names) {
      try {
        await update(name);
      } on Object {
        failed++;
      }
    }
    return failed;
  }
}

final NotifierProvider<RuleProviderUpdatesNotifier, Set<String>>
ruleProviderUpdatesProvider =
    NotifierProvider<RuleProviderUpdatesNotifier, Set<String>>(
      RuleProviderUpdatesNotifier.new,
    );

/// Maps a core error onto a stable l10n key so this page never renders a raw
/// exception string.
///
/// The core layer promises a stable `code` on everything user-facing; anything
/// it does not recognise collapses to the unknown-error key rather than leaking
/// an English `toString()` into a Chinese UI.
String failureMessageKey(Object error) {
  if (error is AikoCoreException) return 'error.code.${error.code}';
  if (error is CoreStartException) return 'error.code.${error.code}';
  if (error is ClashApiException) return 'error.code.E_CORE_NOT_RUNNING';
  return 'error.code.E_UNKNOWN';
}
