import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../platform/vpn_bridge.dart';
import '../platform/vpn_state.dart';
import 'profile.dart';
import 'profile_controller.dart';
import 'profile_import_service.dart';

class ProfilesPage extends StatefulWidget {
  const ProfilesPage({
    required this.controller,
    required this.importService,
    required this.vpnBridge,
    super.key,
  });

  final ProfileController controller;
  final ProfileImportService importService;
  final VpnBridge vpnBridge;

  @override
  State<ProfilesPage> createState() => _ProfilesPageState();
}

class _ProfilesPageState extends State<ProfilesPage> {
  bool _selectionInProgress = false;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('配置'),
        actions: [
          IconButton(
            tooltip: '导入配置',
            onPressed: _showImportSheet,
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: widget.controller,
        builder: (context, _) {
          if (widget.controller.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (widget.controller.profiles.isEmpty) {
            return _EmptyProfiles(onImport: _showImportSheet);
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: widget.controller.profiles.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final profile = widget.controller.profiles[index];
              final selected = widget.controller.selected?.id == profile.id;
              return Card(
                child: ListTile(
                  selected: selected,
                  leading: Icon(
                    selected ? Icons.check_circle : Icons.description_outlined,
                  ),
                  title: Text(profile.name),
                  subtitle: Text(_sourceLabel(profile)),
                  onTap: _selectionInProgress
                      ? null
                      : () => _selectProfile(profile),
                  trailing: IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _selectionInProgress
                        ? null
                        : () => _confirmDelete(profile),
                  ),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showImportSheet,
        icon: const Icon(Icons.add),
        label: const Text('导入'),
      ),
    );
  }

  String _sourceLabel(Profile profile) {
    return switch (profile.source) {
      ProfileSource.localFile => '本地 JSON',
      ProfileSource.httpsUrl => 'HTTPS · ${profile.sourceHost}',
      ProfileSource.pasted => '粘贴内容',
    };
  }

  Future<void> _showImportSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const ListTile(
                title: Text('导入配置'),
                subtitle: Text('仅支持最大 4 MiB 的 sing-box JSON'),
              ),
              ListTile(
                leading: const Icon(Icons.folder_open),
                title: const Text('本地 JSON 文件'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_importFile());
                },
              ),
              ListTile(
                leading: const Icon(Icons.https),
                title: const Text('HTTPS 地址'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_importTextDialog(urlMode: true));
                },
              ),
              ListTile(
                leading: const Icon(Icons.content_paste),
                title: const Text('粘贴 JSON'),
                onTap: () {
                  Navigator.pop(sheetContext);
                  unawaited(_importTextDialog(urlMode: false));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _importFile() async {
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
      );
      final file = result?.files.single;
      if (file == null) {
        return;
      }
      if (file.size > maxProfileBytes) {
        throw const ProfileImportException('配置超过 4 MiB 限制');
      }
      await _completeImport(
        widget.importService.fromStream(
          stream: file.xFile.openRead(),
          suggestedName: file.name,
        ),
      );
    } on Object catch (error) {
      _showError(error);
    }
  }

  Future<void> _importTextDialog({required bool urlMode}) async {
    final controller = TextEditingController();
    final input = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(urlMode ? '从 HTTPS 导入' : '粘贴 JSON'),
        content: TextField(
          controller: controller,
          autofocus: true,
          minLines: urlMode ? 1 : 8,
          maxLines: urlMode ? 2 : 16,
          keyboardType: urlMode ? TextInputType.url : TextInputType.multiline,
          decoration: InputDecoration(
            hintText: urlMode ? 'https://example.com/config.json' : '{ ... }',
          ),
          autocorrect: false,
          enableSuggestions: false,
          smartDashesType: SmartDashesType.disabled,
          smartQuotesType: SmartQuotesType.disabled,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (!mounted) {
      return;
    }
    if (input == null) {
      return;
    }
    try {
      await _completeImport(
        urlMode
            ? widget.importService.fromHttpsUrl(input)
            : widget.importService.fromPasted(input),
      );
    } on Object catch (error) {
      _showError(error);
    }
  }

  Future<void> _completeImport(Future<Profile> pending) async {
    final profile = await commitImportedProfile(
      pending: pending,
      importService: widget.importService,
      vpnBridge: widget.vpnBridge,
      controller: widget.controller,
    );
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('已导入“${profile.name}”')));
  }

  Future<void> _confirmDelete(Profile profile) async {
    final status = await widget.vpnBridge.getStatus();
    if (!mounted) return;
    if (isProfileActive(status, profile)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('请先断开当前 VPN，再删除正在使用的配置')));
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('删除配置？'),
        content: Text('“${profile.name}”将从设备中移除。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await widget.controller.remove(profile);
    }
  }

  Future<void> _selectProfile(Profile profile) async {
    if (_selectionInProgress || widget.controller.selected?.id == profile.id) {
      return;
    }
    setState(() => _selectionInProgress = true);
    try {
      await selectProfileSafely(
        controller: widget.controller,
        vpnBridge: widget.vpnBridge,
        profile: profile,
      );
      if (!mounted) return;
    } on Object catch (error) {
      _showError(error);
    } finally {
      if (mounted) {
        setState(() => _selectionInProgress = false);
      }
    }
  }

  void _showError(Object error) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }
}

bool isProfileActive(VpnStatus status, Profile profile) {
  return status.state != VpnState.stopped &&
      status.activeProfilePath == profile.path;
}

Future<void> selectProfileSafely({
  required ProfileController controller,
  required VpnBridge vpnBridge,
  required Profile profile,
  Duration confirmationTimeout = const Duration(seconds: 10),
  Duration pollInterval = const Duration(milliseconds: 50),
}) async {
  final status = await vpnBridge.getStatus();
  if (status.state == VpnState.starting || status.state == VpnState.stopping) {
    throw const VpnBridgeException('VPN 正在切换状态，请稍后再更换配置');
  }
  if (status.state == VpnState.running) {
    final path = profile.path;
    if (path == null) {
      throw const VpnBridgeException('配置文件不可用');
    }
    await vpnBridge.reload(path);
    await _waitForActiveProfile(
      vpnBridge: vpnBridge,
      profilePath: path,
      timeout: confirmationTimeout,
      pollInterval: pollInterval,
    );
  }
  controller.select(profile);
}

Future<void> _waitForActiveProfile({
  required VpnBridge vpnBridge,
  required String profilePath,
  required Duration timeout,
  required Duration pollInterval,
}) async {
  final stopwatch = Stopwatch()..start();
  while (true) {
    final status = await vpnBridge.getStatus();
    if (status.state == VpnState.running &&
        status.activeProfilePath == profilePath) {
      return;
    }
    if (status.state == VpnState.error) {
      throw VpnBridgeException(status.message ?? '切换配置失败');
    }
    if (status.state == VpnState.stopped || status.state == VpnState.stopping) {
      throw const VpnBridgeException('VPN 在配置切换完成前已停止');
    }
    if (stopwatch.elapsed >= timeout) {
      throw const VpnBridgeException('等待 VPN 确认新配置超时，已保留原选择');
    }
    await Future<void>.delayed(pollInterval);
  }
}

Future<Profile> commitImportedProfile({
  required Future<Profile> pending,
  required ProfileImportService importService,
  required VpnBridge vpnBridge,
  required ProfileController controller,
}) async {
  final profile = await pending;
  final path = profile.path;
  if (path == null) {
    throw const ProfileImportException('配置未能保存到应用私有目录');
  }
  try {
    await vpnBridge.checkProfile(path);
  } on Object {
    await importService.discard(profile);
    rethrow;
  }
  await controller.add(profile);
  return profile;
}

class _EmptyProfiles extends StatelessWidget {
  const _EmptyProfiles({required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.description_outlined,
              size: 72,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 20),
            Text('还没有配置', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            const Text(
              '导入经过信任的 sing-box JSON 后即可连接。',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onImport,
              icon: const Icon(Icons.add),
              label: const Text('导入配置'),
            ),
          ],
        ),
      ),
    );
  }
}
