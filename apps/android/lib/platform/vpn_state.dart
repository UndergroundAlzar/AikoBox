enum VpnState {
  stopped,
  starting,
  running,
  stopping,
  error;

  static VpnState parse(Object? value) {
    final normalized = value?.toString().toLowerCase();
    return VpnState.values.firstWhere(
      (state) => state.name == normalized,
      orElse: () => VpnState.error,
    );
  }
}

class VpnStatus {
  const VpnStatus({required this.state, this.message, this.activeProfilePath});

  factory VpnStatus.fromMap(Map<Object?, Object?> map) {
    return VpnStatus(
      state: VpnState.parse(map['state']),
      message: map['message']?.toString(),
      activeProfilePath: map['activeProfilePath']?.toString(),
    );
  }

  final VpnState state;
  final String? message;
  final String? activeProfilePath;
}
