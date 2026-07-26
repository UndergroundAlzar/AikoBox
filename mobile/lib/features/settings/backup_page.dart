/// Backup and restore of the application configuration to a local file.
///
/// v1 is deliberately local-only — no WebDAV, no Gist. The desktop client's
/// remote backup carries a GitHub token and a WebDAV password; neither has a
/// safe home on a phone yet, and shipping half of it would be worse than
/// shipping none.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:aikobox_subscription/aikobox_subscription.dart'
    show redactSecrets;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/providers.dart';
import '../../l10n/aiko_l10n.dart';
import '../../widgets/widgets.dart';
import 'app_info.dart';
import 'appearance_sync.dart';
import 'backup_codec.dart';
import 'settings_controls.dart';

const String kBackupRoute = '/settings/backup';

/// Writes [bytes] somewhere the user chose. Returns the path, or null when the
/// dialog was cancelled.
typedef BackupWriter =
    Future<String?> Function(String fileName, Uint8List bytes);

/// Reads a user-chosen file as text. Returns null when the dialog was
/// cancelled.
typedef BackupReader = Future<String?> Function();

/// Overridden in tests so the file dialogs never have to run.
final Provider<BackupWriter> backupWriterProvider = Provider<BackupWriter>(
  (Ref ref) => _saveWithPicker,
);

final Provider<BackupReader> backupReaderProvider = Provider<BackupReader>(
  (Ref ref) => _readWithPicker,
);

Future<String?> _saveWithPicker(String fileName, Uint8List bytes) =>
    FilePicker.saveFile(
      fileName: fileName,
      bytes: bytes,
      type: FileType.custom,
      allowedExtensions: const <String>['json'],
    );

Future<String?> _readWithPicker() async {
  final FilePickerResult? result = await FilePicker.pickFiles(
    withData: true,
    type: FileType.any,
  );
  if (result == null || result.files.isEmpty) return null;
  final Uint8List? bytes = result.files.first.bytes;
  if (bytes == null) return null;
  try {
    return utf8.decode(bytes);
  } on FormatException {
    // Not UTF-8; let the codec reject it as "not JSON" rather than crash here.
    return utf8.decode(bytes, allowMalformed: true);
  }
}

class BackupPage extends ConsumerStatefulWidget {
  const BackupPage({super.key});

  @override
  ConsumerState<BackupPage> createState() => _BackupPageState();
}

class _BackupPageState extends ConsumerState<BackupPage> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final AikoL10n l10n = context.l10n;

    return AikoScaffold(
      title: l10n.t('localBackup.title'),
      body: SettingsBody(
        children: <Widget>[
          SettingsGroup(
            isFirst: true,
            title: l10n.t('settings.section.backup'),
            children: <Widget>[
              SettingsNote(
                l10n.t('localBackup.import.confirm.body'),
                icon: Icons.warning_amber_rounded,
              ),
              SettingsValueTile(
                tileKey: const Key('backup-export'),
                title: l10n.t('localBackup.export.title'),
                subtitle: l10n.t('localBackup.export.button'),
                icon: Icons.upload_file_rounded,
                showChevron: false,
                enabled: !_busy,
                onTap: _export,
              ),
              SettingsValueTile(
                tileKey: const Key('backup-import'),
                title: l10n.t('localBackup.import.title'),
                subtitle: l10n.t('localBackup.import.button'),
                icon: Icons.download_rounded,
                showChevron: false,
                enabled: !_busy,
                onTap: _import,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _export() async {
    setState(() => _busy = true);
    try {
      final AppConfig config = ref.read(appConfigProvider);
      // Resolved rather than peeked: nothing else on this page watches the
      // package info, so a plain read would still be loading.
      String version = '';
      try {
        final PackageInfo info = await ref.read(appPackageInfoProvider.future);
        version = '${info.version}+${info.buildNumber}';
      } catch (_) {
        // A backup without a version stamp is still a valid backup.
      }
      final DateTime now = DateTime.now();
      final String document = encodeAikoBackup(
        config,
        exportedAt: now,
        appVersion: version,
      );
      final String? path = await ref.read(backupWriterProvider)(
        defaultBackupFileName(now),
        Uint8List.fromList(utf8.encode(document)),
      );
      if (!mounted) return;
      if (path == null) return; // Cancelled.
      showAikoSnack(
        context,
        context.l10n.t('localBackup.notification.exportSuccess.title'),
      );
    } catch (_) {
      if (mounted) {
        showAikoSnack(
          context,
          context.l10n.t('common.saveFailed'),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    setState(() => _busy = true);
    try {
      final String? raw = await ref.read(backupReaderProvider)();
      if (raw == null || !mounted) return;

      final AikoBackup backup;
      try {
        backup = decodeAikoBackup(raw);
      } on BackupFormatException catch (error) {
        if (mounted) {
          showAikoSnack(
            context,
            context.l10n.t(
              'common.error.restoreFailed',
              args: <String, Object?>{'error': error.code},
            ),
            error: true,
          );
        }
        return;
      }

      if (!mounted) return;
      final AikoL10n l10n = context.l10n;
      final bool confirmed = await showAikoConfirmSheet(
        context,
        title: l10n.t('localBackup.import.confirm.title'),
        message: l10n.t('localBackup.import.confirm.body'),
        confirmLabel: l10n.t('common.confirm'),
        cancelLabel: l10n.t('common.cancel'),
        icon: Icons.settings_backup_restore_rounded,
        destructive: true,
      );
      if (!confirmed || !mounted) return;

      await ref
          .read(appConfigProvider.notifier)
          .update((AppConfig _) => backup.appConfig);
      await adoptAppearanceFromConfig(ref, backup.appConfig);
      await ref
          .read(localeSettingProvider.notifier)
          .setLocaleTag(
            AikoL10n.isSupportedTag(backup.appConfig.language ?? '')
                ? backup.appConfig.language
                : null,
          );

      if (mounted) {
        showAikoSnack(
          context,
          context.l10n.t('localBackup.notification.importSuccess.title'),
        );
      }
    } catch (error) {
      if (mounted) {
        showAikoSnack(
          context,
          context.l10n.t(
            'common.error.restoreFailed',
            // The file being restored is user-supplied and may be anything at
            // all; a parse failure can quote its contents (N7).
            args: <String, Object?>{'error': redactSecrets('$error')},
          ),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
