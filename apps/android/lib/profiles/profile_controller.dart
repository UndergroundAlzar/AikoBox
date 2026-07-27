import 'package:flutter/foundation.dart';

import 'profile.dart';
import 'profile_repository.dart';

class ProfileController extends ChangeNotifier {
  ProfileController(this.repository);

  final ProfileRepository repository;
  List<Profile> _profiles = const [];
  bool _loading = false;
  bool _disposed = false;
  String? _selectedId;
  String? _pendingActiveProfilePath;
  bool _selectionRestored = false;

  List<Profile> get profiles => List.unmodifiable(_profiles);
  bool get loading => _loading;
  Profile? get selected {
    for (final profile in _profiles) {
      if (profile.id == _selectedId) {
        return profile;
      }
    }
    return null;
  }

  Future<void> load() async {
    _loading = true;
    notifyListeners();
    try {
      final loaded = await repository.load();
      if (_disposed) {
        return;
      }
      _profiles = loaded;
      _restoreSelectionIfReady();
    } finally {
      if (!_disposed) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> add(Profile profile) async {
    final updated = [
      profile,
      ..._profiles.where((item) => item.id != profile.id),
    ];
    await repository.save(updated);
    _profiles = updated;
    _selectedId = profile.id;
    notifyListeners();
  }

  Future<void> remove(Profile profile) async {
    final updated = _profiles.where((item) => item.id != profile.id).toList();
    await repository.save(updated);
    _profiles = updated;
    if (_selectedId == profile.id) {
      _selectedId = _profiles.firstOrNull?.id;
    }
    notifyListeners();
  }

  void select(Profile profile) {
    _selectedId = profile.id;
    _pendingActiveProfilePath = profile.path;
    _selectionRestored = true;
    notifyListeners();
  }

  /// Reconciles the visible selection with the profile actually used by the
  /// native VPN service. The path is remembered when repository loading is
  /// still in flight, so Activity reconstruction cannot briefly fall back to
  /// an unrelated first profile.
  void restoreSelection({
    required String? activeProfilePath,
    required bool allowFallback,
  }) {
    _pendingActiveProfilePath = _normalizedPath(activeProfilePath);
    _selectionRestored = true;
    if (_profiles.isEmpty && _loading) {
      return;
    }
    _applyRestoredSelection(allowFallback: allowFallback);
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _restoreSelectionIfReady() {
    if (!_selectionRestored) {
      return;
    }
    _applyRestoredSelection(allowFallback: _pendingActiveProfilePath == null);
  }

  void _applyRestoredSelection({required bool allowFallback}) {
    final activePath = _pendingActiveProfilePath;
    if (activePath != null) {
      _selectedId = _profiles
          .where((profile) => _normalizedPath(profile.path) == activePath)
          .firstOrNull
          ?.id;
      return;
    }
    if (allowFallback) {
      final currentStillExists = _profiles.any(
        (profile) => profile.id == _selectedId,
      );
      if (!currentStillExists) {
        _selectedId = _profiles.firstOrNull?.id;
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

String? _normalizedPath(String? value) {
  final trimmed = value?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}

extension<T> on List<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
