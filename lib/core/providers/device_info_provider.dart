import 'dart:ui' as ui;
import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:video_view/video_view.dart';

part 'device_info_provider.g.dart';

class DeviceProfile {
  final bool isTv;
  final bool isTablet;
  final bool isDesktopOS;
  final List<String> hardwareDecoders;

  const DeviceProfile({
    this.isTv = false,
    this.isTablet = false,
    this.isDesktopOS = false,
    this.hardwareDecoders = const [],
  });

  bool get isLargeScreen => isTv || isTablet || isDesktopOS;
}

@riverpod
Future<DeviceProfile> deviceProfile(Ref ref) async {
  bool isTv = false;
  bool isTablet = false;
  bool isDesktopOS = false;
  List<String> hardwareDecoders = [];

  if (!kIsWeb) {
    if (Platform.isAndroid || Platform.isIOS) {
      final view = ui.PlatformDispatcher.instance.views.first;
      final size = view.physicalSize / view.devicePixelRatio;
      if (size.shortestSide >= 600) {
        isTablet = true;
      }
      if (Platform.isAndroid) {
        final deviceInfo = DeviceInfoPlugin();
        final androidInfo = await deviceInfo.androidInfo;
        isTv = androidInfo.systemFeatures.contains('android.software.leanback');
      }

      try {
        hardwareDecoders = await VideoController.getHardwareDecoders();
      } catch (_) {}
    }

    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      isDesktopOS = true;
      hardwareDecoders = ['hevc', 'h264', 'vp9', 'av1'];
    }
  } else {
    hardwareDecoders = ['h264'];
  }

  return DeviceProfile(
    isTv: isTv,
    isTablet: isTablet,
    isDesktopOS: isDesktopOS,
    hardwareDecoders: hardwareDecoders,
  );
}
