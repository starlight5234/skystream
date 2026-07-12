import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

class PlayerPlatformService {
  // Singleton — ensures saved window geometry survives across widget rebuilds.
  static final PlayerPlatformService _instance = PlayerPlatformService._internal();
  factory PlayerPlatformService() => _instance;
  PlayerPlatformService._internal();


  // ── Orientation helpers ────────────────────────────────────────────────────

  void toggleOrientation(BuildContext context) {
    final orientation = MediaQuery.of(context).orientation;
    if (orientation == Orientation.landscape) {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    } else {
      SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    }
  }

  void updateOrientation(int? width, int? height) {
    try {
      if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) return;
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerPlatformService.updateOrientation: $e');
    }

    if (width != null && height != null && width > 0 && height > 0) {
      if (width >= height) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
      }
    }
  }

  Future<bool> toggleFullscreen() async {
    if (Platform.isAndroid || Platform.isIOS) return false;
    try {
      final isFull = await windowManager.isFullScreen();
      if (!isFull) {
        if (Platform.isWindows || Platform.isLinux) {
          await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
        }
        await windowManager.setFullScreen(true);
        return true;
      } else {
        await windowManager.setFullScreen(false);
        if (Platform.isWindows || Platform.isLinux) {
          await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        }
        return false;
      }
    } catch (e) {
      if (kDebugMode) debugPrint('PlayerPlatformService.toggleFullscreen: $e');
    }
    return false;
  }
}
