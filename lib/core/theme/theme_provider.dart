import 'package:flutter/material.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import '../storage/settings_repository.dart';
import '../providers/device_info_provider.dart';

part 'theme_provider.g.dart';

@Riverpod(keepAlive: true)
class AppThemeMode extends _$AppThemeMode {
  late SettingsRepository _repository;

  @override
  ThemeMode build() {
    _repository = ref.watch(settingsRepositoryProvider);
    final saved = _repository.getThemeMode();
    if (saved == null) {
      final profile = ref.watch(deviceProfileProvider).asData?.value;
      if (profile?.isTv == true) {
        return ThemeMode.dark;
      }
      return ThemeMode.system;
    }
    return _getThemeMode(saved);
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    state = mode;
    await _repository.saveThemeMode(mode.name);
  }

  ThemeMode _getThemeMode(String mode) {
    switch (mode) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      case 'system':
      default:
        return ThemeMode.system;
    }
  }
}
