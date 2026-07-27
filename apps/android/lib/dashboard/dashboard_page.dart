import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/vpn_bridge.dart';
import '../platform/vpn_state.dart';
import '../profiles/profile_controller.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({
    required this.profileController,
    required this.vpnBridge,
    super.key,
  });

  final ProfileController profileController;
  final VpnBridge vpnBridge;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  VpnStatus _status = const VpnStatus(state: VpnState.stopped);
  StreamSubscription<VpnStatus>? _subscription;
  String? _error;

  bool get _busy =>
      _status.state == VpnState.starting || _status.state == VpnState.stopping;

  @override
  void initState() {
    super.initState();
    _load();
    _subscription = widget.vpnBridge.statusEvents.listen(
      (status) {
        if (!mounted) return;
        _restoreSelectionFrom(status);
        setState(() {
          _status = status;
          _error = status.state == VpnState.error ? status.message : null;
        });
      },
      onError: (Object error) {
        if (mounted) {
          setState(() => _error = error.toString());
        }
      },
    );
  }

  Future<void> _load() async {
    try {
      final status = await widget.vpnBridge.getStatus();
      if (!mounted) {
        return;
      }
      _restoreSelectionFrom(status);
      setState(() => _status = status);
    } on Object catch (error) {
      if (mounted) {
        setState(() => _error = error.toString());
      }
    }
  }

  void _restoreSelectionFrom(VpnStatus status) {
    final activePath = status.activeProfilePath?.trim();
    final hasActivePath = activePath != null && activePath.isNotEmpty;
    if (hasActivePath) {
      widget.profileController.restoreSelection(
        activeProfilePath: activePath,
        allowFallback: false,
      );
      return;
    }
    if (status.state == VpnState.stopped || status.state == VpnState.error) {
      widget.profileController.restoreSelection(
        activeProfilePath: null,
        allowFallback: true,
      );
    }
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final running = _status.state == VpnState.running;
    return Scaffold(
      appBar: AppBar(
        title: const Text('AikoBox'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: _load,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.profileController,
        builder: (context, _) => RefreshIndicator(
          onRefresh: _load,
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
            children: [
              Center(
                child: Semantics(
                  button: true,
                  label: running ? '断开 VPN' : '连接 VPN',
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: _busy ? null : _toggle,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 280),
                      width: 184,
                      height: 184,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: running
                            ? colors.primaryContainer
                            : colors.surfaceContainerHighest,
                        boxShadow: [
                          BoxShadow(
                            color: colors.primary.withValues(
                              alpha: running ? 0.28 : 0.08,
                            ),
                            blurRadius: running ? 36 : 16,
                            spreadRadius: running ? 4 : 0,
                          ),
                        ],
                      ),
                      child: _busy
                          ? const Padding(
                              padding: EdgeInsets.all(70),
                              child: CircularProgressIndicator(),
                            )
                          : Icon(
                              Icons.power_settings_new_rounded,
                              size: 72,
                              color: running
                                  ? colors.primary
                                  : colors.onSurfaceVariant,
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              Text(
                _statusLabel(_status.state),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 6),
              Text(
                widget.profileController.selected?.name ?? '请先导入配置',
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
              if (_error != null) ...[
                const SizedBox(height: 16),
                Card(
                  color: colors.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: colors.error),
                        const SizedBox(width: 12),
                        Expanded(child: Text(_error!)),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _toggle() async {
    if (!mounted) return;
    setState(() => _error = null);
    try {
      if (_status.state == VpnState.running) {
        setState(() => _status = const VpnStatus(state: VpnState.stopping));
        await widget.vpnBridge.stop();
        return;
      }
      final profile = widget.profileController.selected;
      final profilePath = profile?.path;
      if (profile == null || profilePath == null) {
        throw const VpnBridgeException('请先在“配置”页导入配置');
      }
      setState(() => _status = const VpnStatus(state: VpnState.starting));
      final prepared = await widget.vpnBridge.prepareVpn();
      if (!mounted) return;
      if (!prepared) {
        throw const VpnBridgeException('未获得 VPN 权限');
      }
      await widget.vpnBridge.start(profilePath);
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _status = const VpnStatus(state: VpnState.error);
        _error = error.toString();
      });
    }
  }

  String _statusLabel(VpnState state) {
    return switch (state) {
      VpnState.stopped => '未连接',
      VpnState.starting => '正在连接',
      VpnState.running => '已连接',
      VpnState.stopping => '正在断开',
      VpnState.error => '连接异常',
    };
  }
}
