import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

class PlayerPlatformService {
  Future<void> enterPip(bool isPlaying) async {
    try {
      const platform = MethodChannel('dev.akash.skystream.player/pip');
      await platform.invokeMethod('enterPip', {'isPlaying': isPlaying});
    } catch (e) {
      if (kDebugMode) debugPrint("PIP Error: $e");
    }
  }

  void syncPipState(bool isPlaying) {
    if (Platform.isAndroid) {
      const MethodChannel(
        'dev.akash.skystream.player/pip',
      ).invokeMethod('setPipState', {'isPlaying': isPlaying});
    }
  }

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
    // Let the user decide when to rotate or allow auto-rotation via system sensors.
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
