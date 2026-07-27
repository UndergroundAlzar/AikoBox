import 'package:flutter/material.dart';

import 'settings_controller.dart';

class SettingsPage extends StatelessWidget {
  const SettingsPage({required this.controller, super.key});

  final SettingsController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        children: [
          Text('外观', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Card(
            child: RadioGroup<ThemeMode>(
              groupValue: controller.themeMode,
              onChanged: _themeChanged,
              child: const Column(
                children: [
                  RadioListTile<ThemeMode>(
                    value: ThemeMode.system,
                    title: Text('跟随系统'),
                    secondary: Icon(Icons.brightness_auto),
                  ),
                  RadioListTile<ThemeMode>(
                    value: ThemeMode.light,
                    title: Text('浅色'),
                    secondary: Icon(Icons.light_mode_outlined),
                  ),
                  RadioListTile<ThemeMode>(
                    value: ThemeMode.dark,
                    title: Text('深色'),
                    secondary: Icon(Icons.dark_mode_outlined),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          Text('安全', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          const Card(
            child: Column(
              children: [
                ListTile(
                  leading: Icon(Icons.lock_outline),
                  title: Text('私有配置存储'),
                  subtitle: Text('配置仅保存在应用数据中'),
                ),
                ListTile(
                  leading: Icon(Icons.visibility_off_outlined),
                  title: Text('错误信息脱敏'),
                  subtitle: Text('隐藏 URL 凭据、令牌、密码和标识符'),
                ),
                ListTile(
                  leading: Icon(Icons.https_outlined),
                  title: Text('安全远程导入'),
                  subtitle: Text('仅允许 HTTPS，最大 4 MiB'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          const Card(
            child: AboutListTile(
              icon: Icon(Icons.info_outline),
              applicationName: 'AikoBox',
              applicationVersion: '0.1.0-beta.3',
              applicationLegalese: 'GPL-3.0',
            ),
          ),
        ],
      ),
    );
  }

  void _themeChanged(ThemeMode? value) {
    if (value != null) {
      controller.setThemeMode(value);
    }
  }
}
