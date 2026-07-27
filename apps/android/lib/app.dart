import 'package:flutter/material.dart';

import 'dashboard/dashboard_page.dart';
import 'platform/vpn_bridge.dart';
import 'profiles/profile_import_service.dart';
import 'profiles/profile_controller.dart';
import 'profiles/profile_repository.dart';
import 'profiles/profiles_page.dart';
import 'settings/settings_controller.dart';
import 'settings/settings_page.dart';

class AikoBoxApp extends StatelessWidget {
  const AikoBoxApp({
    required this.profileRepository,
    required this.importService,
    required this.vpnBridge,
    required this.settingsController,
    super.key,
  });

  final ProfileRepository profileRepository;
  final ProfileImportService importService;
  final VpnBridge vpnBridge;
  final SettingsController settingsController;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settingsController,
      builder: (context, _) {
        return MaterialApp(
          title: 'AikoBox',
          debugShowCheckedModeBanner: false,
          themeMode: settingsController.themeMode,
          theme: _theme(Brightness.light),
          darkTheme: _theme(Brightness.dark),
          home: AikoShell(
            profileRepository: profileRepository,
            importService: importService,
            vpnBridge: vpnBridge,
            settingsController: settingsController,
          ),
        );
      },
    );
  }

  ThemeData _theme(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF6C63FF),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
      cardTheme: CardThemeData(
        elevation: 0,
        color: colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      navigationBarTheme: NavigationBarThemeData(
        indicatorColor: colorScheme.secondaryContainer,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(18),
          borderSide: BorderSide.none,
        ),
      ),
    );
  }
}

class AikoShell extends StatefulWidget {
  const AikoShell({
    required this.profileRepository,
    required this.importService,
    required this.vpnBridge,
    required this.settingsController,
    super.key,
  });

  final ProfileRepository profileRepository;
  final ProfileImportService importService;
  final VpnBridge vpnBridge;
  final SettingsController settingsController;

  @override
  State<AikoShell> createState() => _AikoShellState();
}

class _AikoShellState extends State<AikoShell> {
  int _index = 0;
  late final ProfileController _profileController;

  @override
  void initState() {
    super.initState();
    _profileController = ProfileController(widget.profileRepository)..load();
  }

  @override
  void dispose() {
    _profileController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      DashboardPage(
        profileController: _profileController,
        vpnBridge: widget.vpnBridge,
      ),
      ProfilesPage(
        controller: _profileController,
        importService: widget.importService,
        vpnBridge: widget.vpnBridge,
      ),
      SettingsPage(controller: widget.settingsController),
    ];
    return Scaffold(
      body: SafeArea(
        child: IndexedStack(index: _index, children: pages),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.shield_outlined),
            selectedIcon: Icon(Icons.shield),
            label: '连接',
          ),
          NavigationDestination(
            icon: Icon(Icons.tune_outlined),
            selectedIcon: Icon(Icons.tune),
            label: '配置',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: '设置',
          ),
        ],
      ),
    );
  }
}
