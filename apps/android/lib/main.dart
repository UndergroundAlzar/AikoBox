import 'package:flutter/material.dart';

import 'app.dart';
import 'platform/vpn_bridge.dart';
import 'profiles/profile_import_service.dart';
import 'profiles/profile_repository.dart';
import 'settings/settings_controller.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final profileRepository = SharedPreferencesProfileRepository();
  final settingsController = SettingsController();
  await settingsController.load();

  runApp(
    AikoBoxApp(
      profileRepository: profileRepository,
      importService: ProfileImportService(
        fileStore: const DeviceProfileFileStore(),
      ),
      vpnBridge: const MethodChannelVpnBridge(),
      settingsController: settingsController,
    ),
  );
}
