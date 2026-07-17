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

  /// Indicates if running on a desktop operating system (macOS, Windows, Linux)
  /// Use this for capability checks (e.g. window controls, mouse hovers),
  /// NOT for layout sizing. Use [ResponsiveBreakpoints] for layout sizing.
  final bool isDesktopOS;

  /// Supported hardware-accelerated decoders (e.g. ['av1', 'hevc', 'h264'])
  final List<String> hardwareDecoders;

  const DeviceProfile({
    this.isTv = false,
    this.isTablet = false,
    this.isDesktopOS = false,
    this.hardwareDecoders = const ['h264'],
  });

  bool get isLargeScreen => isTv || isTablet || isDesktopOS;
}

@Riverpod(keepAlive: true)
Future<DeviceProfile> deviceProfile(Ref ref) async {
  bool isTv = false;
  bool isTablet = false;
  bool isDesktopOS = false;
  List<String> hardwareDecoders = const ['h264'];

  if (!kIsWeb) {
    if (Platform.isAndroid || Platform.isIOS) {
      final view = ui.PlatformDispatcher.instance.views.first;
      final size = view.physicalSize / view.devicePixelRatio;
      if (size.shortestSide >= 600) {
        isTablet = true;
      }
      
      final deviceInfo = DeviceInfoPlugin();
      
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        isTv = androidInfo.systemFeatures.contains('android.software.leanback');
        try {
          final codecs = await VideoController.getHardwareDecoders();
          hardwareDecoders = codecs;
        } catch (_) {}
      } else if (Platform.isIOS) {
        final iosDecoders = ['hevc', 'h264'];
        try {
          final iosInfo = await deviceInfo.iosInfo;
          final machine = iosInfo.utsname.machine;
          
          // Check for AV1 hardware decoder support on iPhone 15 Pro / Max (iPhone16,1 or iPhone16,2), 
          // iPhone 16 series (iPhone17,x), and M3/M4 iPads (iPad16,x)
          bool hasAv1 = false;
          final iphoneRegex = RegExp(r'^iPhone(\d+),(\d+)$');
          final iphoneMatch = iphoneRegex.firstMatch(machine);
          if (iphoneMatch != null) {
            final major = int.tryParse(iphoneMatch.group(1) ?? '') ?? 0;
            final minor = int.tryParse(iphoneMatch.group(2) ?? '') ?? 0;
            if (major == 16 && (minor == 1 || minor == 2)) {
              hasAv1 = true;
            } else if (major >= 17) {
              hasAv1 = true;
            }
          }
          if (machine.startsWith('iPad')) {
            final ipadRegex = RegExp(r'^iPad(\d+),(\d+)$');
            final ipadMatch = ipadRegex.firstMatch(machine);
            if (ipadMatch != null) {
              final major = int.tryParse(ipadMatch.group(1) ?? '') ?? 0;
              if (major >= 16) {
                hasAv1 = true;
              }
            }
          }
          if (hasAv1) {
            iosDecoders.insert(0, 'av1');
          }
        } catch (_) {}
        hardwareDecoders = iosDecoders;
      }
    }

    if (Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
      isDesktopOS = true;
      // High-end hardware decoders are standard on desktop environments,
      // and CPU limits are much higher so fallback costs are minimal.
      hardwareDecoders = const ['av1', 'hevc', 'vp9', 'h264'];
    }
  }

  return DeviceProfile(
    isTv: isTv,
    isTablet: isTablet,
    isDesktopOS: isDesktopOS,
    hardwareDecoders: hardwareDecoders,
  );
}
